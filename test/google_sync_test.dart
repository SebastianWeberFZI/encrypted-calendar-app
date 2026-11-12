import 'dart:io';

import 'package:encrypted_calendar_app/src/models/calendar_models.dart';
import 'package:encrypted_calendar_app/src/sync/device_calendar.dart';
import 'package:encrypted_calendar_app/src/sync/event_mapping.dart';
import 'package:encrypted_calendar_app/src/sync/google_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// Attrappe des Android-Kalenderspeichers (verhält sich wie ohne Sync-Adapter:
/// Löschen markiert nur).
class FakeDevice implements DeviceCalendarApi {
  final Map<int, Map<String, Object?>> rows = {};
  final Map<int, List<(int, int)>> instanceList = {};
  var nextId = 100;
  var permission = true;
  final cals = [
    const DeviceCalendar(id: 1, name: 'sarah@gmail.com', account: 'sarah@gmail.com',
        accountType: 'com.google', owner: 'sarah@gmail.com', primary: true),
    const DeviceCalendar(id: 2, name: 'Feiertage', account: 'sarah@gmail.com',
        accountType: 'com.google', accessLevel: 200),
  ];

  int add(Map<String, Object?> v) {
    final id = nextId++;
    rows[id] = {'_id': id, 'deleted': 0, 'eventTimezone': 'Europe/Berlin', ...v};
    return id;
  }

  DeviceEvent row(int id) => DeviceEvent.fromRow(rows[id]!);
  List<DeviceEvent> live([int cal = 1]) => [
        for (final r in rows.values)
          if (r['deleted'] != 1 && r['calendar_id'] == cal) DeviceEvent.fromRow(r)
      ];

  @override
  Future<bool> hasPermission() async => permission;
  @override
  Future<List<DeviceCalendar>> calendars() async => cals;
  @override
  Future<List<DeviceEvent>> events(List<int> calendarIds, int fromMillis) async => [
        for (final r in rows.values)
          if (r['deleted'] != 1 && calendarIds.contains(r['calendar_id']))
            if (r['rrule'] != null || ((r['dtend'] ?? r['dtstart']) as int) >= fromMillis) DeviceEvent.fromRow(r)
      ];
  @override
  Future<List<DeviceEvent>> eventsByIds(List<int> ids) async =>
      [for (final id in ids) if (rows[id] != null) DeviceEvent.fromRow(rows[id]!)];
  @override
  Future<List<(int, int)>> instances(int eventId, int fromMillis, int toMillis) async =>
      instanceList[eventId] ?? [];
  @override
  Future<int> insert(Map<String, Object?> values) async => add(values);
  @override
  Future<void> update(int id, Map<String, Object?> values) async => rows[id]!.addAll(values);
  @override
  Future<void> delete(int id) async => rows[id]?['deleted'] = 1;
}

class MemoryData implements AppCalendarData {
  MemoryData(this.me);
  String me;
  @override
  final List<CalendarDef> calendars = [];
  @override
  final List<CalendarEvent> events = [];

  @override
  Future<void> saveEvent(CalendarEvent e) async {
    e.updatedAt = DateTime.now();
    e.updatedBy = me;
    events.removeWhere((x) => x.id == e.id);
    events.add(e);
  }

  @override
  Future<void> deleteEvent(CalendarEvent e) async => events.removeWhere((x) => x.id == e.id);

  CalendarEvent byTitle(String t) => events.firstWhere((e) => e.title == t);
  Iterable<CalendarEvent> inCal(CalendarDef c) => events.where((e) => e.calendarKey == c.key);
}

void main() {
  late Directory tmp;
  late FakeDevice dev;
  late MemoryData data;
  late CalendarDef familie, google;
  final now = DateTime(2026, 11, 12, 18, 0);

  GoogleSync sync({GoogleSyncConfig? config, String me = 'Sarah'}) => GoogleSync(
        data: data,
        api: dev,
        me: me,
        clock: () => now,
        stateFile: File('${tmp.path}/sub/state.json'),
        config: config ??
            GoogleSyncConfig(importCalendarKey: google.key, importFrom: const [1], defaultTarget: 1),
      );

  CalendarEvent ev(String title, DateTime s, DateTime e, {CalendarDef? cal, bool allDay = false, Recurrence? rec}) {
    final x = CalendarEvent(sourceId: 'g', calendarId: (cal ?? familie).id, title: title,
        start: s, end: e, allDay: allDay, recurrence: rec, updatedBy: 'Sebastian');
    data.events.add(x);
    return x;
  }

  int googleOnly(String title, DateTime s, DateTime e, {Map<String, Object?> more = const {}}) => dev.add({
        'calendar_id': 1, 'title': title, 'dtstart': s.millisecondsSinceEpoch,
        'dtend': e.millisecondsSinceEpoch, 'allDay': 0, ...more,
      });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gsync');
    dev = FakeDevice();
    data = MemoryData('Sarah');
    familie = CalendarDef(sourceId: 'g', name: 'Gemeinsam', color: 0xFF00AA00);
    google = CalendarDef(sourceId: 'g', name: 'Sarah – Google', color: 0xFF4285F4);
    data.calendars.addAll([familie, google]);
  });
  tearDown(() => tmp.delete(recursive: true));

  group('Formen und Regeln', () {
    test('Regeln hin und zurück', () {
      final s = DateTime(2026, 11, 12, 9); // Donnerstag
      expect(parseRule('FREQ=WEEKLY;BYDAY=TH;WKST=MO', s)!.byWeekday, isEmpty);
      expect(parseRule('FREQ=WEEKLY;BYDAY=MO,TH', s)!.byWeekday, [1, 4]);
      expect(parseRule('FREQ=MONTHLY;BYDAY=2TU', s), isNull);
      expect(parseRule('FREQ=MONTHLY;BYMONTHDAY=12', s)!.freq, RecurrenceFreq.monthly);
      expect(parseRule('FREQ=MONTHLY;BYMONTHDAY=1,15', s), isNull);
      expect(parseRule('FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=12', s)!.freq, RecurrenceFreq.yearly);
      expect(parseRule('FREQ=DAILY;INTERVAL=2;UNTIL=20261231T225959Z', s)!.until, DateTime(2026, 12, 31));
      expect(parseRule('FREQ=HOURLY', s), isNull);
      final r = Recurrence(freq: RecurrenceFreq.weekly, until: DateTime(2026, 12, 31));
      expect(canonicalRule(r, s), 'FREQ=WEEKLY;BYDAY=TH;UNTIL=20261231');
      final endUtc = DateTime(2026, 12, 31, 23, 59, 59).toUtc();
      expect(providerRule(r, s, false),
          'FREQ=WEEKLY;BYDAY=TH;UNTIL=${endUtc.year}${_two(endUtc.month)}${_two(endUtc.day)}T${_two(endUtc.hour)}5959Z');
      expect(providerRule(r, s, true), 'FREQ=WEEKLY;BYDAY=TH;UNTIL=20261231');
    });

    test('EXDATE in allen Schreibweisen, Dauer', () {
      expect(parseExdates('20261119T080000Z,20261126T080000Z'), [DateTime(2026, 11, 19), DateTime(2026, 11, 26)]);
      expect(parseExdates('TZID=Europe/Berlin;20261119T090000'), [DateTime(2026, 11, 19)]);
      expect(parseExdates('20261224T000000Z', allDay: true), [DateTime(2026, 12, 24)]);
      expect(parseExdates('EXDATE;VALUE=DATE:20261224\nEXDATE;VALUE=DATE:20261231', allDay: true),
          [DateTime(2026, 12, 24), DateTime(2026, 12, 31)]);
      expect(parseDuration('P3600S'), 3600000);
      expect(parseDuration('PT1H30M'), 5400000);
      expect(parseDuration('P2D'), 2 * 86400000);
    });

    test('App → Kalenderspeicher → gleiche Form (auch über die Zeitumstellung)', () {
      final cases = [
        ev('Termin', DateTime(2026, 11, 12, 9, 30), DateTime(2026, 11, 12, 10, 15)),
        ev('Urlaub', DateTime(2026, 10, 24), DateTime(2026, 10, 27), allDay: true),
        ev('Sport', DateTime(2026, 10, 1, 19), DateTime(2026, 10, 1, 20),
            rec: Recurrence(freq: RecurrenceFreq.weekly, byWeekday: const [1, 4], until: DateTime(2027, 3, 31)))
          ..exdates = [DateTime(2026, 10, 29)],
        ev('Geburtstag', DateTime(1990, 3, 29), DateTime(1990, 3, 29), allDay: true,
            rec: const Recurrence(freq: RecurrenceFreq.yearly)),
      ];
      for (final e in cases) {
        final row = DeviceEvent.fromRow({'_id': 1, 'calendar_id': 1, ...rowValuesFromApp(e)});
        expect(normFromRow(row).key, normFromApp(e).key, reason: e.title);
      }
      final urlaub = rowValuesFromApp(cases[1]);
      expect(urlaub['dtstart'], DateTime.utc(2026, 10, 24).millisecondsSinceEpoch);
      expect(urlaub['dtend'], DateTime.utc(2026, 10, 28).millisecondsSinceEpoch);
      expect(urlaub['eventTimezone'], 'UTC');
      final sport = rowValuesFromApp(cases[2]);
      expect(sport['dtend'], isNull);
      expect(sport['duration'], 'P3600S');
      final ex = DateTime(2026, 10, 29, 19).toUtc();
      expect(sport['exdate'], '${ex.year}${_two(ex.month)}${_two(ex.day)}T${_two(ex.hour)}0000Z');
    });
  });

  group('Abgleich', () {
    test('App-Termine landen markiert im Google-Kalender, Google-Termine in „Sarah – Google“', () async {
      final t = ev('Elternabend', DateTime(2026, 11, 20, 19), DateTime(2026, 11, 20, 21));
      ev('Alt', DateTime(2026, 1, 3, 9), DateTime(2026, 1, 3, 10)); // außerhalb des Fensters
      final gid = googleOnly('Zahnarzt', DateTime(2026, 11, 18, 8), DateTime(2026, 11, 18, 9),
          more: {'description': 'Kontrolle', 'eventLocation': 'Praxis'});
      final r = await sync().run();
      expect(r.exported, 1);
      expect(r.imported, 1);
      final copy = dev.live().firstWhere((x) => x.title == 'Elternabend');
      expect(copy.customAppPackage, kAppPackage);
      expect(copy.customAppUri, 'kalender://event/${t.id}');
      final z = data.byTitle('Zahnarzt');
      expect(z.calendarKey, google.key);
      expect((z.description, z.location), ('Kontrolle', 'Praxis'));
      expect((z.extra['google'] as Map)['event'], gid);
      expect(data.inCal(google).length, 1, reason: 'eigene Kopien kommen nicht zurück');
      // Zweiter Lauf: nichts mehr zu tun
      final r2 = await sync().run();
      expect(r2.anything, isFalse, reason: r2.summary);
    });

    test('Änderungen in beide Richtungen, Herkunft gewinnt bei Konflikt', () async {
      final t = ev('Elternabend', DateTime(2026, 11, 20, 19), DateTime(2026, 11, 20, 21));
      final gid = googleOnly('Zahnarzt', DateTime(2026, 11, 18, 8), DateTime(2026, 11, 18, 9));
      await sync().run();
      final copyId = dev.live().firstWhere((x) => x.title == 'Elternabend').id;

      t.title = 'Elternabend Klasse 3';
      dev.rows[gid]!['title'] = 'Zahnarzt Dr. Weiß';
      var r = await sync().run();
      expect(dev.row(copyId).title, 'Elternabend Klasse 3');
      expect(data.byTitle('Zahnarzt Dr. Weiß').calendarKey, google.key);
      expect((r.updatedOut, r.updatedIn), (1, 1));

      // Google ändert die Kopie → App übernimmt
      dev.rows[copyId]!['eventLocation'] = 'Schule';
      await sync().run();
      expect(t.location, 'Schule');

      // Beide ändern die Kopie → App gewinnt
      t.title = 'Elternabend (verlegt)';
      dev.rows[copyId]!['title'] = 'Elternabend ???';
      await sync().run();
      expect(dev.row(copyId).title, 'Elternabend (verlegt)');

      // Sarah ändert einen Google-Termin in der App → geht nach Google
      final z = data.byTitle('Zahnarzt Dr. Weiß');
      z.start = DateTime(2026, 11, 18, 10);
      z.end = DateTime(2026, 11, 18, 11);
      await data.saveEvent(z);
      r = await sync().run();
      expect(dev.row(gid).dtstart, DateTime(2026, 11, 18, 10).millisecondsSinceEpoch);
      expect(r.updatedOut, 1);

      // Sebastian (ältere App) ändert ihn trotzdem → wird zurückgesetzt
      z.title = 'Von Sebastian geändert';
      z.updatedBy = 'Sebastian';
      r = await sync().run();
      expect(z.title, 'Zahnarzt Dr. Weiß');
      expect(dev.row(gid).title, 'Zahnarzt Dr. Weiß');
      expect(r.reverted, 1);
    });

    test('Löschen in beide Richtungen', () async {
      final a = ev('A', DateTime(2026, 11, 20, 9), DateTime(2026, 11, 20, 10));
      ev('B', DateTime(2026, 11, 21, 9), DateTime(2026, 11, 21, 10));
      final g1 = googleOnly('G1', DateTime(2026, 11, 22, 9), DateTime(2026, 11, 22, 10));
      final g2 = googleOnly('G2', DateTime(2026, 11, 23, 9), DateTime(2026, 11, 23, 10));
      await sync().run();
      final copyB = dev.live().firstWhere((x) => x.title == 'B').id;

      await data.deleteEvent(a); // in der App gelöscht
      dev.rows[copyB]!['deleted'] = 1; // Kopie in Google gelöscht
      dev.rows[g1]!['deleted'] = 1; // Google-Termin gelöscht
      final r = await sync().run();
      expect(dev.live().map((x) => x.title), isNot(contains('A')));
      expect(data.events.map((e) => e.title), isNot(contains('B')));
      expect(data.events.map((e) => e.title), isNot(contains('G1')));
      expect((r.deletedOut, r.deletedIn), (1, 2));

      // Sarah löscht G2 in der App (Grabstein) → auch in Google weg
      final e2 = data.byTitle('G2');
      await data.deleteEvent(e2);
      await GoogleSyncState.addTombstone(File('${tmp.path}/sub/state.json'), e2.id);
      await sync().run();
      expect(dev.rows[g2]!['deleted'], 1);
    });

    test('Gelöscht ohne Grabstein (fremd) → wiederhergestellt', () async {
      googleOnly('G', DateTime(2026, 11, 22, 9), DateTime(2026, 11, 22, 10));
      await sync().run();
      await data.deleteEvent(data.byTitle('G'));
      final r = await sync().run();
      expect(data.byTitle('G').calendarKey, google.key);
      expect(r.reverted, 1);
    });

    test('Schutz: verschwinden viele Termine auf einmal, wird nichts gelöscht', () async {
      for (var i = 0; i < 10; i++) {
        googleOnly('G$i', DateTime(2026, 11, 13 + i, 9), DateTime(2026, 11, 13 + i, 10));
      }
      await sync().run();
      for (final id in dev.rows.keys) {
        dev.rows[id]!['deleted'] = 1;
      }
      final r = await sync().run();
      expect(data.inCal(google).length, 10);
      expect(r.warnings.single, contains('zur Sicherheit'));
    });

    test('Serien: abbildbar mit Ausnahme, nicht abbildbar als Einzeltermine', () async {
      final s = DateTime(2026, 11, 5, 18);
      final series = googleOnly('Chor', s, s, more: {
        'dtend': null, 'duration': 'P5400S', 'rrule': 'FREQ=WEEKLY;BYDAY=TH',
        'exdate': '20261126T170000Z',
      });
      // eine Probe verschoben
      googleOnly('Chor (Generalprobe)', DateTime(2026, 11, 20, 18), DateTime(2026, 11, 20, 21), more: {
        'original_id': series, 'originalInstanceTime': DateTime(2026, 11, 19, 18).millisecondsSinceEpoch,
      });
      final odd = googleOnly('Stammtisch', DateTime(2026, 11, 10, 20), DateTime(2026, 11, 10, 23),
          more: {'rrule': 'FREQ=MONTHLY;BYDAY=2TU', 'dtend': null, 'duration': 'P10800S'});
      dev.instanceList[odd] = [
        for (final d in [DateTime(2026, 11, 10, 20), DateTime(2026, 12, 8, 20)])
          (d.millisecondsSinceEpoch, d.add(const Duration(hours: 3)).millisecondsSinceEpoch),
      ];
      final r = await sync().run();
      final chor = data.byTitle('Chor');
      expect(chor.recurrence!.freq, RecurrenceFreq.weekly);
      expect(chor.exdates, containsAll([DateTime(2026, 11, 26), DateTime(2026, 11, 19)]));
      expect(chor.end.difference(chor.start), const Duration(minutes: 90));
      expect(data.byTitle('Chor (Generalprobe)').recurrence, isNull);
      final st = data.events.where((e) => e.title == 'Stammtisch').toList();
      expect(st.length, 2);
      expect(st.every((e) => (e.extra['google'] as Map)['instance'] != null), isTrue);
      expect(r.imported, 4);
      expect((await sync().run()).anything, isFalse);
      // Ein Vorkommen fällt weg
      dev.instanceList[odd] = dev.instanceList[odd]!.take(1).toList();
      await sync().run();
      expect(data.events.where((e) => e.title == 'Stammtisch').length, 1);
    });

    test('Zustand verloren: keine Dubletten, Zuordnung über Markierungen', () async {
      ev('A', DateTime(2026, 11, 20, 9), DateTime(2026, 11, 20, 10));
      googleOnly('G', DateTime(2026, 11, 22, 9), DateTime(2026, 11, 22, 10));
      await sync().run();
      File('${tmp.path}/sub/state.json').deleteSync();
      final r = await sync().run();
      expect(r.anything, isFalse, reason: r.summary);
      expect(dev.live().length, 2);
      expect(data.events.length, 2);
    });

    test('Kalender „nicht übertragen“ entfernt die Kopien; Verschieben aus „Sarah – Google“', () async {
      ev('A', DateTime(2026, 11, 20, 9), DateTime(2026, 11, 20, 10));
      final g = googleOnly('G', DateTime(2026, 11, 22, 9), DateTime(2026, 11, 22, 10));
      await sync().run();
      final off = GoogleSyncConfig(
          importCalendarKey: google.key, importFrom: const [1], defaultTarget: 1, targets: {familie.key: null});
      var r = await sync(config: off).run();
      expect(r.deletedOut, 1);
      expect(dev.live().map((x) => x.title), ['G']);

      // Sarah verschiebt den Google-Termin in „Gemeinsam“ → wird App-Termin mit Kopie
      final e = data.byTitle('G')..calendarId = familie.id;
      await data.saveEvent(e);
      r = await sync().run();
      expect(dev.rows[g]!['deleted'], 1);
      expect(e.extra.containsKey('google'), isFalse);
      final copy = dev.live().singleWhere((x) => x.title == 'G');
      expect(copy.customAppUri, 'kalender://event/${e.id}');
      expect(data.inCal(google), isEmpty);
    });

    test('Ohne Berechtigung: verständlicher Fehler', () async {
      dev.permission = false;
      expect(sync().run(), throwsA(isA<GoogleSyncException>()));
    });
  });
}

String _two(int v) => v.toString().padLeft(2, '0');

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

  @override
  Future<void> setAlerts(int eventId, List<int> minutes) async {
    rows[eventId]!['alerts'] = List.of(minutes);
    rows[eventId]!['hasAlarm'] = minutes.isEmpty ? 0 : 1;
  }
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

  GoogleSync sync({GoogleSyncConfig? config, String me = 'Sarah', bool dryRun = false}) => GoogleSync(
        data: data,
        api: dev,
        me: me,
        dryRun: dryRun,
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
      expect(parseRule('FREQ=MONTHLY;BYDAY=2TU', s)!.byDay, [const NthWeekday(2, 2)]);
      expect(parseRule('FREQ=MONTHLY;BYMONTHDAY=12', s)!.isSimple, isTrue);
      expect(parseRule('FREQ=MONTHLY;BYMONTHDAY=1,15', s)!.byMonthDay, [1, 15]);
      expect(parseRule('FREQ=MONTHLY;BYDAY=2TU;X-NAME=1', s), isNull);
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
          more: {'rrule': 'FREQ=DAILY;INTERVAL=2;BYDAY=TU', 'dtend': null, 'duration': 'P10800S'});
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

    test('Google-Serien wie „2. Dienstag“ werden echte Serien – in beide Richtungen', () async {
      final st = googleOnly('Stammtisch', DateTime(2026, 11, 10, 20), DateTime(2026, 11, 10, 20),
          more: {'rrule': 'FREQ=MONTHLY;WKST=SU;BYDAY=2TU', 'dtend': null, 'duration': 'P10800S'});
      final mf = ev('Monatsabschluss', DateTime(2026, 11, 30, 16), DateTime(2026, 11, 30, 17),
          rec: parseRule('FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1', DateTime(2026, 11, 30)));
      final r = await sync().run();
      expect((r.imported, r.exported), (1, 1));
      final a = data.byTitle('Stammtisch');
      expect(a.recurrence!.byDay, [const NthWeekday(2, 2)]);
      expect(a.isForeignInstance, isFalse);
      final copy = dev.live().firstWhere((x) => x.title == 'Monatsabschluss');
      expect(copy.rrule, 'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1');
      expect((await sync().run()).anything, isFalse);
      // Sarah verschiebt die Serie in der App auf den 3. Dienstag → Google
      a.recurrence = a.recurrence!.copyWith(byDay: [const NthWeekday(2, 3)]);
      a.start = DateTime(2026, 11, 17, 20);
      a.end = DateTime(2026, 11, 17, 23);
      await data.saveEvent(a);
      await sync().run();
      expect(dev.row(st).rrule, 'FREQ=MONTHLY;BYDAY=3TU');
      // Google ändert die Kopie auf „letzter Freitag“ → App
      dev.rows[copy.id]!['rrule'] = 'FREQ=MONTHLY;BYDAY=-1FR';
      dev.rows[copy.id]!['dtstart'] = DateTime(2026, 11, 27, 16).millisecondsSinceEpoch;
      await sync().run();
      expect(mf.recurrence!.byDay, [const NthWeekday(5, -1)]);
      expect((await sync().run()).anything, isFalse);
    });

    test('Bisher einzeln übernommene Serie wird zur echten Serie', () async {
      final st = googleOnly('Stammtisch', DateTime(2026, 11, 10, 20), DateTime(2026, 11, 10, 20),
          more: {'rrule': 'FREQ=MONTHLY;BYDAY=2TU;X-ALT=1', 'dtend': null, 'duration': 'P10800S'});
      dev.instanceList[st] = [
        for (var m = 0; m < 9; m++)
          (DateTime(2026, 11 + m, 1, 20).millisecondsSinceEpoch, DateTime(2026, 11 + m, 1, 23).millisecondsSinceEpoch),
      ];
      await sync().run();
      expect(data.events.where((e) => e.title == 'Stammtisch').length, 9);
      dev.rows[st]!['rrule'] = 'FREQ=MONTHLY;BYDAY=2TU'; // wie nach dem Update lesbar
      final r = await sync().run();
      expect(r.warnings, isEmpty, reason: 'kein Löschschutz – die Serie ersetzt die Einzeltermine');
      final left = data.events.where((e) => e.title == 'Stammtisch').toList();
      expect(left.length, 1);
      expect(left.single.recurrence!.byDay, [const NthWeekday(2, 2)]);
      expect((await sync().run()).anything, isFalse);
    });

    test('Erinnerungen in beide Richtungen; die der Kopien bestimmt die App', () async {
      final cfg = GoogleSyncConfig(importCalendarKey: google.key, importFrom: const [1], defaultTarget: 1, reminders: true);
      final g = googleOnly('Zahnarzt', DateTime(2026, 11, 18, 8), DateTime(2026, 11, 18, 9),
          more: {'alerts': [30, 1440], 'hasAlarm': 1});
      final t = ev('Elternabend', DateTime(2026, 11, 20, 19), DateTime(2026, 11, 20, 21))
        ..reminders = [const Reminder(minutesBefore: 60), const Reminder(minutesBefore: 120, push: false, email: true)];
      await sync(config: cfg).run();
      final z = data.byTitle('Zahnarzt');
      expect([for (final x in z.reminders) (x.minutesBefore, x.push)], [(1440, true), (30, true)]);
      final copyId = dev.live().firstWhere((x) => x.title == 'Elternabend').id;
      expect(dev.row(copyId).alerts, [60], reason: 'nur Push, E-Mail bleibt in der App');
      expect((await sync(config: cfg).run()).anything, isFalse);

      // Sarah ändert die Erinnerung in der App → Google
      z.reminders = [const Reminder(minutesBefore: 10)];
      await data.saveEvent(z);
      await sync(config: cfg).run();
      expect(dev.row(g).alerts, [10]);
      // In Google geändert → App
      await dev.setAlerts(g, [15]);
      await sync(config: cfg).run();
      expect(z.reminders.single.minutesBefore, 15);

      // Google hängt an die Kopie eine Standard-Erinnerung → App bleibt, Kopie zurück
      await dev.setAlerts(copyId, [30]);
      final r = await sync(config: cfg).run();
      expect(r.appChanged, isFalse);
      expect(t.reminders.map((x) => x.minutesBefore), [60, 120]);
      expect(dev.row(copyId).alerts, [60]);
      expect((await sync(config: cfg).run()).anything, isFalse);

      // Ohne Erinnerungs-Abgleich bleibt alles, wie es ist
      await dev.setAlerts(g, [5]);
      expect((await sync().run()).anything, isFalse);
      expect(z.reminders.single.minutesBefore, 15);
    });

    test('Erinnerungen an Google-Termine anderer kommen nicht in den eigenen Google-Kalender', () async {
      ev('Sarahs Zahnarzt', DateTime(2026, 11, 18, 8), DateTime(2026, 11, 18, 9))
        ..extra['google'] = {'event': 4711, 'calendar': 9, 'owner': 'Sarah'}
        ..reminders = [const Reminder(minutesBefore: 30)];
      final cfg = GoogleSyncConfig(importCalendarKey: google.key, importFrom: const [1], defaultTarget: 1, reminders: true);
      await sync(me: 'Sebastian', config: cfg).run();
      expect(dev.live().single.alerts, isEmpty);
      expect((await sync(me: 'Sebastian', config: cfg).run()).anything, isFalse);
    });

    test('Zeitraum „gesamte Vergangenheit“', () async {
      ev('Hochzeit', DateTime(2019, 6, 1, 14), DateTime(2019, 6, 1, 23));
      googleOnly('Abi-Treffen', DateTime(2021, 9, 4, 18), DateTime(2021, 9, 4, 23));
      expect((await sync().run()).anything, isFalse, reason: 'Standard: 90 Tage');
      final all = GoogleSyncConfig(importCalendarKey: google.key, importFrom: const [1], defaultTarget: 1, pastDays: null);
      final r = await sync(config: all).run();
      expect((r.exported, r.imported), (1, 1));
      expect(data.byTitle('Abi-Treffen').calendarKey, google.key);
      expect((await sync(config: all).run()).anything, isFalse);
      // Zurück auf 90 Tage: nichts wird gelöscht
      final back = await sync().run();
      expect(back.deletedIn + back.deletedOut, 0);
      expect(data.events.length, 2);
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

    test('Kalender „nicht übertragen“ entfernt die Kopien; Zuordnen aus „Sarah – Google“', () async {
      ev('A', DateTime(2026, 11, 20, 9), DateTime(2026, 11, 20, 10));
      final g = googleOnly('G', DateTime(2026, 11, 22, 9), DateTime(2026, 11, 22, 10));
      await sync().run();
      final off = GoogleSyncConfig(
          importCalendarKey: google.key, importFrom: const [1], defaultTarget: 1, targets: {familie.key: null});
      var r = await sync(config: off).run();
      expect(r.deletedOut, 1);
      expect(dev.live().map((x) => x.title), ['G']);

      // Sarah ordnet den Google-Termin „Gemeinsam“ zu → bleibt mit Google verbunden
      final e = data.byTitle('G')..calendarId = familie.id;
      expect(e.googleOwner, 'Sarah');
      await data.saveEvent(e);
      r = await sync(config: off).run();
      expect(r.anything, isFalse, reason: r.summary);
      expect(dev.rows[g]!['deleted'], 0, reason: 'das Original bleibt');
      expect(dev.live().map((x) => x.title), ['G'], reason: 'keine zusätzliche Kopie');

      // Änderungen laufen weiter in beide Richtungen
      dev.rows[g]!['title'] = 'G in Google geändert';
      r = await sync(config: off).run();
      expect((e.title, e.calendarKey, r.updatedIn), ('G in Google geändert', familie.key, 1));
      e.location = 'Rathaus';
      await data.saveEvent(e);
      await sync(config: off).run();
      expect(dev.row(g).location, 'Rathaus');

      // Sebastian (ältere App) ändert ihn → zurückgesetzt, bleibt in „Gemeinsam“
      e.title = 'Von Sebastian';
      e.updatedBy = 'Sebastian';
      r = await sync(config: off).run();
      expect((e.title, e.calendarKey, r.reverted), ('G in Google geändert', familie.key, 1));

      // Zustand verloren: findet ihn auch in „Gemeinsam“ wieder, keine Dublette
      File('${tmp.path}/sub/state.json').deleteSync();
      r = await sync(config: off).run();
      expect(r.anything, isFalse, reason: r.summary);
      expect(data.events.where((x) => x.title == 'G in Google geändert').length, 1);

      // Zurück nach „Sarah – Google“ und dort von Sarah gelöscht → auch in Google weg
      e.calendarId = google.id;
      await data.saveEvent(e);
      await data.deleteEvent(e);
      await GoogleSyncState.addTombstone(File('${tmp.path}/sub/state.json'), e.id);
      await sync(config: off).run();
      expect(dev.rows[g]!['deleted'], 1);
    });

    test('Ältere Übernahme ohne Besitzerin wird ergänzt, auch nach dem Zuordnen', () async {
      final g = googleOnly('G', DateTime(2026, 11, 22, 9), DateTime(2026, 11, 22, 10));
      await sync().run();
      final e = data.byTitle('G');
      e.extra['google'] = {'event': g, 'calendar': 1}; // wie Version 0.1.4
      e.calendarId = familie.id;
      final r = await sync().run();
      expect(e.googleOwner, 'Sarah');
      expect(dev.rows[g]!['deleted'], 0);
      expect(r.exported, 0);
    });

    test('Fremder Google-Termin in „Gemeinsam“: Kopie für Sebastian, Änderungen dort zurückgesetzt', () async {
      final e = ev('Sarahs Zahnarzt', DateTime(2026, 11, 18, 8), DateTime(2026, 11, 18, 9))
        ..extra['google'] = {'event': 4711, 'calendar': 9, 'owner': 'Sarah'};
      final r = await sync(me: 'Sebastian').run();
      expect(r.exported, 1);
      final copy = dev.live().single;
      expect(copy.title, 'Sarahs Zahnarzt');
      dev.rows[copy.id]!['title'] = 'Von Sebastian in Google geändert';
      final r2 = await sync(me: 'Sebastian').run();
      expect(e.title, 'Sarahs Zahnarzt', reason: 'nur Sarah ändert ihn');
      expect(dev.row(copy.id).title, 'Sarahs Zahnarzt');
      expect((r2.updatedIn, r2.updatedOut), (0, 1));
    });

    test('Neu in „Sarah – Google“ angelegt (ohne Original) → landet als Kopie in Google', () async {
      final e = ev('Direkt angelegt', DateTime(2026, 11, 24, 9), DateTime(2026, 11, 24, 10), cal: google);
      final r = await sync().run();
      expect(r.exported, 1);
      expect(dev.live().single.customAppUri, 'kalender://event/${e.id}');
      expect((await sync().run()).anything, isFalse);
    });

    test('Probelauf ändert nichts, zeigt aber jeden Termin', () async {
      ev('Elternabend', DateTime(2026, 11, 20, 19), DateTime(2026, 11, 20, 21));
      googleOnly('Zahnarzt', DateTime(2026, 11, 18, 8), DateTime(2026, 11, 18, 9));
      final rowsBefore = dev.rows.length;
      final titleBefore = data.events.single.title;
      final r = await sync(dryRun: true).run();
      expect((r.exported, r.imported), (1, 1));
      expect(r.log, contains('→ Google neu: Elternabend (20.11.2026)'));
      expect(r.log, contains('← Google neu: Zahnarzt (18.11.2026)'));
      expect(dev.rows.length, rowsBefore, reason: 'nichts im Handy-Kalender angelegt');
      expect(data.events.length, 1, reason: 'nichts in der App angelegt');
      expect(data.events.single.title, titleBefore);
      expect(File('${tmp.path}/sub/state.json').existsSync(), isFalse, reason: 'kein Zustand gespeichert');
      final real = await sync().run();
      expect((real.exported, real.imported), (1, 1));
      // Nach dem echten Lauf hat der Probelauf nichts mehr zu tun
      expect((await sync(dryRun: true).run()).anything, isFalse);
    });

    test('Probelauf mit Änderungen fasst die echten Termine nicht an', () async {
      final t = ev('Elternabend', DateTime(2026, 11, 20, 19), DateTime(2026, 11, 20, 21));
      await sync().run();
      final copyId = dev.live().single.id;
      dev.rows[copyId]!['title'] = 'In Google umbenannt';
      final r = await sync(dryRun: true).run();
      expect(r.updatedIn, 1);
      expect(t.title, 'Elternabend', reason: 'App-Termin unverändert');
      await data.deleteEvent(t);
      final r2 = await sync(dryRun: true).run();
      expect(r2.deletedOut, 1);
      expect(dev.rows[copyId]!['deleted'], 0, reason: 'Kopie nicht gelöscht');
    });

    test('Ein gleich aussehender eigener Google-Termin wird nie als Kopie behandelt', () async {
      final s = DateTime(2026, 11, 20, 19), e = DateTime(2026, 11, 20, 21);
      final app = ev('Elternabend', s, e);
      final own = googleOnly('Elternabend', s, e); // selbst in Google eingetragen
      await sync().run();
      expect(dev.live().where((x) => x.title == 'Elternabend').length, 2);
      await data.deleteEvent(app); // jemand löscht den App-Termin
      await sync().run();
      expect(dev.rows[own]!['deleted'], 0, reason: 'der eigene Google-Termin bleibt');
      expect(data.inCal(google).single.title, 'Elternabend');
    });

    test('Ohne Berechtigung: verständlicher Fehler', () async {
      dev.permission = false;
      expect(sync().run(), throwsA(isA<GoogleSyncException>()));
    });
  });
}

String _two(int v) => v.toString().padLeft(2, '0');

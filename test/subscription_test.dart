import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:encrypted_calendar_app/src/core/crypto_service.dart';
import 'package:encrypted_calendar_app/src/core/doc_store.dart';
import 'package:encrypted_calendar_app/src/models/calendar_models.dart';
import 'package:encrypted_calendar_app/src/settings.dart';
import 'package:encrypted_calendar_app/src/sync/abo_presets.dart';
import 'package:encrypted_calendar_app/src/sync/ics.dart';
import 'package:encrypted_calendar_app/src/sync/ics_fetch.dart';
import 'package:encrypted_calendar_app/src/sync/subscription_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// So liefert die Abfallwirtschaft Germersheim ihre Termine (gekürzt): Termine
/// um Mitternacht ohne Dauer, Titel mit Leerzeichen am Ende, wechselnde UIDs,
/// die Zeitzone am Ende der Datei.
String germersheim(List<(String, String)> events, {String uidSeed = 'a'}) {
  final b = StringBuffer('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//eluceo/ical//2.0/EN\r\nCALSCALE:GREGORIAN\r\n');
  var i = 0;
  for (final (day, title) in events) {
    b.write('BEGIN:VEVENT\r\n'
        'UID:$uidSeed${i++}f0c1d2e3\r\n'
        'DTSTAMP:20261122T101500Z\r\n'
        'SUMMARY:$title \r\n'
        'DESCRIPTION:$title \r\n'
        'DTSTART;TZID=Europe/Berlin:${day}T000000\r\n'
        'DTEND;TZID=Europe/Berlin:${day}T000000\r\n'
        'LOCATION:Minfeld\r\n'
        'END:VEVENT\r\n');
  }
  b.write('BEGIN:VTIMEZONE\r\nTZID:Europe/Berlin\r\nBEGIN:STANDARD\r\nDTSTART:19701025T030000\r\n'
      'TZOFFSETFROM:+0200\r\nTZOFFSETTO:+0100\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nEND:VCALENDAR\r\n');
  return b.toString();
}

/// Speicher im Arbeitsspeicher mit echten deterministischen IDs.
class MemoryData implements SubscriptionData {
  MemoryData(this.key);
  final SecretKey key;
  final crypto = CryptoService();
  final Map<String, CalendarEvent> events = {};
  var saves = 0, deletes = 0;

  @override
  List<CalendarEvent> eventsOf(CalendarDef cal) =>
      events.values.where((e) => e.calendarId == cal.id).toList();
  @override
  Future<String> eventId(CalendarDef cal, String key) => crypto.deterministicId('abo|${cal.id}|$key', this.key);
  @override
  Future<void> saveEvent(CalendarEvent e) async {
    saves++;
    e.updatedAt = DateTime.now();
    e.updatedBy = 'Test';
    // wie im Repo: als Dokument speichern und neu einlesen
    events[e.id] = CalendarEvent.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>, e.sourceId);
  }

  @override
  Future<void> deleteEvent(CalendarEvent e) async {
    deletes++;
    events.remove(e.id);
  }
}

void main() {
  group('ICS lesen', () {
    test('Abfallkalender Germersheim: Mitternacht ohne Dauer = ganztägig', () {
      final events = parseIcs(germersheim([('20261124', 'Bioabfall'), ('20261201', 'Restmüll')]));
      expect(events, hasLength(2));
      final e = events.first;
      expect(e.allDay, isTrue);
      expect(e.start, DateTime(2026, 11, 24));
      expect(e.end, DateTime(2026, 11, 24));
      expect(e.summary, 'Bioabfall');
      expect(e.description, 'Bioabfall');
      expect(e.location, 'Minfeld');
      expect(events.last.summary, 'Restmüll');
    });

    test('Datum, Zeit in UTC, Faltung, Escapes, abgesagt', () {
      const ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\nUID:1\nSUMMARY:Herbstferien\nDTSTART;VALUE=DATE:20261102\nDTEND;VALUE=DATE:20261107\nEND:VEVENT\n'
          'BEGIN:VEVENT\nUID:2\nSUMMARY:Elternabend\\, Klasse 3\nDESCRIPTION:Zeile 1\\nZeile 2\n'
          'DTSTART:20261110T180000Z\nDTEND:20261110T193000Z\nLOCATION:Schule\\; Aula\n'
          'BEGIN:VALARM\nTRIGGER:-PT15M\nDESCRIPTION:Alarm\nEND:VALARM\nEND:VEVENT\n'
          'BEGIN:VEVENT\nUID:3\nSUMMARY:Ein sehr langer \n Titel\nDTSTART;VALUE=DATE:20261201\nEND:VEVENT\n'
          'BEGIN:VEVENT\nUID:4\nSTATUS:CANCELLED\nSUMMARY:Fällt aus\nDTSTART;VALUE=DATE:20261202\nEND:VEVENT\n'
          'BEGIN:VEVENT\nUID:5\nSUMMARY:Kurs\nDTSTART:20261203T090000\nDURATION:PT1H30M\nEND:VEVENT\n'
          'END:VCALENDAR\n';
      final events = parseIcs(ics);
      expect(events.map((e) => e.summary), ['Herbstferien', 'Elternabend, Klasse 3', 'Ein sehr langer Titel', 'Kurs']);
      final ferien = events[0];
      expect(ferien.allDay, isTrue);
      expect(ferien.start, DateTime(2026, 11, 2));
      expect(ferien.end, DateTime(2026, 11, 6), reason: 'DTEND ist exklusiv');
      final abend = events[1];
      expect(abend.allDay, isFalse);
      expect(abend.start, DateTime.utc(2026, 11, 10, 18).toLocal());
      expect(abend.end, DateTime.utc(2026, 11, 10, 19, 30).toLocal());
      expect(abend.description, 'Zeile 1\nZeile 2');
      expect(abend.location, 'Schule; Aula');
      expect(events[2].allDay, isTrue);
      expect(events[2].end, DateTime(2026, 12, 1));
      expect(events[3].end, DateTime(2026, 12, 3, 10, 30));
    });

    test('Serie mit Ausnahme und geändertem Einzeltermin', () {
      const ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\nUID:s1\nSUMMARY:Training\nDTSTART:20261104T180000\nDTEND:20261104T193000\n'
          'RRULE:FREQ=WEEKLY;COUNT=10\nEXDATE:20261111T180000\nEND:VEVENT\n'
          'BEGIN:VEVENT\nUID:s1\nRECURRENCE-ID:20261118T180000\nSUMMARY:Training (Halle 2)\n'
          'DTSTART:20261118T190000\nDTEND:20261118T203000\nEND:VEVENT\n'
          'BEGIN:VEVENT\nUID:s1\nRECURRENCE-ID:20261125T180000\nSTATUS:CANCELLED\nSUMMARY:Training\n'
          'DTSTART:20261125T180000\nEND:VEVENT\n'
          'END:VCALENDAR\n';
      final events = parseIcs(ics);
      expect(events, hasLength(2));
      final series = events.first;
      expect(series.recurrence?.freq, RecurrenceFreq.weekly);
      expect(series.recurrence?.count, 10);
      expect(series.exdates, [DateTime(2026, 11, 11), DateTime(2026, 11, 18), DateTime(2026, 11, 25)]);
      expect(events.last.summary, 'Training (Halle 2)');
      expect(events.last.recurrence, isNull);
    });

    test('keine Kalenderdatei', () {
      expect(() => parseIcs('<html></html>'), throwsFormatException);
    });
  });

  group('ICS abrufen', () {
    const page = '<html><body><h1>ICS-Export</h1>'
        '<form action="/suche" method="get"><input type="text" name="q"></form>'
        '<form method="POST">'
        '<input type="hidden" name="ICS_DOWNLOAD" value="9dcb88e0137649590b755372b040afad">'
        '<input type="hidden" name="REQUEST_TOKEN" value="tok&amp;123">'
        '<button type="submit">Als ICS herunterladen</button></form></body></html>';

    test('Seite mit Download-Formular: Formular wird abgeschickt', () async {
      final url = GermersheimWaste.url(place: 'Minfeld', types: ['Restmüll', 'Gelber Sack']);
      http.Request? post;
      final client = MockClient((req) async {
        if (req.method == 'GET') {
          expect(req.url.queryParametersAll['icsabfallart[]'], ['Restmüll', 'Gelber Sack']);
          return http.Response(page, 200,
              headers: {'content-type': 'text/html; charset=utf-8', 'set-cookie': 'sid=abc; path=/; HttpOnly'});
        }
        post = req;
        return http.Response.bytes(utf8.encode(germersheim([('20261124', 'Restmüll')])), 200,
            headers: {'content-type': 'text/calendar; charset=utf-8'});
      });
      final ics = await fetchIcs(url, client: client);
      expect(parseIcs(ics).single.summary, 'Restmüll');
      expect(post, isNotNull);
      expect(post!.url.toString(), Uri.parse(url).toString(), reason: 'leere action = dieselbe Seite');
      expect(post!.bodyFields, {'ICS_DOWNLOAD': '9dcb88e0137649590b755372b040afad', 'REQUEST_TOKEN': 'tok&123'});
      expect(post!.headers['Cookie'], 'sid=abc');
      expect(post!.headers['Origin'], 'https://www.abfallwirtschaft-germersheim.de');
    });

    test('direkte Datei und webcal://', () async {
      Uri? asked;
      final client = MockClient((req) async {
        asked = req.url;
        return http.Response.bytes(utf8.encode(germersheim([('20261124', 'Papier')])), 200);
      });
      final ics = await fetchIcs('webcal://example.org/ferien.ics', client: client);
      expect(asked.toString(), 'https://example.org/ferien.ics');
      expect(parseIcs(ics).single.summary, 'Papier');
    });

    test('Fehler werden verständlich gemeldet', () async {
      final notFound = MockClient((req) async => http.Response('nope', 404));
      await expectLater(fetchIcs('https://example.org/x.ics', client: notFound),
          throwsA(isA<IcsFetchException>().having((e) => e.message, 'message', contains('404'))));
      final html = MockClient((req) async => http.Response('<html>Hallo</html>', 200));
      await expectLater(fetchIcs('https://example.org/', client: html), throwsA(isA<IcsFetchException>()));
      await expectLater(fetchIcs('ftp://example.org/x.ics', client: html), throwsA(isA<IcsFetchException>()));
    });

    test('Germersheim-Adresse zurücklesen', () {
      final url = GermersheimWaste.url(place: 'Hördt', types: ['Gelber Cont.', 'Problemmüll'], large: true);
      expect(url, contains('ueber-240-liter'));
      final p = GermersheimWaste.parse(url)!;
      expect(p.place, 'Hördt');
      expect(p.types, ['Gelber Cont.', 'Problemmüll']);
      expect(p.large, isTrue);
      expect(GermersheimWaste.parse('https://example.org/x.ics'), isNull);
    });
  });

  group('Abo abgleichen', () {
    late SecretKey key;
    late CalendarDef cal;
    final today = DateTime(2026, 11, 22, 15);

    setUp(() async {
      key = SecretKey(List.generate(32, (i) => i));
      cal = CalendarDef(
        id: 'muell',
        sourceId: 'q1',
        name: 'Müllabfuhr',
        color: 0xFFF08C3A,
        subscription: {'url': 'https://example.org', 'label': 'Abfallwirtschaft Germersheim'},
        defaultReminders: [const Reminder(minutesBefore: 840)],
        colorLabels: [
          const ColorLabel(color: 0xFF78909C, label: 'Restmüll'),
          const ColorLabel(color: 0xFF8D6E63, label: 'Bioabfall'),
        ],
      );
    });

    Future<SubscriptionResult> apply(MemoryData d, List<(String, String)> feed) =>
        SubscriptionSync(d, now: () => today).apply(cal, parseIcs(germersheim(feed, uidSeed: '${d.saves}')));

    test('legt Termine mit Farbe und Erinnerung an; zweiter Abruf ändert nichts', () async {
      final d = MemoryData(key);
      final r = await apply(d, [('20261124', 'Bioabfall'), ('20261124', 'Papier'), ('20261201', 'Restmüll')]);
      expect(r.added, 3);
      expect(r.summary, '3 Termine – 3 neu');
      final bio = d.events.values.firstWhere((e) => e.title == 'Bioabfall');
      expect(bio.allDay, isTrue);
      expect(bio.start, DateTime(2026, 11, 24));
      expect(bio.color, 0xFF8D6E63);
      expect(bio.reminders, [const Reminder(minutesBefore: 840)]);
      expect(bio.description, '', reason: 'Beschreibung = Titel bringt nichts');
      expect(bio.location, 'Minfeld');
      expect(bio.calendarKey, cal.key);
      expect(d.events.values.firstWhere((e) => e.title == 'Papier').color, isNull);

      final saves = d.saves;
      final again = await apply(d, [('20261124', 'Bioabfall'), ('20261124', 'Papier'), ('20261201', 'Restmüll')]);
      expect(again.changedAny, isFalse);
      expect(again.summary, '3 Termine, unverändert');
      expect(d.saves, saves, reason: 'neue UIDs der Datei ändern nichts');
    });

    test('verlegter Termin: alter (künftig) weg, neuer da; Vergangenes und Heutiges bleibt', () async {
      final d = MemoryData(key);
      await apply(d, [('20261115', 'Restmüll'), ('20261122', 'Bioabfall'), ('20261124', 'Papier'), ('20261201', 'Restmüll')]);
      expect(d.events, hasLength(4));
      // Der Kreis liefert nur „ab heute“; Papier ist vom 24. auf den 25. verlegt.
      final r = await apply(d, [('20261125', 'Papier'), ('20261201', 'Restmüll')]);
      expect(r.added, 1);
      expect(r.removed, 1);
      expect(d.events.values.map((e) => '${isoDate(e.start)} ${e.title}').toList()..sort(),
          ['2026-11-15 Restmüll', '2026-11-22 Bioabfall', '2026-11-25 Papier', '2026-12-01 Restmüll']);
    });

    test('leere Datei entfernt nichts', () async {
      final d = MemoryData(key);
      await apply(d, [('20261124', 'Papier')]);
      final r = await apply(d, []);
      expect(r.changedAny, isFalse);
      expect(d.events, hasLength(1));
    });

    test('Datei mit Vergangenheit gilt ab ihrem frühesten Termin', () async {
      final d = MemoryData(key);
      await apply(d, [('20260105', 'Restmüll'), ('20261110', 'Papier'), ('20261201', 'Restmüll')]);
      final r = await apply(d, [('20260105', 'Restmüll'), ('20261201', 'Restmüll')]);
      expect(r.removed, 1, reason: 'Papier am 10.11. fehlt in einer vollständigen Datei');
      expect(d.events, hasLength(2));
    });

    test('geänderte Farben und Erinnerungen des Kalenders gelten beim nächsten Abruf', () async {
      final d = MemoryData(key);
      await apply(d, [('20261124', 'Papier')]);
      cal.colorLabels = [...cal.colorLabels, const ColorLabel(color: 0xFF4A74D9, label: 'Papier')];
      cal.defaultReminders = [const Reminder(minutesBefore: 840), const Reminder(minutesBefore: 0)];
      final r = await apply(d, [('20261124', 'Papier')]);
      expect(r.changed, 1);
      final e = d.events.values.single;
      expect(e.color, 0xFF4A74D9);
      expect(e.reminders, hasLength(2));
    });

    test('zwei Handys erzeugen dieselben Dokumente (keine Doppelten, keine Konflikte)', () async {
      final a = MemoryData(key), b = MemoryData(key);
      final feed = [('20261124', 'Bioabfall'), ('20261201', 'Restmüll')];
      await apply(a, feed);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await apply(b, feed);
      expect(a.events.keys.toSet(), b.events.keys.toSet());
      for (final id in a.events.keys) {
        expect(sameDocContent(a.events[id]!.toJson(), b.events[id]!.toJson()), isTrue);
      }
      // anderer Kalender → andere IDs
      final other = MemoryData(key);
      final cal2 = CalendarDef(id: 'muell2', sourceId: 'q1', name: 'X', color: 0, subscription: const {'url': 'x'});
      await SubscriptionSync(other, now: () => today).apply(cal2, parseIcs(germersheim(feed)));
      expect(other.events.keys.toSet().intersection(a.events.keys.toSet()), isEmpty);
    });
  });

  test('Abruf fällig?', () {
    final now = DateTime(2026, 11, 22, 12);
    expect(SubscriptionService.isDue(null, now), isTrue);
    final ok = SubscriptionStatus(lastOk: now.subtract(const Duration(hours: 2)), lastTry: now.subtract(const Duration(hours: 2)));
    expect(SubscriptionService.isDue(ok, now), isFalse);
    ok.lastOk = ok.lastTry = now.subtract(const Duration(hours: 13));
    expect(SubscriptionService.isDue(ok, now), isTrue);
    final failed = SubscriptionStatus(lastOk: now.subtract(const Duration(hours: 20)), lastTry: now.subtract(const Duration(minutes: 20)), error: 'x');
    expect(SubscriptionService.isDue(failed, now), isFalse, reason: 'nach Fehler eine Stunde Pause');
    failed.lastTry = now.subtract(const Duration(minutes: 70));
    expect(SubscriptionService.isDue(failed, now), isTrue);
  });
}

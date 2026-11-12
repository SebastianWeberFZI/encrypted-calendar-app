import 'package:encrypted_calendar_app/src/models/calendar_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dokumente älterer und neuerer App-Versionen: tolerant lesen, verlustfrei
/// zurückschreiben.
void main() {
  test('Minimaler Termin einer frühen Version wird gelesen', () {
    final e = CalendarEvent.fromJson(
        {'id': 'a', 'calendar_id': 'c', 'start': '2026-11-17'}, 's');
    expect(e.title, '');
    expect(e.allDay, isFalse);
    expect(e.end, e.start);
    expect(e.reminders, isEmpty);
  });

  test('Unbekannte Felder eines neueren Termins bleiben erhalten', () {
    final j = {
      'id': 'a',
      'calendar_id': 'c',
      'title': 'Urlaub',
      'all_day': true,
      'start': '2026-11-17',
      'end': '2026-11-28',
      'attendees': ['Sarah'],
      'reminders': [
        {'minutes_before': 60, 'push': true, 'sound': 'gong'}
      ],
      'schema_version': 3,
    };
    final e = CalendarEvent.fromJson(j, 's');
    e.title = 'Urlaub Toskana';
    final out = e.toJson();
    expect(out['attendees'], ['Sarah']);
    expect(out['title'], 'Urlaub Toskana');
    expect((out['reminders'] as List).single['sound'], 'gong');
    expect(out['schema_version'], kSchemaVersion);
  });

  test('Unbekannte Wiederholungsart: Termin einmal anzeigen, Regel behalten', () {
    final j = {
      'id': 'a',
      'calendar_id': 'c',
      'start': '2026-11-17T10:00',
      'recurrence': {'freq': 'hourly', 'interval': 2},
    };
    final e = CalendarEvent.fromJson(j, 's');
    expect(e.recurrence, isNull);
    expect(e.toJson()['recurrence'], {'freq': 'hourly', 'interval': 2});
    // Wer hier eine neue Regel festlegt, ersetzt die unbekannte.
    e.recurrence = const Recurrence(freq: RecurrenceFreq.daily);
    expect(e.toJson()['recurrence']['freq'], 'daily');
  });

  test('Unbekannte Regelteile bleiben erhalten, solange die Regel gleich bleibt', () {
    final e = CalendarEvent.fromJson({
      'id': 'a',
      'calendar_id': 'c',
      'start': '2026-11-17T10:00',
      'recurrence': {'freq': 'monthly', 'by_set_pos': -1},
    }, 's');
    expect(e.recurrence!.freq, RecurrenceFreq.monthly);
    expect(e.toJson()['recurrence']['by_set_pos'], -1);
  });

  test('Falsche Typen führen zu Standardwerten statt Absturz', () {
    final e = CalendarEvent.fromJson({
      'id': 'a',
      'calendar_id': 7,
      'title': 42,
      'all_day': 'ja',
      'start': '2026-11-17T10:00',
      'end': 'morgen',
      'color': '123',
      'reminders': 'keine',
      'exdates': [1, '2026-11-24', null],
      'recurrence': 'weekly',
      'created_at': 5,
    }, 's');
    expect(e.title, '');
    expect(e.calendarId, '');
    expect(e.allDay, isFalse);
    expect(e.end, e.start);
    expect(e.color, 123);
    expect(e.reminders, isEmpty);
    expect(e.exdates, [DateTime(2026, 11, 24)]);
    expect(e.recurrence, isNull);
  });

  test('ID kommt aus dem Dateinamen, Termin ohne Beginn wird abgelehnt', () {
    final e = CalendarEvent.fromJson(
        {'calendar_id': 'c', 'start': '2026-11-17'}, 's', path: 'events/xyz.enc');
    expect(e.id, 'xyz');
    expect(() => CalendarEvent.fromJson({'id': 'a'}, 's'), throwsFormatException);
    expect(() => CalendarEvent.fromJson({'start': '2026-11-17'}, 's'), throwsFormatException);
  });

  test('Unbekannte Kalenderart bleibt erhalten, bis sie geändert wird', () {
    final c = CalendarDef.fromJson({
      'id': 'k',
      'name': 'Aufgaben',
      'kind': 'tasks',
      'color_labels': [
        {'color': 1, 'label': 'Dringend', 'icon': 'flag'},
        'kaputt',
      ],
      'share': {'with': 'Sarah'},
    }, 's');
    expect(c.kind, CalendarKind.standard);
    expect(c.toJson()['kind'], 'tasks');
    expect(c.toJson()['share'], {'with': 'Sarah'});
    expect(c.colorLabels.single.toJson()['icon'], 'flag');
    c.kind = CalendarKind.birthdays;
    expect(c.toJson()['kind'], 'birthdays');
  });

  test('copy() übernimmt unbekannte Felder', () {
    final e = CalendarEvent.fromJson(
        {'id': 'a', 'calendar_id': 'c', 'start': '2026-11-17', 'x': 1}, 's');
    final c = e.copy(id: 'b');
    expect(c.id, 'b');
    expect(c.toJson()['x'], 1);
  });
}

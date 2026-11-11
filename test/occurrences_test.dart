import 'package:encrypted_calendar_app/src/models/calendar_models.dart';
import 'package:encrypted_calendar_app/src/models/holidays.dart';
import 'package:encrypted_calendar_app/src/models/occurrences.dart';
import 'package:encrypted_calendar_app/src/models/week_layout.dart';
import 'package:flutter_test/flutter_test.dart';

CalendarEvent ev(DateTime s, DateTime e, {Recurrence? rec, bool allDay = false, List<DateTime>? ex}) =>
    CalendarEvent(sourceId: 's', calendarId: 'c', title: 'T', start: s, end: e,
        allDay: allDay, recurrence: rec, exdates: ex);

List<String> days(CalendarEvent e, DateTime from, DateTime to) =>
    occurrenceStarts(e, from, to).map(isoDate).toList();

void main() {
  group('Wiederholungen', () {
    test('wöchentlich an Di+Do, 5 Vorkommen', () {
      final e = ev(DateTime(2026, 11, 3, 18), DateTime(2026, 11, 3, 19),
          rec: const Recurrence(freq: RecurrenceFreq.weekly, byWeekday: [2, 4], count: 5));
      expect(days(e, DateTime(2026, 11, 1), DateTime(2027, 1, 1)),
          ['2026-11-03', '2026-11-05', '2026-11-10', '2026-11-12', '2026-11-17']);
    });

    test('alle 2 Wochen, mit ausgelassenem Termin', () {
      final e = ev(DateTime(2026, 11, 5), DateTime(2026, 11, 5), allDay: true,
          rec: const Recurrence(freq: RecurrenceFreq.weekly, interval: 2),
          ex: [DateTime(2026, 11, 19)]);
      expect(days(e, DateTime(2026, 11, 1), DateTime(2026, 12, 20)),
          ['2026-11-05', '2026-12-03', '2026-12-17']);
    });

    test('täglich bis Datum; Sprung in die Zukunft liefert dasselbe', () {
      final e = ev(DateTime(2020, 1, 1, 7), DateTime(2020, 1, 1, 8),
          rec: const Recurrence(freq: RecurrenceFreq.daily, interval: 3));
      final far = days(e, DateTime(2026, 11, 10), DateTime(2026, 11, 20));
      final all = days(e, DateTime(2020, 1, 1), DateTime(2026, 11, 20))
          .where((d) => d.compareTo('2026-11-10') >= 0)
          .toList();
      expect(far, all);
      expect(far, isNotEmpty);
    });

    test('monatlich am 31. überspringt kurze Monate', () {
      final e = ev(DateTime(2026, 1, 31, 9), DateTime(2026, 1, 31, 10),
          rec: const Recurrence(freq: RecurrenceFreq.monthly));
      expect(days(e, DateTime(2026, 1, 1), DateTime(2026, 6, 1)),
          ['2026-01-31', '2026-03-31', '2026-05-31']);
    });

    test('Geburtstag am 29.2. erscheint in Nicht-Schaltjahren am 28.2.', () {
      final e = ev(DateTime(2000, 2, 29), DateTime(2000, 2, 29), allDay: true,
          rec: const Recurrence(freq: RecurrenceFreq.yearly));
      expect(days(e, DateTime(2027, 1, 1), DateTime(2029, 1, 1)), ['2027-02-28', '2028-02-29']);
    });

    test('mehrtägiger Termin berührt Zeitraum, der mitten drin beginnt', () {
      final e = ev(DateTime(2026, 11, 27), DateTime(2026, 12, 2), allDay: true);
      expect(days(e, DateTime(2026, 12, 1), DateTime(2027, 1, 1)), ['2026-11-27']);
    });

    test('Alter im Geburtstagskalender', () {
      final cal = CalendarDef(sourceId: 's', id: 'c', name: 'G', color: 0, kind: CalendarKind.birthdays);
      final e = ev(DateTime(1990, 5, 4), DateTime(1990, 5, 4), allDay: true,
          rec: const Recurrence(freq: RecurrenceFreq.yearly))..birthYear = 1990;
      final occ = expandOccurrences([e], {cal.key: cal}, DateTime(2026, 5, 1), DateTime(2026, 6, 1));
      expect(occ.single.title, 'T (36)');
    });

    test('Erinnerung bei ganztägigem Termin bezieht sich auf 9:00', () {
      final o = Occurrence(null, null, DateTime(2026, 11, 12), DateTime(2026, 11, 12));
      expect(reminderTime(o, const Reminder(minutesBefore: 1440)), DateTime(2026, 11, 11, 9));
    });
  });

  group('Monatsraster', () {
    test('mehrtägige Balken teilen sich keinen Slot, Überlauf wird gezählt', () {
      final ws = DateTime(2026, 11, 9); // Montag
      Occurrence o(int s, int e, {bool allDay = true}) => Occurrence(
          ev(DateTime(2026, 11, s, allDay ? 0 : 10), DateTime(2026, 11, e, allDay ? 0 : 11), allDay: allDay),
          null, DateTime(2026, 11, s, allDay ? 0 : 10), DateTime(2026, 11, e, allDay ? 0 : 11));
      final a = o(9, 11), b = o(10, 12), c = o(10, 10, allDay: false), d = o(10, 10, allDay: false);
      final l = layoutWeek(ws, [a, b, c, d], 3);
      final slotOf = {for (final it in l.visible) it.occ: it.slot};
      expect(slotOf[a], 0);
      expect(slotOf[b], 1);
      // Dienstag hat 4 Einträge bei 3 Slots -> letzter Slot wird "+N"
      expect(l.hiddenPerCol[1], 2);
      expect(l.visible.where((it) => it.startCol <= 1 && it.endCol >= 1).length, 2);
    });

    test('Balken aus der Vorwoche ist links offen', () {
      final ws = DateTime(2026, 11, 9);
      final occ = Occurrence(ev(DateTime(2026, 11, 7), DateTime(2026, 11, 10), allDay: true), null,
          DateTime(2026, 11, 7), DateTime(2026, 11, 10));
      final it = layoutWeek(ws, [occ], 4).visible.single;
      expect(it.startCol, 0);
      expect(it.endCol, 1);
      expect(it.continuesLeft, isTrue);
      expect(it.continuesRight, isFalse);
    });
  });

  group('Farbbedeutungen', () {
    test('werden mit dem Kalender gespeichert und je Kalender aufgelöst', () {
      final cal = CalendarDef(sourceId: 's', id: 'c', name: 'Gemeinsam', color: 0xFF2E9C8E,
          colorLabels: const [ColorLabel(color: 0xFF4A74D9, label: 'Arzt')]);
      final back = CalendarDef.fromJson(cal.toJson(), 's');
      expect(back.colorLabels.single.label, 'Arzt');
      expect(back.labelFor(0xFF4A74D9), 'Arzt');
      expect(back.labelFor(0xFFE05A5A), isNull);
      final other = CalendarDef(sourceId: 's', id: 'd', name: 'Arbeit', color: 0,
          colorLabels: const [ColorLabel(color: 0xFF4A74D9, label: 'Meeting')]);
      final e1 = ev(DateTime(2026, 11, 12, 9), DateTime(2026, 11, 12, 10))..color = 0xFF4A74D9;
      expect(Occurrence(e1, back, e1.start, e1.end).colorLabel, 'Arzt');
      expect(Occurrence(e1, other, e1.start, e1.end).colorLabel, 'Meeting');
      expect(Occurrence(ev(e1.start, e1.end), back, e1.start, e1.end).colorLabel, isNull);
    });
  });

  group('Feiertage', () {
    test('Ostern und bewegliche Feiertage 2026', () {
      expect(easterSunday(2026), DateTime(2026, 4, 5));
      final bw = holidaysFor(2026, 'BW');
      expect(bw[DateTime(2026, 6, 4)], 'Fronleichnam');
      expect(bw[DateTime(2026, 1, 6)], 'Heilige Drei Könige');
      expect(bw.containsKey(DateTime(2026, 10, 31)), isFalse);
      expect(holidaysFor(2026, 'SN')[DateTime(2026, 11, 18)], 'Buß- und Bettag');
    });
  });
}

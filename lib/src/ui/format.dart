import '../models/calendar_models.dart';
import '../models/occurrences.dart';

const kWeekdaysShort = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
const kWeekdays = [
  'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'
];
const kMonths = [
  'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August',
  'September', 'Oktober', 'November', 'Dezember'
];
const kMonthsShort = [
  'Jan.', 'Feb.', 'März', 'Apr.', 'Mai', 'Juni', 'Juli', 'Aug.', 'Sep.',
  'Okt.', 'Nov.', 'Dez.'
];

String two(int v) => v.toString().padLeft(2, '0');
String fmtTime(DateTime d) => '${two(d.hour)}:${two(d.minute)}';
String fmtDate(DateTime d) => '${two(d.day)}.${two(d.month)}.${d.year}';
String fmtDateShort(DateTime d) => '${d.day}. ${kMonthsShort[d.month - 1]}';
String fmtDateLong(DateTime d) =>
    '${kWeekdays[d.weekday - 1]}, ${d.day}. ${kMonths[d.month - 1]} ${d.year}';
String fmtDayHeader(DateTime d) =>
    '${kWeekdays[d.weekday - 1]}, ${d.day}. ${kMonths[d.month - 1]}';
String fmtMonthYear(DateTime d) => '${kMonths[d.month - 1]} ${d.year}';

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// "Heute", "Morgen", "Gestern" oder Wochentag + Datum.
String relativeDay(DateTime d, {DateTime? now}) {
  final today = dateOnly(now ?? DateTime.now());
  final diff = dateOnly(d).difference(today).inDays;
  if (diff == 0) return 'Heute';
  if (diff == 1) return 'Morgen';
  if (diff == -1) return 'Gestern';
  return fmtDayHeader(d);
}

/// Zeitangabe eines Vorkommens: "ganztägig", "14:00–15:30", "12.–14. Nov.".
String occurrenceTimeText(Occurrence o, {DateTime? day}) {
  if (o.isMultiDay) {
    final range = '${fmtDateShort(o.startDay)} – ${fmtDateShort(o.endDay)}';
    if (o.allDay) return range;
    if (day != null && sameDay(day, o.start)) return 'ab ${fmtTime(o.start)}';
    if (day != null && sameDay(day, o.end)) return 'bis ${fmtTime(o.end)}';
    return range;
  }
  if (o.allDay) return 'ganztägig';
  if (o.end.isAtSameMomentAs(o.start)) return fmtTime(o.start);
  return '${fmtTime(o.start)}–${fmtTime(o.end)}';
}

String reminderLabel(Reminder r, {required bool allDay}) {
  final m = r.minutesBefore;
  if (allDay) {
    // Bezug 9:00 am Termintag
    if (m == 0) return 'Am Tag um 9:00';
    if (m % 1440 == 0) {
      final d = m ~/ 1440;
      return d == 1 ? '1 Tag vorher um 9:00' : '$d Tage vorher um 9:00';
    }
    final t = DateTime(2000, 1, 1, 9).subtract(Duration(minutes: m));
    return m < 540 ? 'Am Tag um ${fmtTime(t)}' : 'Vortag um ${fmtTime(t)}';
  }
  if (m == 0) return 'Zum Terminbeginn';
  if (m < 60) return '$m Minuten vorher';
  if (m % 1440 == 0) {
    final d = m ~/ 1440;
    return d == 1 ? '1 Tag vorher' : '$d Tage vorher';
  }
  if (m % 60 == 0) {
    final h = m ~/ 60;
    return h == 1 ? '1 Stunde vorher' : '$h Stunden vorher';
  }
  return '$m Minuten vorher';
}

String recurrenceText(Recurrence r, DateTime start) {
  final every = r.interval == 1
      ? r.freq.label
      : 'Alle ${r.interval} ${r.freq.unitPlural}';
  var s = every;
  if (r.freq == RecurrenceFreq.weekly) {
    final days = r.byWeekday.isEmpty ? [start.weekday] : r.byWeekday;
    s += ' am ${(List.of(days)..sort()).map((d) => kWeekdaysShort[d - 1]).join(', ')}';
  } else if (r.freq == RecurrenceFreq.monthly) {
    s += ' am ${start.day}.';
  } else if (r.freq == RecurrenceFreq.yearly) {
    s += ' am ${start.day}. ${kMonths[start.month - 1]}';
  }
  if (r.until != null) s += ', bis ${fmtDate(r.until!)}';
  if (r.count != null) s += ', ${r.count}×';
  return s;
}

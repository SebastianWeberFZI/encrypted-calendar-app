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
  switch (r.freq) {
    case RecurrenceFreq.daily:
      break;
    case RecurrenceFreq.weekly:
      final days = r.byWeekday.isEmpty ? [start.weekday] : r.byWeekday;
      s += ' am ${(List.of(days)..sort()).map((d) => kWeekdaysShort[d - 1]).join(', ')}';
    case RecurrenceFreq.monthly:
      s += ' ${_daysText(r) ?? 'am ${start.day}.'}';
      if (r.byMonth.isNotEmpty) s += ' (nur ${_join([for (final m in r.byMonth) kMonthsShort[m - 1]])})';
    case RecurrenceFreq.yearly:
      final months = _join([for (final m in r.byMonth.isEmpty ? [start.month] : r.byMonth) kMonths[m - 1]]);
      final days = _daysText(r);
      if (days == null) {
        s += ' am ${start.day}. $months';
      } else if (r.byMonth.isEmpty && r.byDay.isEmpty) {
        s += ' $days jedes Monats';
      } else if (r.byMonth.isEmpty) {
        s += ' $days des Jahres';
      } else {
        s += ' $days im $months';
      }
  }
  if (r.until != null) s += ', bis ${fmtDate(r.until!)}';
  if (r.count != null) s += ', ${r.count}×';
  return s;
}

String _join(List<String> xs) =>
    xs.length <= 1 ? xs.join() : '${xs.sublist(0, xs.length - 1).join(', ')} und ${xs.last}';

/// „2.“, „letzten“, „vorletzten“, „3.-letzten“.
String ordinalText(int n) => switch (n) {
      -1 => 'letzten',
      -2 => 'vorletzten',
      _ => n < 0 ? '${-n}.-letzten' : '$n.',
    };

/// Tage einer monatlichen/jährlichen Regel („am 2. Dienstag“, „am 1. und 15.“,
/// „am letzten Werktag“); null = Tag des Beginns.
String? _daysText(Recurrence r) {
  if (r.byDay.isNotEmpty) {
    if (r.bySetPos.isNotEmpty && r.byDay.every((d) => d.n == 0)) {
      final wds = {for (final d in r.byDay) d.weekday};
      final kind = wds.length == 7
          ? 'Tag'
          : wds.length == 5 && wds.containsAll([1, 2, 3, 4, 5])
              ? 'Werktag'
              : wds.length == 2 && wds.containsAll([6, 7])
                  ? 'Wochenendtag'
                  : 'Tag (${(wds.toList()..sort()).map((d) => kWeekdaysShort[d - 1]).join(', ')})';
      return 'am ${_join([for (final p in r.bySetPos) ordinalText(p)])} $kind';
    }
    final every = r.byDay.every((d) => d.n == 0);
    final names = [
      for (final d in r.byDay) d.n == 0 ? kWeekdays[d.weekday - 1] : '${ordinalText(d.n)} ${kWeekdays[d.weekday - 1]}',
    ];
    var t = every ? 'jeden ${_join(names)}' : 'am ${_join(names)}';
    if (r.byMonthDay.isNotEmpty) {
      t += ', wenn es der ${_join([for (final d in r.byMonthDay) d > 0 ? '$d.' : '${ordinalText(d)} Tag'])} ist';
    }
    return t;
  }
  if (r.byMonthDay.isNotEmpty) {
    return 'am ${_join([for (final d in r.byMonthDay) d > 0 ? '$d.' : '${ordinalText(d)} Tag'])}';
  }
  return null;
}

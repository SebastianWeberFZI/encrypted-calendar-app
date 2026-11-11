import 'calendar_models.dart';

/// Ein konkretes Vorkommen eines (ggf. wiederkehrenden) Termins.
class Occurrence {
  Occurrence(this.event, this.calendar, this.start, this.end,
      {this.holiday = false});

  final CalendarEvent? event;
  final CalendarDef? calendar;
  final DateTime start;
  final DateTime end;

  /// Feiertag (virtueller Kalender, kein Dokument).
  final bool holiday;
  String? holidayName;

  bool get allDay => holiday || (event?.allDay ?? true);
  DateTime get startDay => dateOnly(start);
  DateTime get endDay => dateOnly(end);
  bool get isMultiDay => endDay.isAfter(startDay);

  int get color => event?.color ?? calendar?.color ?? 0xFFC0392B;

  /// Bedeutung der Terminfarbe laut Kalender ("Arzt", "Sport" …), sonst null.
  String? get colorLabel => calendar?.labelFor(event?.color);

  /// Anzeigetitel inkl. Alter bei Geburtstagen.
  String get title {
    if (holiday) return holidayName ?? 'Feiertag';
    final e = event!;
    if (calendar?.kind == CalendarKind.birthdays && e.birthYear != null) {
      final age = start.year - e.birthYear!;
      if (age > 0) return '${e.title} ($age)';
    }
    return e.title.isEmpty ? '(ohne Titel)' : e.title;
  }

  String get emoji => calendar?.emoji ?? '';

  /// Stabiler Schlüssel für dieses Vorkommen.
  String get key =>
      holiday ? 'holiday/${isoDate(start)}' : '${event!.id}@${isoDate(start)}';

  bool coversDay(DateTime day) {
    final d = dateOnly(day);
    return !d.isBefore(startDay) && !d.isAfter(endDay);
  }
}

int _daysInMonth(int y, int m) => DateTime(y, m + 1, 0).day;

/// Berechnet alle Vorkommen eines Termins, die den Zeitraum
/// [from, to) (Tage) berühren.
Iterable<DateTime> occurrenceStarts(
    CalendarEvent e, DateTime from, DateTime to) sync* {
  final r = e.recurrence;
  final spanDays = dateOnly(e.end).difference(dateOnly(e.start)).inDays;
  // Ein Vorkommen ab Start s berührt [from,to), wenn s < to und s+span >= from.
  bool touches(DateTime s) {
    final sd = dateOnly(s);
    return sd.isBefore(to) &&
        !sd.add(Duration(days: spanDays)).isBefore(from);
  }

  if (r == null) {
    if (touches(e.start)) yield e.start;
    return;
  }
  final ex = {for (final d in e.exdates) isoDate(d)};
  final until = r.until == null ? null : dateOnly(r.until!);
  final timeOfDay = Duration(hours: e.start.hour, minutes: e.start.minute);
  var emitted = 0;
  final limit = r.count;
  final startDay = dateOnly(e.start);

  bool accept(DateTime day) {
    // true = weiter iterieren
    if (until != null && day.isAfter(until)) return false;
    if (limit != null && emitted >= limit) return false;
    return true;
  }

  switch (r.freq) {
    case RecurrenceFreq.daily:
      var k = 0;
      if (limit == null) {
        final gap = from.difference(startDay).inDays - spanDays;
        if (gap > 0) k = gap ~/ r.interval;
      }
      while (true) {
        final day = DateTime(startDay.year, startDay.month, startDay.day + k * r.interval);
        if (!accept(day) || !day.isBefore(to)) return;
        emitted++;
        final s = day.add(timeOfDay);
        if (!ex.contains(isoDate(day)) && touches(s)) yield s;
        k++;
      }
    case RecurrenceFreq.weekly:
      final days = (r.byWeekday.isEmpty ? [e.start.weekday] : (List.of(r.byWeekday)..sort()));
      final week0 = startDay.subtract(Duration(days: startDay.weekday - 1));
      var w = 0;
      if (limit == null) {
        final gapWeeks = (from.difference(week0).inDays - spanDays) ~/ 7 - 1;
        if (gapWeeks > 0) w = gapWeeks ~/ r.interval;
      }
      while (true) {
        final monday = DateTime(week0.year, week0.month, week0.day + w * 7 * r.interval);
        if (!monday.isBefore(to)) return;
        for (final wd in days) {
          final day = DateTime(monday.year, monday.month, monday.day + wd - 1);
          if (day.isBefore(startDay)) continue;
          if (!accept(day)) return;
          emitted++;
          final s = day.add(timeOfDay);
          if (!day.isBefore(to)) return;
          if (!ex.contains(isoDate(day)) && touches(s)) yield s;
        }
        w++;
      }
    case RecurrenceFreq.monthly:
      var k = 0;
      while (true) {
        final m = startDay.month + k * r.interval;
        final first = DateTime(startDay.year, m, 1);
        if (!first.isBefore(to)) return;
        k++;
        if (startDay.day > _daysInMonth(first.year, first.month)) continue;
        final day = DateTime(first.year, first.month, startDay.day);
        if (!accept(day)) return;
        emitted++;
        final s = day.add(timeOfDay);
        if (!ex.contains(isoDate(day)) && touches(s)) yield s;
      }
    case RecurrenceFreq.yearly:
      var k = 0;
      if (limit == null && from.year - startDay.year > 1) {
        k = ((from.year - startDay.year - 1) ~/ r.interval);
      }
      while (true) {
        final y = startDay.year + k * r.interval;
        k++;
        // 29. Februar -> in Nicht-Schaltjahren am 28.
        final d = startDay.day.clamp(1, _daysInMonth(y, startDay.month));
        final day = DateTime(y, startDay.month, d);
        if (!day.isBefore(to)) return;
        if (!accept(day)) return;
        emitted++;
        final s = day.add(timeOfDay);
        if (!ex.contains(isoDate(day)) && touches(s)) yield s;
      }
  }
}

/// Alle Vorkommen der [events] im Zeitraum [from, to), sortiert.
List<Occurrence> expandOccurrences(Iterable<CalendarEvent> events,
    Map<String, CalendarDef> calendarsByKey, DateTime from, DateTime to) {
  final out = <Occurrence>[];
  final f = dateOnly(from), t = dateOnly(to);
  for (final e in events) {
    final cal = calendarsByKey[e.calendarKey];
    for (final s in occurrenceStarts(e, f, t)) {
      out.add(Occurrence(e, cal, s, s.add(e.duration)));
    }
  }
  out.sort(compareOccurrences);
  return out;
}

int compareOccurrences(Occurrence a, Occurrence b) {
  final c = a.startDay.compareTo(b.startDay);
  if (c != 0) return c;
  // Feiertage, dann mehrtägige, dann ganztägige, dann nach Uhrzeit
  int rank(Occurrence o) => o.holiday ? 0 : o.isMultiDay ? 1 : o.allDay ? 2 : 3;
  final r = rank(a).compareTo(rank(b));
  if (r != 0) return r;
  if (a.isMultiDay && b.isMultiDay) {
    final l = b.endDay.compareTo(a.endDay); // längere zuerst
    if (l != 0) return l;
  }
  final s = a.start.compareTo(b.start);
  return s != 0 ? s : a.title.compareTo(b.title);
}

/// Zeitpunkte, zu denen die Erinnerungen eines Vorkommens fällig sind.
DateTime reminderTime(Occurrence o, Reminder r) {
  final base = o.allDay
      ? DateTime(o.start.year, o.start.month, o.start.day, 9)
      : o.start;
  return base.subtract(Duration(minutes: r.minutesBefore));
}

/// Ordnet mehrtägigen Vorkommen innerhalb einer Woche Spuren zu, sodass sich
/// überlappende Zeiträume nicht dieselbe Zeile teilen (gierig, kleinste freie Spur).
Map<String, int> assignLanes(List<Occurrence> multiDay) {
  final sorted = List.of(multiDay)..sort(compareOccurrences);
  final laneEnds = <DateTime>[];
  final lanes = <String, int>{};
  for (final o in sorted) {
    var lane = laneEnds.indexWhere((end) => end.isBefore(o.startDay));
    if (lane == -1) {
      laneEnds.add(o.endDay);
      lane = laneEnds.length - 1;
    } else {
      laneEnds[lane] = o.endDay;
    }
    lanes[o.key] = lane;
  }
  return lanes;
}

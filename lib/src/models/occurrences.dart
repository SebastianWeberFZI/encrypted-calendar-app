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
  if (!r.isSimple) {
    yield* _generalStarts(e, r, from, to, spanDays, touches);
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

/// Vorkommen für Regeln mit „2. Dienstag“, Monatstagen, BYSETPOS usw.:
/// Zeitraum für Zeitraum (Tag, Woche, Monat, Jahr) die passenden Tage.
Iterable<DateTime> _generalStarts(CalendarEvent e, Recurrence r, DateTime from, DateTime to, int spanDays,
    bool Function(DateTime) touches) sync* {
  final ex = {for (final d in e.exdates) isoDate(d)};
  final until = r.until == null ? null : dateOnly(r.until!);
  final limit = r.count;
  final startDay = dateOnly(e.start);
  final step = r.interval;
  var emitted = 0;

  // Ohne COUNT darf vorgespult werden (mit Sicherheitsabstand).
  var k = 0;
  if (limit == null) {
    final lead = dateOnly(from).subtract(Duration(days: spanDays + 1));
    final periods = switch (r.freq) {
      RecurrenceFreq.daily => lead.difference(startDay).inDays,
      RecurrenceFreq.weekly => lead.difference(startDay).inDays ~/ 7,
      RecurrenceFreq.monthly => (lead.year - startDay.year) * 12 + lead.month - startDay.month,
      RecurrenceFreq.yearly => lead.year - startDay.year,
    };
    if (periods > 0) k = periods ~/ step - 1;
    if (k < 0) k = 0;
  }
  final weekStart0 = startDay.subtract(Duration(days: (startDay.weekday - r.weekStart + 7) % 7));

  while (true) {
    final (periodStart, days) = _periodDays(r, startDay, weekStart0, k * step);
    if (!periodStart.isBefore(to)) return;
    k++;
    for (final day in days) {
      if (day.isBefore(startDay)) continue;
      if (until != null && day.isAfter(until)) return;
      if (limit != null && emitted >= limit) return;
      if (!day.isBefore(to)) return;
      emitted++;
      final s = DateTime(day.year, day.month, day.day, e.start.hour, e.start.minute);
      if (!ex.contains(isoDate(day)) && touches(s)) yield s;
    }
  }
}

/// Beginn des [offset]-ten Zeitraums und seine Tage nach der Regel (sortiert).
(DateTime, List<DateTime>) _periodDays(Recurrence r, DateTime startDay, DateTime weekStart0, int offset) {
  bool monthOk(DateTime d) => r.byMonth.isEmpty || r.byMonth.contains(d.month);
  List<int> monthDays(int y, int m) {
    final n = _daysInMonth(y, m);
    return [
      for (final d in r.byMonthDay)
        if (d > 0 && d <= n) d else if (d < 0 && -d <= n) n + d + 1,
    ];
  }

  /// Tage mit [w] in einem Bereich (Monat oder Jahr), Ordnungszahl relativ dazu.
  List<DateTime> weekdayDays(DateTime first, DateTime endExcl, NthWeekday w) {
    final all = <DateTime>[];
    var d = first.add(Duration(days: (w.weekday - first.weekday + 7) % 7));
    while (d.isBefore(endExcl)) {
      all.add(d);
      d = DateTime(d.year, d.month, d.day + 7);
    }
    if (w.n == 0) return all;
    final i = w.n > 0 ? w.n - 1 : all.length + w.n;
    return i >= 0 && i < all.length ? [all[i]] : const [];
  }

  List<DateTime> byDayIn(DateTime first, DateTime endExcl) =>
      [for (final w in r.byDay) ...weekdayDays(first, endExcl, w)];

  late DateTime periodStart;
  var days = <DateTime>[];
  switch (r.freq) {
    case RecurrenceFreq.daily:
      periodStart = DateTime(startDay.year, startDay.month, startDay.day + offset);
      final d = periodStart;
      if (monthOk(d) && (r.byMonthDay.isEmpty || monthDays(d.year, d.month).contains(d.day))) days = [d];
    case RecurrenceFreq.weekly:
      periodStart = DateTime(weekStart0.year, weekStart0.month, weekStart0.day + offset * 7);
      final wds = r.byWeekday.isEmpty ? [startDay.weekday] : r.byWeekday;
      for (var i = 0; i < 7; i++) {
        final d = DateTime(periodStart.year, periodStart.month, periodStart.day + i);
        if (wds.contains(d.weekday) && monthOk(d)) days.add(d);
      }
    case RecurrenceFreq.monthly:
      periodStart = DateTime(startDay.year, startDay.month + offset, 1);
      final y = periodStart.year, m = periodStart.month;
      if (monthOk(periodStart)) {
        final next = DateTime(y, m + 1, 1);
        if (r.byDay.isNotEmpty) {
          days = byDayIn(periodStart, next);
          if (r.byMonthDay.isNotEmpty) {
            final md = monthDays(y, m);
            days = days.where((d) => md.contains(d.day)).toList();
          }
        } else if (r.byMonthDay.isNotEmpty) {
          days = [for (final d in monthDays(y, m)) DateTime(y, m, d)];
        } else if (startDay.day <= _daysInMonth(y, m)) {
          days = [DateTime(y, m, startDay.day)];
        }
      }
    case RecurrenceFreq.yearly:
      final y = startDay.year + offset;
      periodStart = DateTime(y, 1, 1);
      final months = r.byMonth.isNotEmpty ? r.byMonth : null;
      if (r.byDay.isNotEmpty) {
        if (months != null) {
          for (final m in months) {
            days.addAll(byDayIn(DateTime(y, m, 1), DateTime(y, m + 1, 1)));
          }
        } else {
          days = byDayIn(periodStart, DateTime(y + 1, 1, 1));
        }
        if (r.byMonthDay.isNotEmpty) {
          days = days.where((d) => monthDays(d.year, d.month).contains(d.day)).toList();
        }
      } else if (r.byMonthDay.isNotEmpty) {
        for (final m in months ?? List.generate(12, (i) => i + 1)) {
          days.addAll([for (final d in monthDays(y, m)) DateTime(y, m, d)]);
        }
      } else {
        for (final m in months ?? [startDay.month]) {
          if (startDay.day <= _daysInMonth(y, m)) days.add(DateTime(y, m, startDay.day));
        }
      }
  }
  final unique = {for (final d in days) isoDate(d): d}.values.toList()..sort();
  if (r.bySetPos.isEmpty) return (periodStart, unique);
  final picked = <DateTime>{
    for (final p in r.bySetPos)
      if (p > 0 && p <= unique.length) unique[p - 1] else if (p < 0 && -p <= unique.length) unique[unique.length + p],
  }.toList()
    ..sort();
  return (periodStart, picked);
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

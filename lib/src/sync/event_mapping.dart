import 'dart:convert';

import '../models/calendar_models.dart';
import 'device_calendar.dart';

/// Gemeinsame Form eines Termins für den Vergleich App ↔ Handy-Kalender.
/// Gleiche Form = nichts zu tun; die gespeicherte Prüfsumme der letzten
/// gemeinsamen Form zeigt, welche Seite sich seitdem geändert hat.
class EventNorm {
  const EventNorm({
    required this.title,
    required this.description,
    required this.location,
    required this.allDay,
    required this.start,
    required this.end,
    this.rule = '',
    this.exdates = const [],
    this.alerts = const [],
  });

  final String title;
  final String description;
  final String location;
  final bool allDay;

  /// Ganztägig: Datum (yyyy-MM-dd); sonst Millisekunden seit 1970 (UTC).
  final String start;

  /// Ganztägig: letzter Tag (inklusive); sonst Ende in Millisekunden.
  final String end;

  /// Wiederholung in kanonischer Form ('' = keine; 'RAW:…' = nicht abbildbar).
  final String rule;

  /// Ausgelassene Tage einer Serie (yyyy-MM-dd, sortiert).
  final List<String> exdates;

  /// Benachrichtigungen (Minuten vorher, sortiert) – nur wenn Erinnerungen
  /// abgeglichen werden, sonst leer.
  final List<int> alerts;

  String get key =>
      jsonEncode([title, description, location, allDay, start, end, rule, exdates, if (alerts.isNotEmpty) alerts]);
  String get hash => fnv64(key);

  @override
  String toString() => key;
}

/// FNV-1a (64 Bit) als Hex – kurz und auf allen Geräten gleich.
String fnv64(String s) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toUnsigned(64).toRadixString(16);
}

String _two(int v) => v.toString().padLeft(2, '0');
String _ymd(DateTime d) => '${d.year}${_two(d.month)}${_two(d.day)}';
String _utcStamp(DateTime d) {
  final u = d.toUtc();
  return '${_ymd(u)}T${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z';
}

int _minute(int ms) => ms ~/ 60000 * 60000;

/// UTC-Mitternacht eines Datums (so speichert Android ganztägige Termine).
int utcMidnight(DateTime d) => DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch;
DateTime utcDate(int ms) {
  final u = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  return DateTime(u.year, u.month, u.day);
}

// --------------------------------------------------------------- Wiederholung

/// Muster der Regel; wöchentlich immer mit BYDAY (wie es Kalender schreiben).
String _rulePattern(Recurrence n, DateTime start) =>
    n.freq == RecurrenceFreq.weekly && n.byWeekday.isEmpty ? n.copyWith(byWeekday: [start.weekday]).pattern : n.pattern;

/// Kanonische Regel aus der App-Regel (Reihenfolge fest, Standardwerte weggelassen).
String canonicalRule(Recurrence r, DateTime start) {
  final n = r.normalized(start);
  final parts = [_rulePattern(n, start)];
  if (n.count != null) {
    parts.add('COUNT=${n.count}');
  } else if (n.until != null) {
    parts.add('UNTIL=${_ymd(n.until!)}');
  }
  return parts.join(';');
}

/// Regel für den Kalenderspeicher (UNTIL bei Terminen mit Uhrzeit als
/// UTC-Zeitpunkt am Ende des letzten Tages).
String providerRule(Recurrence r, DateTime start, bool allDay) {
  final n = r.normalized(start);
  final parts = [_rulePattern(n, start)];
  if (n.count != null) {
    parts.add('COUNT=${n.count}');
  } else if (n.until != null) {
    final u = n.until!;
    parts.add(allDay ? 'UNTIL=${_ymd(u)}' : 'UNTIL=${_utcStamp(DateTime(u.year, u.month, u.day, 23, 59, 59))}');
  }
  return parts.join(';');
}

/// RRULE aus dem Kalenderspeicher → App-Regel; null, wenn die App sie nicht
/// abbilden kann (z. B. stündlich, BYWEEKNO, BYYEARDAY).
Recurrence? parseRule(String rrule, DateTime start) {
  final r = Recurrence.tryParsePattern(rrule);
  if (r == null) return null;
  final map = <String, String>{};
  for (final p in rrule.replaceFirst(RegExp(r'^RRULE:', caseSensitive: false), '').split(';')) {
    final i = p.indexOf('=');
    if (i > 0) map[p.substring(0, i).trim().toUpperCase()] = p.substring(i + 1).trim().toUpperCase();
  }
  int? count;
  DateTime? until;
  if (map['COUNT'] != null) {
    count = int.tryParse(map['COUNT']!);
    if (count == null || count < 1) return null;
  } else if (map['UNTIL'] != null) {
    until = parseStamp(map['UNTIL']!);
    if (until == null) return null;
    until = DateTime(until.year, until.month, until.day);
  }
  return r.copyWith(until: until, count: count).normalized(start);
}

/// „20261112“, „20261112T090000“ oder „20261112T090000Z“ → lokale Zeit.
/// Ganztägige Werte (nur Datum oder UTC-Mitternacht) ergeben das Datum selbst.
DateTime? parseStamp(String s, {bool allDay = false}) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$').firstMatch(s.trim());
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (m[4] == null) return DateTime(y, mo, d);
  final h = int.parse(m[4]!), mi = int.parse(m[5]!), se = int.parse(m[6]!);
  if (m[7] == 'Z') {
    if (allDay) return DateTime(y, mo, d);
    return DateTime.utc(y, mo, d, h, mi, se).toLocal();
  }
  return DateTime(y, mo, d, h, mi, se);
}

/// EXDATE-Feld (mehrere Formen: „TZID=…;a,b“, Zeilen, Kommas) → Tage.
List<DateTime> parseExdates(String? exdate, {bool allDay = false}) {
  if (exdate == null || exdate.trim().isEmpty) return [];
  final out = <DateTime>[];
  for (var line in exdate.split(RegExp(r'[\n\r]+'))) {
    line = line.replaceFirst(RegExp(r'^EXDATE', caseSensitive: false), '');
    // „TZID=…;Werte“ oder „;VALUE=DATE:Werte“: nur die Werte zählen
    final colon = line.lastIndexOf(':');
    if (colon >= 0) line = line.substring(colon + 1);
    final semi = line.lastIndexOf(';');
    if (semi >= 0) line = line.substring(semi + 1);
    for (final v in line.split(',')) {
      final d = parseStamp(v, allDay: allDay);
      if (d != null) out.add(DateTime(d.year, d.month, d.day));
    }
  }
  return out;
}

/// Dauer „P1D“, „PT1H30M“, „P3600S“, „P2W“ → Millisekunden.
int? parseDuration(String? s) {
  if (s == null || s.isEmpty) return null;
  final m = RegExp(r'^([+-])?P(.*)$').firstMatch(s.trim().toUpperCase());
  if (m == null) return null;
  var total = 0, n = 0;
  for (final c in m[2]!.split('')) {
    final digit = int.tryParse(c);
    if (digit != null) {
      n = n * 10 + digit;
      continue;
    }
    switch (c) {
      case 'W':
        total += n * 7 * 86400;
      case 'D':
        total += n * 86400;
      case 'H':
        total += n * 3600;
      case 'M':
        total += n * 60;
      case 'S':
        total += n;
      case 'T':
        break;
      default:
        return null;
    }
    n = 0;
  }
  return (m[1] == '-' ? -total : total) * 1000;
}

// --------------------------------------------------------------- Formen

/// Minuten der Push-Erinnerungen eines App-Termins (sortiert, ohne doppelte).
List<int> pushAlerts(CalendarEvent e) =>
    {for (final r in e.reminders) if (r.push && r.minutesBefore >= 0) r.minutesBefore}.toList()..sort();

/// Form eines App-Termins; [alerts] nur, wenn Erinnerungen abgeglichen werden.
EventNorm normFromApp(CalendarEvent e, {List<int> alerts = const []}) {
  final r = e.recurrence;
  final rule = r == null ? '' : canonicalRule(r, e.start);
  return EventNorm(
    title: e.title.trim(),
    description: e.description.trim(),
    location: e.location.trim(),
    allDay: e.allDay,
    start: e.allDay ? isoDate(e.start) : '${_minute(e.start.millisecondsSinceEpoch)}',
    end: e.allDay ? isoDate(e.end) : '${_minute(e.end.millisecondsSinceEpoch)}',
    rule: rule,
    exdates: rule.isEmpty ? const [] : ({for (final d in e.exdates) isoDate(d)}.toList()..sort()),
    alerts: alerts,
  );
}

/// Beginn und Ende eines Termins aus dem Kalenderspeicher (lokal).
/// Ganztägig: Datum des ersten und letzten Tages.
(DateTime, DateTime) rowTimes(DeviceEvent r) {
  final durMs = parseDuration(r.duration);
  if (r.allDay) {
    final s = utcDate(r.dtstart);
    final endExcl = r.dtend != null && r.dtend! > r.dtstart
        ? utcDate(r.dtend!)
        : (durMs != null && durMs > 0 ? utcDate(r.dtstart + durMs) : s.add(const Duration(days: 1)));
    var last = DateTime(endExcl.year, endExcl.month, endExcl.day - 1);
    if (last.isBefore(s)) last = s;
    return (s, last);
  }
  final s = DateTime.fromMillisecondsSinceEpoch(r.dtstart);
  final endMs = r.dtend ?? (durMs != null ? r.dtstart + durMs : r.dtstart);
  final e = DateTime.fromMillisecondsSinceEpoch(endMs < r.dtstart ? r.dtstart : endMs);
  return (s, e);
}

/// Form eines Termins aus dem Kalenderspeicher; [exceptions] sind dessen
/// Ausnahmen (verschobene oder abgesagte Vorkommen) – ihr ursprünglicher Tag
/// zählt als ausgelassen.
EventNorm normFromRow(DeviceEvent r, [Iterable<DeviceEvent> exceptions = const [], bool withAlerts = false]) {
  final (s, e) = rowTimes(r);
  var rule = '';
  var ex = <String>[];
  if (r.recurring) {
    final rec = (r.rdate ?? '').isEmpty ? parseRule(r.rrule ?? '', s) : null;
    rule = rec == null ? 'RAW:${r.rrule ?? ''}|${r.rdate ?? ''}' : canonicalRule(rec, s);
    ex = {
      for (final d in parseExdates(r.exdate, allDay: r.allDay)) isoDate(d),
      for (final x in exceptions)
        if (x.originalInstanceTime != null)
          isoDate(r.allDay ? utcDate(x.originalInstanceTime!) : dateOnly(DateTime.fromMillisecondsSinceEpoch(x.originalInstanceTime!))),
    }.toList()
      ..sort();
  }
  return EventNorm(
    title: r.title.trim(),
    description: r.description.trim(),
    location: r.location.trim(),
    allDay: r.allDay,
    start: r.allDay ? isoDate(s) : '${_minute(r.dtstart)}',
    end: r.allDay ? isoDate(e) : '${_minute(e.millisecondsSinceEpoch)}',
    rule: rule,
    exdates: ex,
    alerts: withAlerts ? r.alerts : const [],
  );
}

/// Kann die App diese Serie abbilden?
bool rowSupported(DeviceEvent r) {
  if ((r.rdate ?? '').isNotEmpty) return false;
  if ((r.rrule ?? '').isEmpty) return true;
  final (s, _) = rowTimes(r);
  return parseRule(r.rrule!, s) != null;
}

/// Übernimmt Inhalt und Zeiten aus dem Kalenderspeicher in einen App-Termin
/// (Farbe, Link und unbekannte Felder bleiben; Erinnerungen nur mit [alerts]:
/// dann ersetzen sie die Push-Erinnerungen, reine E-Mail-Erinnerungen bleiben).
void applyRowToApp(CalendarEvent target, DeviceEvent r,
    [Iterable<DeviceEvent> exceptions = const [], List<int>? alerts]) {
  if (alerts != null) {
    final mail = {for (final x in target.reminders) if (x.email) x.minutesBefore};
    target.reminders = [
      for (final m in alerts) Reminder(minutesBefore: m, push: true, email: mail.contains(m)),
      for (final m in mail)
        if (!alerts.contains(m)) Reminder(minutesBefore: m, push: false, email: true),
    ]..sort((a, b) => b.minutesBefore.compareTo(a.minutesBefore));
  }
  final (s, e) = rowTimes(r);
  target
    ..title = r.title.trim()
    ..description = r.description.trim()
    ..location = r.location.trim()
    ..allDay = r.allDay
    ..start = s
    ..end = e;
  if (r.recurring && (r.rdate ?? '').isEmpty) {
    target.recurrence = parseRule(r.rrule ?? '', s);
    target.exdates = [
      for (final d in parseExdates(r.exdate, allDay: r.allDay)) d,
      for (final x in exceptions)
        if (x.originalInstanceTime != null)
          r.allDay ? utcDate(x.originalInstanceTime!) : dateOnly(DateTime.fromMillisecondsSinceEpoch(x.originalInstanceTime!)),
    ];
  } else {
    target.recurrence = null;
    target.exdates = [];
  }
}

/// Werte für den Kalenderspeicher aus einem App-Termin. [calendarId] nur beim
/// Anlegen; [appUri] markiert Kopien der App.
Map<String, Object?> rowValuesFromApp(CalendarEvent e, {int? calendarId, String? appPackage, String? appUri}) {
  final v = <String, Object?>{
    'calendar_id': ?calendarId,
    'title': e.title.trim(),
    'description': e.description.trim(),
    'eventLocation': e.location.trim(),
    'allDay': e.allDay ? 1 : 0,
    'eventTimezone': e.allDay ? 'UTC' : (e.timeZone.isEmpty ? 'Europe/Berlin' : e.timeZone),
    'dtstart': e.allDay ? utcMidnight(e.start) : e.start.millisecondsSinceEpoch,
    'customAppPackage': ?appPackage,
    'customAppUri': ?appUri,
  };
  final r = e.recurrence;
  if (r != null) {
    final days = dateOnly(e.end).difference(dateOnly(e.start)).inDays + 1;
    final secs = e.end.difference(e.start).inSeconds;
    v['rrule'] = providerRule(r, e.start, e.allDay);
    v['duration'] = e.allDay ? 'P${days < 1 ? 1 : days}D' : 'P${secs < 0 ? 0 : secs}S';
    v['dtend'] = null;
    final ex = {for (final d in e.exdates) dateOnly(d)}.toList()..sort();
    v['exdate'] = ex.isEmpty
        ? null
        : ex
            .map((d) => e.allDay
                ? '${_ymd(d)}T000000Z'
                : _utcStamp(DateTime(d.year, d.month, d.day, e.start.hour, e.start.minute)))
            .join(',');
  } else {
    v['rrule'] = null;
    v['duration'] = null;
    v['exdate'] = null;
    v['dtend'] = e.allDay
        ? utcMidnight(DateTime(e.end.year, e.end.month, e.end.day + 1))
        : e.end.millisecondsSinceEpoch;
  }
  return v;
}

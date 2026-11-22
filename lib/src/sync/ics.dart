import '../models/calendar_models.dart';
import 'event_mapping.dart';

/// Ein Termin aus einer iCalendar-Datei (RFC 5545), so weit die App ihn
/// abbilden kann.
class IcsEvent {
  IcsEvent({
    required this.uid,
    required this.summary,
    required this.start,
    required this.end,
    required this.allDay,
    this.description = '',
    this.location = '',
    this.url = '',
    this.recurrence,
    List<DateTime>? exdates,
    this.recurrenceId,
    this.cancelled = false,
  }) : exdates = exdates ?? [];

  final String uid;
  final String summary;

  /// Lokale Zeit. Ganztägig: nur das Datum zählt, [end] = letzter Tag (inklusive).
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String description;
  final String location;
  final String url;
  final Recurrence? recurrence;
  final List<DateTime> exdates;

  /// Geändertes oder abgesagtes Einzelvorkommen einer Serie (RECURRENCE-ID).
  final DateTime? recurrenceId;
  final bool cancelled;

  @override
  String toString() => '${allDay ? isoDate(start) : isoLocal(start)} $summary';
}

/// Eine Zeile `NAME;PARAM=WERT:Inhalt`.
class _Prop {
  _Prop(this.name, this.params, this.value);
  final String name;
  final Map<String, String> params;
  final String value;
}

/// Liest die Termine einer iCalendar-Datei. Abgesagte Termine (STATUS:
/// CANCELLED) und Einträge ohne lesbaren Beginn fehlen im Ergebnis. Geänderte
/// Einzelvorkommen einer Serie (RECURRENCE-ID) stehen als eigene Termine
/// darin, die Serie lässt diesen Tag dann aus.
/// Wirft [FormatException], wenn der Text keine iCalendar-Datei ist.
List<IcsEvent> parseIcs(String text) {
  final all = _parse(text);
  final series = {
    for (final e in all)
      if (e.recurrence != null && e.recurrenceId == null && e.uid.isNotEmpty) e.uid: e,
  };
  final out = <IcsEvent>[];
  for (final e in all) {
    final id = e.recurrenceId;
    if (id != null) {
      final master = series[e.uid];
      final day = DateTime(id.year, id.month, id.day);
      if (master != null && !master.exdates.contains(day)) master.exdates.add(day);
    }
    if (!e.cancelled) out.add(e);
  }
  return out;
}

List<IcsEvent> _parse(String text) {
  final lines = _unfold(text);
  if (!lines.any((l) => l.toUpperCase() == 'BEGIN:VCALENDAR')) {
    throw const FormatException('Keine Kalenderdatei (iCalendar)');
  }
  final out = <IcsEvent>[];
  List<_Prop>? current;
  var depth = 0; // verschachtelte Blöcke im Termin (z. B. VALARM)
  for (final line in lines) {
    final upper = line.toUpperCase();
    if (current == null) {
      if (upper == 'BEGIN:VEVENT') current = [];
      continue;
    }
    if (upper.startsWith('BEGIN:')) {
      depth++;
    } else if (upper.startsWith('END:')) {
      if (depth > 0) {
        depth--;
      } else if (upper == 'END:VEVENT') {
        final e = _event(current);
        if (e != null) out.add(e);
        current = null;
      }
    } else if (depth == 0) {
      final p = _prop(line);
      if (p != null) current.add(p);
    }
  }
  return out;
}

/// Zeilen zusammenfügen, die mit Leerzeichen/Tab fortgesetzt werden.
List<String> _unfold(String text) {
  final raw = text.replaceFirst('﻿', '').split(RegExp(r'\r\n|\n|\r'));
  final out = <String>[];
  for (final l in raw) {
    if ((l.startsWith(' ') || l.startsWith('\t')) && out.isNotEmpty) {
      out[out.length - 1] += l.substring(1);
    } else if (l.isNotEmpty) {
      out.add(l);
    }
  }
  return out;
}

_Prop? _prop(String line) {
  // Doppelpunkte in Parameterwerten stehen in Anführungszeichen.
  var inQuote = false;
  var colon = -1;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') inQuote = !inQuote;
    if (c == ':' && !inQuote) {
      colon = i;
      break;
    }
  }
  if (colon <= 0) return null;
  final head = line.substring(0, colon).split(';');
  final params = <String, String>{};
  for (final p in head.skip(1)) {
    final i = p.indexOf('=');
    if (i > 0) params[p.substring(0, i).toUpperCase()] = p.substring(i + 1).replaceAll('"', '');
  }
  return _Prop(head.first.toUpperCase(), params, line.substring(colon + 1));
}

String _text(String v) => v
    .replaceAllMapped(RegExp(r'\\([nN\\;,])'),
        (m) => m[1] == 'n' || m[1] == 'N' ? '\n' : m[1]!)
    .trim();

IcsEvent? _event(List<_Prop> props) {
  _Prop? first(String name) => props.where((p) => p.name == name).firstOrNull;
  final cancelled = first('STATUS')?.value.trim().toUpperCase() == 'CANCELLED';
  final recurrenceId = first('RECURRENCE-ID');
  final dtStart = first('DTSTART');
  if (dtStart == null) return null;
  final dateOnly = dtStart.params['VALUE']?.toUpperCase() == 'DATE' || !dtStart.value.contains('T');
  final start = parseStamp(dtStart.value);
  if (start == null) return null;

  final dtEnd = first('DTEND');
  DateTime? end = dtEnd == null ? null : parseStamp(dtEnd.value);
  final duration = parseDuration(first('DURATION')?.value);
  if (end == null && duration != null) end = start.add(Duration(milliseconds: duration));

  final midnight = start.hour == 0 && start.minute == 0 && start.second == 0;
  // Ganztägig: reines Datum – oder (wie manche Abfallkalender) Mitternacht
  // ohne Dauer bzw. bis Mitternacht eines Folgetags.
  final allDay = dateOnly ||
      (midnight &&
          (end == null ||
              end == start ||
              (end.hour == 0 && end.minute == 0 && end.second == 0 && end.isAfter(start))));
  DateTime s, e;
  if (allDay) {
    s = DateTime(start.year, start.month, start.day);
    if (end == null || !end.isAfter(start)) {
      e = s;
    } else {
      // DTEND ist exklusiv: bis zum Vortag.
      final last = DateTime(end.year, end.month, end.day).subtract(const Duration(days: 1));
      e = last.isBefore(s) ? s : last;
    }
  } else {
    s = start;
    e = end != null && end.isAfter(start) ? end : start;
  }

  final rrule = first('RRULE')?.value;
  final exdates = [
    for (final p in props.where((p) => p.name == 'EXDATE')) ...parseExdates(p.value, allDay: allDay),
  ];
  return IcsEvent(
    uid: first('UID')?.value.trim() ?? '',
    summary: _text(first('SUMMARY')?.value ?? ''),
    description: _text(first('DESCRIPTION')?.value ?? ''),
    location: _text(first('LOCATION')?.value ?? ''),
    url: (first('URL')?.value ?? '').trim(),
    start: s,
    end: e,
    allDay: allDay,
    recurrence: rrule == null || recurrenceId != null ? null : parseRule(rrule, s),
    exdates: exdates,
    recurrenceId: recurrenceId == null ? null : parseStamp(recurrenceId.value),
    cancelled: cancelled,
  );
}

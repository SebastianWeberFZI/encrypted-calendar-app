import 'dart:io';

import 'package:flutter/services.dart';

/// Dünner Zugriff auf den Kalenderspeicher von Android (CalendarContract).
///
/// Dort liegen u. a. die Google-Kalender des Handys; das Google-Konto
/// gleicht sie selbst mit Google ab. Zeilen kommen als Maps mit den
/// Spaltennamen von CalendarContract (z. B. `dtstart`, `rrule`, `allDay`).
class SystemCalendar {
  static const _ch = MethodChannel('de.sweber/system_calendar');

  /// Nur unter Android vorhanden.
  static bool get supported => Platform.isAndroid;

  static Future<bool> hasPermission() async =>
      supported && (await _ch.invokeMethod<bool>('hasPermission') ?? false);

  /// Fragt nach Lese- und Schreibrecht (braucht eine sichtbare Activity).
  static Future<bool> requestPermission() async =>
      supported && (await _ch.invokeMethod<bool>('requestPermission') ?? false);

  static Future<List<Map<String, Object?>>> calendars() => _rows('calendars');

  /// Termine (auch Serien und Ausnahmen) der Kalender, die nach [fromMillis]
  /// noch stattfinden; gelöschte Zeilen nicht.
  static Future<List<Map<String, Object?>>> events(
          {required List<int> calendarIds, int? fromMillis}) =>
      calendarIds.isEmpty
          ? Future.value([])
          : _rows('events', {'calendarIds': calendarIds, 'from': fromMillis});

  /// Termine per ID – auch als gelöscht markierte (`deleted` = 1).
  static Future<List<Map<String, Object?>>> eventsByIds(List<int> ids) =>
      ids.isEmpty ? Future.value([]) : _rows('eventsByIds', {'ids': ids});

  /// Einzelne Vorkommen eines Termins im Zeitraum (`begin`, `end`).
  static Future<List<Map<String, Object?>>> instances(int eventId, int fromMillis, int toMillis) =>
      _rows('instances', {'eventId': eventId, 'from': fromMillis, 'to': toMillis});

  static Future<int> insertEvent(Map<String, Object?> values) async =>
      await _ch.invokeMethod<int>('insertEvent', {'values': values}) ?? -1;

  static Future<int> updateEvent(int id, Map<String, Object?> values) async =>
      await _ch.invokeMethod<int>('updateEvent', {'id': id, 'values': values}) ?? 0;

  static Future<int> deleteEvent(int id) async =>
      await _ch.invokeMethod<int>('deleteEvent', {'id': id}) ?? 0;

  static Future<List<Map<String, Object?>>> _rows(String method, [Map<String, Object?>? args]) async {
    final raw = await _ch.invokeMethod<List<Object?>>(method, args) ?? const [];
    return [
      for (final r in raw)
        if (r is Map) {for (final e in r.entries) e.key.toString(): e.value},
    ];
  }
}

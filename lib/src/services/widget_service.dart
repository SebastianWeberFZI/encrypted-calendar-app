import 'dart:convert';
import 'dart:io';

import 'package:home_widget/home_widget.dart';

import '../calendar_repository.dart';
import '../models/calendar_models.dart';
import '../settings.dart';

/// Bereitet die Daten für die nativen Startbildschirm-Widgets auf
/// (Monat/4 Wochen und Agenda). Die Widgets lesen nur diese Vorschau –
/// nie das Repo oder Schlüssel.
class WidgetService {
  static const monthProvider =
      'de.sweber.encrypted_calendar_app.MonthWidgetProvider';
  static const agendaProvider =
      'de.sweber.encrypted_calendar_app.AgendaWidgetProvider';

  /// Kann der Launcher Widgets direkt aus der App anlegen (Android 8+)?
  static Future<bool> canPin() async {
    if (!Platform.isAndroid) return false;
    try {
      return await HomeWidget.isRequestPinWidgetSupported() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Öffnet den System-Dialog „Zum Startbildschirm hinzufügen“.
  static Future<void> pin(String provider) =>
      HomeWidget.requestPinWidget(qualifiedAndroidName: provider);

  static Future<void> update(
      CalendarRepository repo, LocalSettings settings) async {
    if (!Platform.isAndroid) return;
    final now = DateTime.now();
    final today = dateOnly(now);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final to = weekStart.add(const Duration(days: 49));
    final keys = settings.widgetCalendars ??
        {
          for (final c in repo.calendars)
            if (!settings.hiddenCalendars.contains(c.key)) c.key
        };
    final occ = repo.occurrences(weekStart, to,
        calendarKeys: keys,
        holidayState:
            settings.showHolidays && settings.widgetShowHolidays
                ? settings.holidayState
                : null);
    final data = {
      'generated': now.toIso8601String(),
      'week_start': isoDate(weekStart),
      'theme': settings.themeColor,
      'events': [
        for (final o in occ)
          {
            't': o.title,
            'c': o.color,
            's': isoDate(o.startDay),
            'e': isoDate(o.endDay),
            'h': o.allDay ? '' : '${o.start.hour.toString().padLeft(2, '0')}:'
                '${o.start.minute.toString().padLeft(2, '0')}',
            'he': o.allDay ? '' : '${o.end.hour.toString().padLeft(2, '0')}:'
                '${o.end.minute.toString().padLeft(2, '0')}',
            'hol': o.holiday,
            'loc': o.event?.location ?? '',
          }
      ],
    };
    try {
      await HomeWidget.saveWidgetData<String>('calendar_data', jsonEncode(data));
      await HomeWidget.updateWidget(qualifiedAndroidName: monthProvider);
      await HomeWidget.updateWidget(qualifiedAndroidName: agendaProvider);
    } catch (_) {
      // Kein Widget-Support (z. B. in Tests) – nicht kritisch.
    }
  }
}

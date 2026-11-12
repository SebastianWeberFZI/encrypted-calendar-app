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
    // Das Monats-Widget scrollt ein halbes Jahr weit.
    final to = weekStart.add(const Duration(days: 7 * 26));
    // Alle Kalender liefern – welche ein Widget zeigt, entscheidet es selbst
    // (eigene Auswahl je Widget, sonst diese Standardauswahl).
    final defaultKeys = settings.widgetCalendars ??
        {
          for (final c in repo.calendars)
            if (!settings.hiddenCalendars.contains(c.key)) c.key
        };
    final sourceLabels = {for (final s in repo.sources) s.id: s.config.label};
    final occ = repo.occurrences(weekStart, to,
        calendarKeys: {for (final c in repo.calendars) c.key},
        holidayState: settings.holidayState);
    final data = {
      'week_start': isoDate(weekStart),
      'theme': settings.themeColor,
      'default_keys': defaultKeys.toList(),
      'default_holidays': settings.showHolidays && settings.widgetShowHolidays,
      'calendars': [
        for (final c in repo.calendars)
          {
            'k': c.key,
            'n': c.name,
            'c': c.color,
            'e': c.emoji,
            's': sourceLabels[c.sourceId] ?? '',
          }
      ],
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
            'k': o.calendar?.key ?? '',
          }
      ],
    };
    try {
      // Energie sparen: Widgets nur neu zeichnen, wenn sich ihre Daten geändert
      // haben (sonst würde jeder Abgleich – bei offener App minütlich – sie anstoßen).
      final encoded = jsonEncode(data);
      final previous = await HomeWidget.getWidgetData<String>('calendar_data');
      if (encoded == previous) return;
      await HomeWidget.saveWidgetData<String>('calendar_data', encoded);
      await HomeWidget.updateWidget(qualifiedAndroidName: monthProvider);
      await HomeWidget.updateWidget(qualifiedAndroidName: agendaProvider);
    } catch (_) {
      // Kein Widget-Support (z. B. in Tests) – nicht kritisch.
    }
  }
}

import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../calendar_repository.dart';
import '../models/calendar_models.dart';
import '../models/occurrences.dart';
import '../settings.dart';
import '../ui/format.dart';

/// Termin-Erinnerungen als lokale Android-Benachrichtigungen (exakte Alarme).
/// Für Serien werden jeweils die Vorkommen der nächsten 30 Tage eingeplant.
class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  static const _maxScheduled = 120;
  static const _horizon = Duration(days: 30);

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Termin-Erinnerungen',
      channelDescription: 'Erinnerungen an Termine',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.event,
    ),
  );

  Future<void> init({bool requestPermissions = true}) async {
    if (!Platform.isAndroid) return; // Linux-Vorschau: keine System-Erinnerungen
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(
          tz.getLocation(await FlutterTimezone.getLocalTimezone()));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Europe/Berlin'));
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_notify'),
      ),
    );
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (requestPermissions) {
      await android?.requestNotificationsPermission();
    }
    // Ab Android 13 ist USE_EXACT_ALARM (Kalender-App) automatisch erteilt; davor
    // SCHEDULE_EXACT_ALARM. Fehlt beides, wird ungenauer geplant statt die
    // Einstellungsseite ungefragt zu öffnen.
    _exact = await android?.canScheduleExactNotifications() ?? false;
    _ready = true;
  }

  bool _exact = false;

  static int notificationId(String key) => key.hashCode & 0x7fffffff;

  /// Plant alle Push-Erinnerungen der nächsten 30 Tage neu (nur Differenzen).
  Future<void> reschedule(CalendarRepository repo, LocalSettings settings) async {
    if (!_ready) return;
    final now = DateTime.now();
    final wanted = <int, (DateTime, String, String)>{};
    if (settings.pushEnabled) {
      final occ = repo.occurrences(
          now.subtract(const Duration(days: 2)), now.add(_horizon));
      final entries = <(DateTime, String, String, String)>[];
      for (final o in occ) {
        final e = o.event;
        if (e == null) continue;
        for (var i = 0; i < e.reminders.length; i++) {
          final r = e.reminders[i];
          if (!r.push) continue;
          final at = reminderTime(o, r);
          if (!at.isAfter(now)) continue;
          entries.add((at, '${o.key}#$i', _title(o), _body(o)));
        }
      }
      entries.sort((a, b) => a.$1.compareTo(b.$1));
      for (final e in entries.take(_maxScheduled)) {
        wanted[notificationId(e.$2)] = (e.$1, e.$3, e.$4);
      }
    }
    final pending = await _plugin.pendingNotificationRequests();
    for (final p in pending) {
      if (!wanted.containsKey(p.id)) await _plugin.cancel(id: p.id);
    }
    for (final entry in wanted.entries) {
      final (at, title, body) = entry.value;
      await _plugin.zonedSchedule(
        id: entry.key,
        title: title,
        body: body,
        scheduledDate: tz.TZDateTime.from(at, tz.local),
        notificationDetails: _details,
        androidScheduleMode: _exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  String _title(Occurrence o) =>
      '${o.emoji.isEmpty ? '' : '${o.emoji} '}${o.title}';

  String _body(Occurrence o) {
    final day = relativeDay(o.start);
    final when = o.allDay ? day : '$day, ${occurrenceTimeText(o)} Uhr';
    final loc = o.event?.location ?? '';
    return loc.isEmpty ? when : '$when · $loc';
  }

  /// Testbenachrichtigung aus den Einstellungen.
  Future<void> showTest() async {
    if (!_ready) return;
    await _plugin.show(
      id: 1,
      title: 'Test-Erinnerung',
      body: 'So sehen Termin-Erinnerungen aus.',
      notificationDetails: _details,
    );
  }
}

/// Hilfsfunktion für Tests: Erinnerungszeit eines Termins am Tag [day].
DateTime reminderAt(CalendarEvent e, Reminder r, DateTime day) =>
    reminderTime(Occurrence(e, null, day, day.add(e.duration)), r);

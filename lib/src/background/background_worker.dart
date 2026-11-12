import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../calendar_repository.dart';
import '../core/source_config.dart';
import '../services/email_service.dart';
import '../services/notification_service.dart';
import '../services/widget_service.dart';
import '../settings.dart';

const kPeriodicTask = 'kalender-sync';

/// Einstiegspunkt des Hintergrund-Workers (eigener Dart-Isolate).
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      await runBackgroundCycle(force: input?['force'] == true);
    } catch (e) {
      debugPrint('Hintergrund-Sync fehlgeschlagen: $e');
    }
    return true;
  });
}

/// Ein Durchlauf: Sync (falls die App nicht offen ist), Erinnerungen neu
/// planen, Widgets aktualisieren, fällige Mails verschicken.
Future<void> runBackgroundCycle({bool force = false}) async {
  final settings = await LocalSettings.load();
  final dir = await getApplicationSupportDirectory();
  final configStore = SourceConfigStore();
  final repo = CalendarRepository(
      baseDir: dir.path,
      configStore: configStore,
      userName: () => settings.userName);
  await repo.open();
  if (repo.sources.isEmpty) return;

  final beat = settings.foregroundBeat;
  final appActive =
      !force && beat != null && DateTime.now().difference(beat).inMinutes < 3;
  if (!appActive) await repo.syncAll();

  final notifications = NotificationService();
  await notifications.init(requestPermissions: false);
  await notifications.reschedule(repo, settings);
  await WidgetService.update(repo, settings);
  if (!appActive) {
    await EmailService.dispatchDue(
        repo, settings, await configStore.readSecret('smtp_password'));
  }
}

Future<void> registerBackgroundWork() async {
  if (!Platform.isAndroid) return;
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    kPeriodicTask,
    kPeriodicTask,
    frequency: const Duration(minutes: 15),
    // Energie sparen: nur mit Netz (ohne Netz gibt es nichts abzugleichen).
    // „update“ übernimmt geänderte Bedingungen auch für bereits registrierte Aufgaben.
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}

/// Werkstatt-Test: denselben Hintergrund-Durchlauf einmalig nach [delay]
/// auslösen (periodische Arbeit lässt Android nicht vorzeitig laufen).
Future<void> triggerBackgroundOnce({Duration delay = const Duration(seconds: 15)}) async {
  if (!Platform.isAndroid) return;
  await Workmanager().registerOneOffTask(
    '$kPeriodicTask-test-${DateTime.now().millisecondsSinceEpoch}',
    '$kPeriodicTask-test',
    initialDelay: delay,
    inputData: {'force': true},
  );
}

import 'dart:async';
import 'dart:io';

import 'dart:ui' show PlatformDispatcher, PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app_state.dart';
import 'src/background/background_worker.dart';
import 'src/calendar_repository.dart';
import 'src/core/app_log.dart';
import 'src/core/source_config.dart';
import 'src/services/notification_service.dart';
import 'src/settings.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/onboarding_screen.dart';
import 'src/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await LocalSettings.load();
  final dir = await getApplicationSupportDirectory();
  await AppLog.init(dir.path);
  FlutterError.onError = (details) {
    // Mit dem auslösenden Widget (z. B. bei Layout-Überläufen), gekürzt.
    final text = details.toString();
    AppLog.error('flutter', text.length > 1500 ? '${text.substring(0, 1500)}…' : text, null,
        details.exception is Error ? details.stack : null);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.error('app', 'Unbehandelter Fehler', error, stack);
    return false;
  };
  unawaited(PackageInfo.fromPlatform().then((p) => AppLog.info('app',
      'Start, Version ${p.version} (${p.buildNumber}), ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')).catchError((_) {}));
  final configStore = SourceConfigStore();
  final repo = CalendarRepository(
      baseDir: dir.path, configStore: configStore, userName: () => settings.userName);
  final state = AppState(
    repo: repo,
    settings: settings,
    notifications: NotificationService(),
    configStore: configStore,
  );
  runApp(CalendarApp(state: state));
  await state.initialize();
  unawaited(registerBackgroundWork().catchError((Object e) {
    AppLog.warn('app', 'Hintergrund-Sync nicht verfügbar: $e');
  }));
}

class CalendarApp extends StatelessWidget {
  const CalendarApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => MaterialApp(
        title: 'Kalender',
        debugShowCheckedModeBanner: false,
        scrollBehavior: const MaterialScrollBehavior().copyWith(dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        }),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: buildTheme(state.settings.themeColor, Brightness.light),
        darkTheme: buildTheme(state.settings.themeColor, Brightness.dark),
        home: !state.initialized
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : state.isConfigured
                ? HomeScreen(state: state)
                : OnboardingScreen(state: state),
      ),
    );
  }
}

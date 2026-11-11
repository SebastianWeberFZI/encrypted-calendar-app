import 'dart:async';

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app_state.dart';
import 'src/background/background_worker.dart';
import 'src/calendar_repository.dart';
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
    debugPrint('Hintergrund-Sync nicht verfügbar: $e');
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

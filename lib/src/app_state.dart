import 'dart:async';

import 'package:flutter/widgets.dart';

import 'calendar_repository.dart';
import 'core/github_api.dart';
import 'core/source_config.dart';
import 'models/calendar_models.dart';
import 'models/occurrences.dart';
import 'services/email_service.dart';
import 'services/notification_service.dart';
import 'services/widget_service.dart';
import 'settings.dart';

/// Zentraler UI-Zustand: Datenquellen, Sichtbarkeit, Sync, Folgeaktionen
/// (Erinnerungen, Widgets, Mails) nach Datenänderungen.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({
    required this.repo,
    required this.settings,
    required this.notifications,
    required this.configStore,
  });

  final CalendarRepository repo;
  final LocalSettings settings;
  final NotificationService notifications;
  final SourceConfigStore configStore;

  bool initialized = false;
  bool syncing = false;
  String? lastSyncMessage;
  Timer? _syncDebounce;
  Timer? _sideEffectsDebounce;
  Timer? _minuteTimer;
  Timer? _autoSync;

  /// Für Hinweise aus Hintergrundaktionen (Snackbar in der UI).
  final ValueNotifier<String?> toast = ValueNotifier(null);

  bool get isConfigured => repo.sources.isNotEmpty && settings.userName.isNotEmpty;
  List<CalendarDef> get calendars => repo.calendars;
  List<SourceRuntime> get sources => repo.sources;

  // ------------------------------------------------------------ Start

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    await repo.open();
    await notifications.init();
    initialized = true;
    notifyListeners();
    _startTimers();
    if (repo.sources.isNotEmpty) {
      unawaited(syncNow(silent: true));
      _scheduleSideEffects();
    }
  }

  void _startTimers() {
    _minuteTimer?.cancel();
    _minuteTimer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
    _autoSync?.cancel();
    _autoSync = Timer.periodic(
        const Duration(minutes: 1), (_) => syncNow(silent: true));
    settings.foregroundBeat = DateTime.now();
  }

  Future<void> _tick() async {
    settings.foregroundBeat = DateTime.now();
    await _sendMails();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTimers();
      unawaited(() async {
        if (await repo.reloadIfChangedOnDisk()) notifyListeners();
        await syncNow(silent: true);
      }());
    } else if (state == AppLifecycleState.paused) {
      _minuteTimer?.cancel();
      _autoSync?.cancel();
      settings.foregroundBeat = null;
    }
  }

  // ------------------------------------------------------------ Sichtbarkeit

  Set<String> get hidden => settings.hiddenCalendars;
  bool isVisible(CalendarDef c) => !hidden.contains(c.key);
  Set<String> get visibleKeys =>
      {for (final c in calendars) if (isVisible(c)) c.key};

  void toggleCalendar(CalendarDef c) {
    final h = Set.of(hidden);
    if (!h.remove(c.key)) h.add(c.key);
    settings.hiddenCalendars = h;
    _changed(data: false);
  }

  /// Nur diesen Kalender anzeigen (langes Tippen auf den Chip).
  void soloCalendar(CalendarDef c) {
    settings.hiddenCalendars = {
      for (final x in calendars) if (x.key != c.key) x.key
    };
    _changed(data: false);
  }

  void showAllCalendars() {
    settings.hiddenCalendars = {};
    _changed(data: false);
  }

  bool get allVisible => hidden.where((k) => calendars.any((c) => c.key == k)).isEmpty;

  /// Sichtbare Vorkommen im Zeitraum, inkl. Feiertage (falls aktiv).
  List<Occurrence> occurrences(DateTime from, DateTime to) =>
      repo.occurrences(from, to,
          calendarKeys: visibleKeys,
          holidayState: settings.showHolidays ? settings.holidayState : null);

  // ------------------------------------------------------------ Schreiben

  Future<void> saveEvent(CalendarEvent e, {String? previousSourceId}) async {
    await repo.saveEvent(e, previousSourceId: previousSourceId);
    _changed();
  }

  Future<void> saveEvents(List<CalendarEvent> list) async {
    for (final e in list) {
      await repo.saveEvent(e);
    }
    _changed();
  }

  Future<void> deleteEvent(CalendarEvent e) async {
    await repo.deleteEvent(e);
    _changed();
  }

  Future<void> deleteOccurrence(CalendarEvent e, DateTime day) async {
    await repo.deleteOccurrence(e, day);
    _changed();
  }

  Future<void> endSeriesBefore(CalendarEvent e, DateTime day) async {
    await repo.endSeriesBefore(e, day);
    _changed();
  }

  Future<void> saveCalendar(CalendarDef c) async {
    await repo.saveCalendar(c);
    _changed();
  }

  Future<void> deleteCalendar(CalendarDef c) async {
    await repo.deleteCalendar(c);
    _changed();
  }

  void settingsChanged() => _changed(data: false);

  void _changed({bool data = true}) {
    notifyListeners();
    _scheduleSideEffects();
    if (data) {
      _syncDebounce?.cancel();
      _syncDebounce =
          Timer(const Duration(seconds: 2), () => syncNow(silent: true));
    }
  }

  void _scheduleSideEffects() {
    _sideEffectsDebounce?.cancel();
    _sideEffectsDebounce = Timer(const Duration(milliseconds: 800), () async {
      await notifications.reschedule(repo, settings);
      await WidgetService.update(repo, settings);
    });
  }

  Future<void> _sendMails() async {
    try {
      await settings.reload();
      final n = await EmailService.dispatchDue(
          repo, settings, await configStore.readSecret('smtp_password'));
      if (n > 0) toast.value = '$n E-Mail-Erinnerung${n == 1 ? '' : 'en'} versendet';
    } catch (e) {
      debugPrint('Mail-Versand fehlgeschlagen: $e');
    }
  }

  // ------------------------------------------------------------ Sync

  Future<void> syncNow({bool silent = false}) async {
    if (syncing || repo.sources.isEmpty) return;
    syncing = true;
    if (!silent) notifyListeners();
    try {
      final before = repo.version;
      final results = await repo.syncAll();
      final changes = results.fold<int>(0, (s, r) => s + r.pulled);
      final conflicts = results.fold<int>(0, (s, r) => s + r.conflicts);
      final notices = [
        for (final s in repo.sources)
          if (s.notice != null) '${s.config.label}: ${s.notice}'
      ];
      lastSyncMessage = sourceErrors.isNotEmpty
          ? sourceErrors.first
          : conflicts > 0
              ? '$conflicts Konflikt(e) – Kopien mit „(Konflikt)“ angelegt'
              : notices.firstOrNull;
      if (!silent && changes == 0 && sourceErrors.isEmpty) {
        toast.value = 'Alles aktuell';
      }
      if (repo.version != before) _scheduleSideEffects();
    } finally {
      syncing = false;
      notifyListeners();
      if (sourceErrors.isEmpty && repo.pendingCount > 0) {
        _syncDebounce?.cancel();
        _syncDebounce =
            Timer(const Duration(seconds: 3), () => syncNow(silent: true));
      }
    }
  }

  /// true, wenn die Meldung um ein App-Update bittet (kein Verbindungsfehler).
  bool get lastSyncNeedsUpdate =>
      lastSyncMessage?.contains('neueren App-Version') ?? false;

  List<String> get sourceErrors => [
        for (final s in repo.sources)
          if (s.error != null) '${s.config.label}: ${s.error}'
      ];

  // ------------------------------------------------------------ Einrichtung

  Future<(SourceRuntime, bool)> addSource({
    required String label,
    required GithubConfig github,
    required String passphrase,
  }) async {
    final r = await repo.addSource(
        label: label, github: github, passphrase: passphrase);
    _changed(data: false);
    return r;
  }

  Future<void> removeSource(SourceRuntime s) async {
    await repo.removeSource(s);
    _changed(data: false);
  }

  void setUserName(String name) {
    settings.userName = name.trim();
    notifyListeners();
  }

  /// Legt die Standard-Kalender in einer frischen Datenquelle an.
  Future<void> createCalendars(String sourceId, List<CalendarDef> defs) async {
    for (var i = 0; i < defs.length; i++) {
      defs[i].sortOrder = i;
      await repo.saveCalendar(defs[i]);
    }
    _changed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _minuteTimer?.cancel();
    _autoSync?.cancel();
    super.dispose();
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';

import '../app_state.dart';
import '../models/calendar_models.dart';
import '../settings.dart';
import 'agenda_view.dart';
import 'calendar_bar.dart';
import 'calendar_nav.dart';
import 'event_editor.dart';
import 'format.dart';
import 'legend_sheet.dart';
import 'month_view.dart';
import 'settings_screen.dart';
import 'week_view.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});
  final AppState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final nav = CalendarNav();
  StreamSubscription<Uri?>? _widgetClicks;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.toast.addListener(_showToast);
    // Tipp auf ein Widget öffnet den passenden Tag.
    if (Platform.isAndroid) {
      HomeWidget.initiallyLaunchedFromHomeWidget().then(_handleWidgetUri).catchError((_) {});
      _widgetClicks = HomeWidget.widgetClicked.listen(_handleWidgetUri, onError: (_) {});
    }
  }

  @override
  void dispose() {
    state.toast.removeListener(_showToast);
    _widgetClicks?.cancel();
    nav.dispose();
    super.dispose();
  }

  void _handleWidgetUri(Uri? uri) {
    if (uri == null || !mounted) return;
    // Aus dem Widget kommend: offene Seiten (Einstellungen, Editor …) schließen,
    // damit der gewählte Tag bzw. der neue Termin auch zu sehen ist.
    Navigator.of(context).popUntil((r) => r.isFirst);
    final d = DateTime.tryParse(uri.queryParameters['date'] ?? '');
    if (d != null) {
      nav.jumpTo(d);
      if (state.settings.viewMode == CalendarViewMode.agenda) {
        state.settings.viewMode = CalendarViewMode.month;
        state.settingsChanged();
      }
    }
    if (uri.host == 'new') openEventEditor(context, state, initialDay: d ?? DateTime.now());
  }

  void _showToast() {
    final msg = state.toast.value;
    if (msg == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
    state.toast.value = null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([state, nav]),
      builder: (context, _) {
        final mode = state.settings.viewMode;
        final theme = Theme.of(context);
        final today = dateOnly(DateTime.now());
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 20,
            title: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _pickMonth,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(mode == CalendarViewMode.agenda ? 'Demnächst' : fmtMonthYear(nav.focused)),
                if (mode != CalendarViewMode.agenda) const Icon(Icons.arrow_drop_down),
              ]),
            ),
            actions: [
              _SyncIndicator(state: state),
              if (state.calendars.any((c) => state.isVisible(c) && c.colorLabels.isNotEmpty))
                IconButton(
                  tooltip: 'Farblegende',
                  icon: const Icon(Icons.palette_outlined),
                  onPressed: () => showLegend(context, state),
                ),
              IconButton(
                tooltip: 'Heute',
                onPressed: () => nav.jumpTo(today),
                icon: Stack(alignment: Alignment.center, children: [
                  const Icon(Icons.calendar_today_outlined),
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text('${today.day}',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
              IconButton(
                tooltip: 'Einstellungen',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => SettingsScreen(state: state))),
              ),
            ],
          ),
          body: Column(children: [
            if (state.settings.showCalendarBar && state.calendars.length > 1) CalendarBar(state: state),
            if (state.lastSyncMessage != null)
              MaterialBanner(
                content: Text(state.lastSyncMessage!),
                leading: Icon(state.lastSyncNeedsUpdate
                    ? Icons.system_update_alt
                    : Icons.cloud_off_outlined),
                backgroundColor: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                actions: [TextButton(onPressed: () => state.syncNow(), child: const Text('Erneut'))],
              ),
            Expanded(
              child: switch (mode) {
                CalendarViewMode.month => MonthView(state: state, nav: nav),
                CalendarViewMode.week => WeekView(state: state, nav: nav),
                CalendarViewMode.agenda => AgendaView(state: state, nav: nav),
              },
            ),
          ]),
          floatingActionButton: FloatingActionButton(
            tooltip: 'Neuer Termin',
            onPressed: () => openEventEditor(context, state, initialDay: nav.selected ?? today),
            child: const Icon(Icons.add),
          ),
          bottomNavigationBar: NavigationBar(
                  height: 64,
                  selectedIndex: mode.index,
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                  onDestinationSelected: (i) {
                    state.settings.viewMode = CalendarViewMode.values[i];
                    state.settingsChanged();
                  },
                  destinations: const [
                    NavigationDestination(icon: Icon(Icons.calendar_view_month_outlined),
                        selectedIcon: Icon(Icons.calendar_view_month), label: 'Monat'),
                    NavigationDestination(icon: Icon(Icons.view_week_outlined),
                        selectedIcon: Icon(Icons.view_week), label: 'Woche'),
                    NavigationDestination(icon: Icon(Icons.view_agenda_outlined),
                        selectedIcon: Icon(Icons.view_agenda), label: 'Liste'),
                  ],
                ),
        );
      },
    );
  }

  Future<void> _pickMonth() async {
    final d = await showDatePicker(
      context: context,
      initialDate: nav.focused,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
      helpText: 'Springe zu',
    );
    if (d != null) nav.jumpTo(d);
  }
}

class _SyncIndicator extends StatelessWidget {
  const _SyncIndicator({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (state.syncing) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final pending = state.repo.pendingCount;
    final err = state.sourceErrors.isNotEmpty;
    return IconButton(
      tooltip: err
          ? 'Sync-Fehler'
          : pending > 0
              ? '$pending Änderung(en) noch nicht übertragen'
              : 'Synchronisiert',
      onPressed: () => state.syncNow(),
      icon: Badge(
        isLabelVisible: pending > 0,
        label: Text('$pending'),
        child: Icon(err
            ? Icons.cloud_off_outlined
            : pending > 0
                ? Icons.cloud_upload_outlined
                : Icons.cloud_done_outlined),
      ),
    );
  }
}

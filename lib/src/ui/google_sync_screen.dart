import 'package:flutter/material.dart';
import 'package:system_calendar/system_calendar.dart';

import '../app_state.dart';
import '../models/calendar_models.dart';
import '../sync/device_calendar.dart';
import '../sync/google_sync_service.dart';
import 'format.dart';

/// Einstellungen für den Abgleich mit dem Kalender dieses Handys (Google).
class GoogleSyncScreen extends StatefulWidget {
  const GoogleSyncScreen({super.key, required this.state});
  final AppState state;

  @override
  State<GoogleSyncScreen> createState() => _GoogleSyncScreenState();
}

class _GoogleSyncScreenState extends State<GoogleSyncScreen> {
  AppState get state => widget.state;
  List<DeviceCalendar> _devCals = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadCalendars();
  }

  Future<void> _loadCalendars() async {
    if (!await SystemCalendar.hasPermission()) return;
    final cals = await GoogleSyncService.api.calendars();
    cals.sort((a, b) => (b.isMain ? 1 : 0) - (a.isMain ? 1 : 0));
    if (mounted) setState(() => _devCals = cals);
  }

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  CalendarDef? get _importCal => state.repo.calendar(state.settings.googleImportCalendar);

  Future<void> _enable() async {
    final s = state.settings;
    if (s.userName.isEmpty) return _toast('Bitte zuerst unter Profil deinen Namen eintragen.');
    if (!await SystemCalendar.requestPermission()) {
      return _toast('Ohne Zugriff auf den Kalender des Handys geht es nicht.');
    }
    await _loadCalendars();
    final writable = _devCals.where((c) => c.writable).toList();
    if (writable.isEmpty) {
      return _toast('Kein beschreibbarer Kalender auf dem Handy – Google-Konto in den '
          'Android-Einstellungen hinzufügen und Kalender-Synchronisierung einschalten.');
    }
    final main = writable.where((c) => c.isGoogle && c.isMain).firstOrNull ??
        writable.where((c) => c.isMain).firstOrNull ??
        writable.first;
    // Datenquelle für die übernommenen Termine (Standard: die gemeinsame)
    var importCal = _importCal;
    if (importCal == null) {
      final sources = state.sources;
      if (sources.isEmpty) return;
      var src = sources.where((x) => x.config.label.toLowerCase().contains('gemeinsam')).firstOrNull ?? sources.first;
      if (sources.length > 1 && mounted) {
        final picked = await showDialog<String>(
          context: context,
          builder: (c) => SimpleDialog(
            title: const Text('Wo sollen deine Google-Termine erscheinen?'),
            children: [
              for (final x in sources)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(c, x.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text('${x.config.label}${x.id == src.id ? '  (empfohlen)' : ''}'),
                  ),
                ),
            ],
          ),
        );
        if (picked == null) return;
        src = sources.firstWhere((x) => x.id == picked);
      }
      importCal = GoogleSyncService.newImportCalendar(src.id, s.userName);
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Abgleich einschalten?'),
        content: Text(
            '• Termine aus allen App-Kalendern werden in „${main.label}“ gespeichert.\n'
            '• Termine aus „${main.label}“ erscheinen hier im Kalender „${importCal!.name}“. '
            'Alle, die diese Datenquelle nutzen, sehen sie – ändern kannst nur du.\n'
            '• Änderungen und Löschungen laufen in beide Richtungen.\n\n'
            'Mach das nur auf einem Handy pro Google-Konto.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Einschalten')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      if (_importCal == null) await state.saveCalendar(importCal);
      s.googleImportCalendar = importCal.key;
      if (s.googleDefaultTarget < 0 || !_devCals.any((c) => c.id == s.googleDefaultTarget)) {
        s.googleDefaultTarget = main.id;
      }
      if (s.googleImportFrom.isEmpty) s.googleImportFrom = [main.id];
      s.googleSync = true;
      final r = await state.googleSyncNow(force: true);
      if (r != null) _toast(r.summary);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable() async {
    var remove = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Abgleich beenden?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: remove,
              onChanged: (v) => set(() => remove = v ?? false),
              title: const Text('App-Termine aus dem Handy-Kalender entfernen'),
            ),
            Text('Der Kalender „${_importCal?.name ?? 'Google'}“ bleibt in der App; '
                'löschen kannst du ihn unter Kalender verwalten.'),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Beenden')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final n = await GoogleSyncService.stop(state.repo, state.settings, removeCopies: remove);
    state.settingsChanged();
    if (mounted) setState(() {});
    _toast(remove ? 'Abgleich beendet, $n Kopien entfernt' : 'Abgleich beendet');
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    try {
      await state.googleSyncNow(force: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changed() {
    state.settingsChanged();
    setState(() {});
    _syncNow();
  }

  Widget _targetDropdown(int value, ValueChanged<int> onChanged, {bool withDefault = false}) {
    final items = <int, String>{
      if (withDefault) -2: 'Wie oben',
      for (final c in _devCals.where((c) => c.writable)) c.id: c.label,
      -1: 'Nicht übertragen',
    };
    return DropdownButton<int>(
      isExpanded: true,
      value: items.containsKey(value) ? value : (withDefault ? -2 : -1),
      items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
      onChanged: (v) => onChanged(v ?? -1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final s = state.settings;
        final on = s.googleSync;
        final importCal = _importCal;
        Widget header(String t) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 6),
              child: Text(t,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
            );
        final appCals = state.calendars.where((c) => c.key != importCal?.key && !c.isSynced).toList();
        final targets = s.googleTargets;
        return Scaffold(
          appBar: AppBar(title: const Text('Google-Kalender')),
          body: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                'Gleicht die Termine mit dem Kalender dieses Handys ab, z. B. deinem Google-Kalender. '
                'App-Termine landen dort, deine Google-Termine erscheinen hier in einem eigenen Kalender. '
                'Der Abgleich läuft auf diesem Handy, auch im Hintergrund.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.sync_alt),
              title: const Text('Mit dem Kalender dieses Handys abgleichen'),
              value: on,
              onChanged: _busy ? null : (v) => v ? _enable() : _disable(),
            ),
            if (on) ...[
              ListTile(
                leading: Icon(s.googleStatusIsError ? Icons.error_outline : Icons.check_circle_outline,
                    color: s.googleStatusIsError ? theme.colorScheme.error : theme.colorScheme.primary),
                title: Text(s.googleStatus.isEmpty ? 'Noch nicht abgeglichen' : s.googleStatus),
                subtitle: s.googleLastRun == null
                    ? null
                    : Text('Zuletzt ${fmtDate(s.googleLastRun!)} um ${fmtTime(s.googleLastRun!)} Uhr'),
                trailing: _busy || state.googleSyncing
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : IconButton(tooltip: 'Jetzt abgleichen', icon: const Icon(Icons.refresh), onPressed: _syncNow),
              ),
              header('App → Handy-Kalender'),
              ListTile(
                leading: const Icon(Icons.upload_outlined),
                title: const Text('App-Termine speichern in'),
                subtitle: _targetDropdown(s.googleDefaultTarget, (v) {
                  s.googleDefaultTarget = v;
                  _changed();
                }),
              ),
              ExpansionTile(
                leading: const Icon(Icons.tune),
                title: const Text('Je App-Kalender'),
                subtitle: Text(targets.isEmpty ? 'Alle wie oben' : '${targets.length} abweichend'),
                children: [
                  for (final c in appCals)
                    ListTile(
                      leading: CircleAvatar(backgroundColor: Color(c.color), radius: 8),
                      title: Text(c.name),
                      subtitle: _targetDropdown(targets[c.key] ?? -2, (v) {
                        final t = Map.of(targets);
                        v == -2 ? t.remove(c.key) : t[c.key] = v;
                        s.googleTargets = t;
                        _changed();
                      }, withDefault: true),
                    ),
                ],
              ),
              header('Handy-Kalender → App'),
              for (final c in _devCals)
                CheckboxListTile(
                  secondary: CircleAvatar(backgroundColor: Color(c.color), radius: 8),
                  title: Text(c.name),
                  subtitle: Text([if (c.account.isNotEmpty && c.account != c.name) c.account, if (!c.writable) 'nur lesen']
                      .join(' · ')),
                  value: s.googleImportFrom.contains(c.id),
                  onChanged: (v) {
                    final l = List.of(s.googleImportFrom)..remove(c.id);
                    if (v == true) l.add(c.id);
                    s.googleImportFrom = l;
                    _changed();
                  },
                ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: Text(importCal == null ? 'Kalender für die Termine fehlt' : 'Erscheinen im Kalender „${importCal.name}“'),
                subtitle: Text(importCal == null
                    ? 'Abgleich aus- und wieder einschalten, um ihn neu anzulegen.'
                    : '${state.repo.source(importCal.sourceId)?.config.label ?? ''} · alle sehen sie, '
                        'nur du (${s.userName}) kannst sie ändern'),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  'Gut zu wissen: Ändern beide Seiten denselben Termin, gewinnt die Seite, aus der er stammt. '
                  'Serien, die die App nicht abbilden kann (z. B. „jeden 2. Dienstag“), erscheinen als '
                  'einzelne Termine und lassen sich nur im Google-Kalender ändern. Erinnerungen und Teilnehmer '
                  'werden nicht übertragen. Verschwinden plötzlich viele Termine auf einer Seite, löscht der '
                  'Abgleich nichts und meldet sich hier.',
                ),
              ),
            ],
          ]),
        );
      },
    );
  }
}

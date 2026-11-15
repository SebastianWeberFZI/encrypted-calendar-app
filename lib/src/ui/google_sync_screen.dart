import 'package:flutter/material.dart';
import 'package:system_calendar/system_calendar.dart';

import '../app_state.dart';
import '../models/calendar_models.dart';
import '../sync/device_calendar.dart';
import '../sync/google_sync.dart';
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
    final suggested = writable.where((c) => c.isGoogle && c.isMain).firstOrNull ??
        writable.where((c) => c.isMain).firstOrNull ??
        writable.first;
    // Mit welchem Kalender des Handys? Zum Ausprobieren einen leeren Test-Kalender.
    var main = suggested;
    if (writable.length > 1 && mounted) {
      final picked = await showDialog<int>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Mit welchem Kalender des Handys abgleichen?'),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Zum gefahrlosen Ausprobieren vorher in Google einen leeren Kalender '
                  '(z. B. „App-Test“) anlegen, auf dem Handy synchronisieren lassen und hier wählen.'),
            ),
            for (final c in [suggested, ...writable.where((x) => x.id != suggested.id)])
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, c.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('${c.label}${c.id == suggested.id ? '  (Hauptkalender)' : ''}'),
                ),
              ),
          ],
        ),
      );
      if (picked == null) return;
      main = writable.firstWhere((c) => c.id == picked);
    }
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
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text('Zum Ausprobieren deine private Datenquelle wählen – dann sieht sie niemand sonst.'),
              ),
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
    final CalendarDef cal = importCal;
    if (!mounted) return;
    final config = GoogleSyncConfig(
      importCalendarKey: cal.key,
      importFrom: [main.id],
      defaultTarget: main.id,
      // Ausnahmen „nicht übertragen“ bleiben, Ziele in andere Kalender nicht.
      targets: {for (final e in s.googleTargets.entries) if (e.value < 0) e.key: null},
      pastDays: s.googlePastDays < 0 ? null : s.googlePastDays,
      reminders: s.googleReminders,
    );
    // Bestätigen – auf Wunsch erst ein Probelauf, der nichts ändert.
    while (true) {
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Abgleich einschalten?'),
          content: Text(
              '• Termine aus allen App-Kalendern werden in „${main.label}“ gespeichert.\n'
              '• Termine aus „${main.label}“ erscheinen hier im Kalender „${cal.name}“. '
              'Alle, die diese Datenquelle nutzen, sehen sie – ändern kannst nur du.\n'
              '• Änderungen und Löschungen laufen in beide Richtungen.\n\n'
              'Der Probelauf zeigt vorher, was passieren würde, und ändert nichts.\n'
              'Mach das nur auf einem Handy pro Google-Konto.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Abbrechen')),
            TextButton(onPressed: () => Navigator.pop(c, 'probe'), child: const Text('Probelauf')),
            FilledButton(onPressed: () => Navigator.pop(c, 'on'), child: const Text('Einschalten')),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'on') break;
      setState(() => _busy = true);
      GoogleSyncResult? r;
      String? error;
      try {
        r = await GoogleSyncService.preview(state.repo, s, config, extra: [if (_importCal == null) cal]);
      } catch (e) {
        error = '$e';
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (!mounted) return;
      final go = await _showResult('Probelauf – nichts wurde geändert', r, error, confirm: 'Einschalten');
      if (go == true) break;
      if (!mounted) return;
    }
    setState(() => _busy = true);
    try {
      if (_importCal == null) await state.saveCalendar(cal);
      s.googleImportCalendar = cal.key;
      s.googleDefaultTarget = main.id;
      s.googleImportFrom = [main.id];
      s.googleTargets = {for (final e in s.googleTargets.entries) if (e.value < 0) e.key: e.value};
      s.googleSync = true;
      final r = await state.googleSyncNow(force: true);
      if (r != null) _toast(r.summary);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ergebnis eines (Probe-)Laufs mit Liste der einzelnen Termine.
  Future<bool?> _showResult(String title, GoogleSyncResult? r, String? error, {String? confirm}) =>
      showDialog<bool>(
        context: context,
        builder: (c) {
          final theme = Theme.of(c);
          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: double.maxFinite,
              height: 380,
              child: ListView(children: [
                Text(error ?? r!.summary, style: theme.textTheme.titleSmall),
                for (final w in r?.warnings ?? const <String>[])
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(w, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                const SizedBox(height: 8),
                for (final line in r?.log ?? const <String>[])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(line, style: theme.textTheme.bodySmall),
                  ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(confirm != null ? 'Zurück' : 'Schließen')),
              if (confirm != null && error == null)
                FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(confirm)),
            ],
          );
        },
      );

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

  static const _pastOptions = {90: '90 Tage zurück', 365: '1 Jahr zurück', 1095: '3 Jahre zurück', -1: 'Gesamte Vergangenheit'};

  /// Zeitraum ändern; bei mehr Vergangenheit erst ein Probelauf mit Rückfrage.
  Future<void> _setPastDays(int days) async {
    final s = state.settings;
    final old = s.googlePastDays;
    if (days == old) return;
    final more = days < 0 || (old >= 0 && days > old);
    if (more) {
      setState(() => _busy = true);
      GoogleSyncResult? r;
      String? error;
      try {
        r = await GoogleSyncService.preview(state.repo, s, GoogleSyncService.configFrom(s, pastDays: days));
      } catch (e) {
        error = '$e';
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (!mounted) return;
      final many = (r?.imported ?? 0) + (r?.exported ?? 0) > 400;
      final ok = await _showResult(
          many
              ? 'Probelauf: viele Termine – das erste Hochladen dauert einige Stunden'
              : 'Probelauf – nichts wurde geändert',
          r,
          error,
          confirm: 'Übernehmen');
      if (ok != true) return;
    }
    s.googlePastDays = days;
    _changed();
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
        // Alle außer dem eigenen Google-Kalender – auch „<andere Person> – Google“,
        // damit man deren Termine vom eigenen Google-Kalender fernhalten kann.
        final appCals = state.calendars.where((c) => c.key != importCal?.key).toList();
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
              if (s.googleLog.isNotEmpty)
                ExpansionTile(
                  leading: const Icon(Icons.history),
                  title: const Text('Letzte Änderungen'),
                  childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in s.googleLog)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(line,
                            style: line.startsWith('—')
                                ? theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)
                                : theme.textTheme.bodySmall),
                      ),
                  ],
                ),
              header('Umfang'),
              ListTile(
                leading: const Icon(Icons.history_toggle_off),
                title: Text('Zeitraum: ${_pastOptions[s.googlePastDays] ?? '${s.googlePastDays} Tage zurück'}'),
                subtitle: const Text('Wie weit zurück in beide Richtungen abgeglichen wird; in die Zukunft immer alles.'),
                trailing: const Icon(Icons.chevron_right),
                enabled: !_busy,
                onTap: () async {
                  final v = await showDialog<int>(
                    context: context,
                    builder: (c) => SimpleDialog(
                      title: const Text('Zeitraum'),
                      children: [
                        for (final e in _pastOptions.entries)
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(c, e.key),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(children: [
                                Expanded(child: Text(e.value)),
                                if (e.key == s.googlePastDays) const Icon(Icons.check, size: 18),
                              ]),
                            ),
                          ),
                      ],
                    ),
                  );
                  if (v != null) await _setPastDays(v);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.notifications_none),
                title: const Text('Erinnerungen abgleichen'),
                subtitle: const Text('Benachrichtigungen (z. B. 30 Min. vorher) in beide Richtungen. Auf diesem '
                    'Handy meldet sie dann der Google-Kalender, die App nicht zusätzlich. Erinnerungen an '
                    'Google-Termine anderer bekommst du nicht.'),
                value: s.googleReminders,
                onChanged: _busy
                    ? null
                    : (v) {
                        s.googleReminders = v;
                        _changed();
                      },
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
                      title: Text(c.isSynced && c.syncOwner != s.userName
                          ? '${c.name} (aus dem ${c.syncLabel}-Kalender von ${c.syncOwner})'
                          : c.name),
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
                        'nur du (${s.userName}) kannst sie ändern. Einzelne Termine lassen sich einem anderen '
                        'Kalender zuordnen (Termin antippen → Zuordnen) und bleiben mit Google verbunden.'),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  'Gut zu wissen: Ändern beide Seiten denselben Termin, gewinnt die Seite, aus der er stammt. '
                  'Serien wie „jeden 2. Dienstag“ oder „letzter Freitag im Monat“ werden echte Serien; nur sehr '
                  'seltene Regeln (z. B. stündlich) erscheinen als einzelne Termine, änderbar nur in Google. '
                  'Teilnehmer und Terminfarben werden nicht übertragen. Verschwinden plötzlich viele Termine '
                  'auf einer Seite, löscht der Abgleich nichts und meldet sich hier.',
                ),
              ),
            ],
          ]),
        );
      },
    );
  }
}

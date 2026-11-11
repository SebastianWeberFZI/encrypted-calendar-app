import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_state.dart';
import '../background/background_worker.dart';
import '../calendar_repository.dart';
import '../core/werkstatt.dart';
import '../models/holidays.dart';
import '../services/widget_service.dart';
import '../werkstatt/demo_data.dart';
import 'calendars_screen.dart';
import 'email_settings_screen.dart';
import 'format.dart';
import 'source_setup_screen.dart';
import 'theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final s = state.settings;
        final theme = Theme.of(context);
        Widget header(String t) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 6),
              child: Text(t,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
            );
        return Scaffold(
          appBar: AppBar(title: const Text('Einstellungen')),
          body: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
            header('Profil'),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(s.userName),
              subtitle: const Text('Dein Name bei Änderungen'),
              onTap: () async {
                final n = await _ask(context, 'Dein Name', s.userName);
                if (n != null && n.trim().isNotEmpty) state.setUserName(n);
              },
            ),
            header('Datenquellen'),
            for (final src in state.sources) _SourceTile(state: state, src: src),
            ListTile(
              leading: const Icon(Icons.add_link),
              title: const Text('Datenquelle hinzufügen'),
              subtitle: const Text('z. B. ein privates Repo nur für dich'),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => SourceSetupScreen(state: state, suggestPrivate: true))),
            ),
            header('Kalender'),
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('Kalender verwalten'),
              subtitle: Text(state.calendars.map((c) => c.name).join(', ')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => CalendarsScreen(state: state))),
            ),
            header('Ansicht'),
            SwitchListTile(
              secondary: const Icon(Icons.view_carousel_outlined),
              title: const Text('Kalenderleiste anzeigen'),
              subtitle: const Text('Kalender oben antippen = ein/aus, lange tippen = nur dieser'),
              value: s.showCalendarBar,
              onChanged: (v) { s.showCalendarBar = v; state.settingsChanged(); },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.celebration_outlined),
              title: const Text('Feiertage anzeigen'),
              value: s.showHolidays,
              onChanged: (v) { s.showHolidays = v; state.settingsChanged(); },
            ),
            if (s.showHolidays)
              ListTile(
                leading: const SizedBox(),
                title: const Text('Bundesland'),
                trailing: DropdownButton<String>(
                  value: s.holidayState,
                  underline: const SizedBox(),
                  items: [
                    for (final e in kBundeslaender.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) { if (v != null) { s.holidayState = v; state.settingsChanged(); } },
                ),
              ),
            ListTile(
              leading: const Icon(Icons.format_paint_outlined),
              title: const Text('Designfarbe'),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 10, runSpacing: 8, children: [
                  for (final c in kThemeColors)
                    GestureDetector(
                      onTap: () { s.themeColor = c; state.settingsChanged(); },
                      child: CircleAvatar(
                        radius: 15,
                        backgroundColor: Color(c),
                        child: s.themeColor == c ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                      ),
                    ),
                ]),
              ),
            ),
            header('Benachrichtigungen'),
            SwitchListTile(
              secondary: const Icon(Icons.notifications_active_outlined),
              title: const Text('Push-Erinnerungen'),
              subtitle: const Text('Lokale Benachrichtigungen auf diesem Handy'),
              value: s.pushEnabled,
              onChanged: (v) { s.pushEnabled = v; state.settingsChanged(); },
            ),
            ListTile(
              leading: const SizedBox(),
              title: const Text('Test-Benachrichtigung'),
              onTap: () => state.notifications.showTest(),
            ),
            ListTile(
              leading: const Icon(Icons.alternate_email),
              title: const Text('E-Mail-Benachrichtigungen'),
              subtitle: Text(s.email.enabled && s.email.isComplete
                  ? 'An ${s.email.to}${s.email.dailyAgenda ? ' · Tagesübersicht um ${s.email.dailyAgendaHour} Uhr' : ''}'
                  : 'Aus'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => EmailSettingsScreen(state: state))),
            ),
            header('Widgets'),
            ListTile(
              leading: const Icon(Icons.widgets_outlined),
              title: const Text('Kalender im Widget'),
              subtitle: Text(s.widgetCalendars == null
                  ? 'Wie in der App sichtbar'
                  : state.calendars.where((c) => s.widgetCalendars!.contains(c.key)).map((c) => c.name).join(', ')),
              onTap: () => _pickWidgetCalendars(context),
            ),
            SwitchListTile(
              secondary: const SizedBox(),
              title: const Text('Feiertage im Widget'),
              value: s.widgetShowHolidays,
              onChanged: (v) { s.widgetShowHolidays = v; state.settingsChanged(); },
            ),
            FutureBuilder<bool>(
              future: WidgetService.canPin(),
              builder: (c, snap) => snap.data == true
                  ? Column(children: [
                      ListTile(
                        leading: const Icon(Icons.calendar_view_month_outlined),
                        title: const Text('Monats-Widget hinzufügen'),
                        subtitle: const Text('2–6 Wochen, Größe frei wählbar'),
                        onTap: () => WidgetService.pin(WidgetService.monthProvider),
                      ),
                      ListTile(
                        leading: const Icon(Icons.view_agenda_outlined),
                        title: const Text('Agenda-Widget hinzufügen'),
                        subtitle: const Text('Die nächsten Termine als Liste'),
                        onTap: () => WidgetService.pin(WidgetService.agendaProvider),
                      ),
                    ])
                  : const ListTile(
                      leading: SizedBox(),
                      subtitle: Text('Widget hinzufügen: Startbildschirm lange gedrückt halten → '
                          'Widgets → Kalender. Es gibt „Monat“ (2–6 Wochen) und „Agenda“.'),
                    ),
            ),
            header('Info'),
            FutureBuilder(
              future: PackageInfo.fromPlatform(),
              builder: (c, snap) => ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text('Version ${snap.data?.version ?? ''}${kWerkstatt ? ' (Werkstatt)' : ''}'),
                subtitle: Text(state.repo.lastSync == null
                    ? 'Noch nicht synchronisiert'
                    : 'Letzter Sync ${fmtDate(state.repo.lastSync!)} ${fmtTime(state.repo.lastSync!)}'),
              ),
            ),
            if (kWerkstatt && defaultTargetPlatform == TargetPlatform.android)
              ListTile(
                leading: const Icon(Icons.schedule_send_outlined),
                title: const Text('Hintergrund-Abruf testen'),
                subtitle: const Text('Läuft in 15 s wie im Hintergrund – App danach mit der Home-Taste verlassen'),
                onTap: () async {
                  await triggerBackgroundOnce();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Hintergrund-Abruf in 15 s – jetzt die App verlassen')));
                  }
                },
              ),
            if (kWerkstatt)
              ListTile(
                leading: const Icon(Icons.science_outlined),
                title: const Text('Demo-Termine hinzufügen'),
                onTap: () async {
                  await state.saveEvents(demoEvents(state.calendars, user: s.userName));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Demo-Termine angelegt')));
                  }
                },
              ),
          ]),
        );
      },
    );
  }

  Future<void> _pickWidgetCalendars(BuildContext context) async {
    final s = state.settings;
    final sel = Set.of(s.widgetCalendars ?? state.visibleKeys);
    final result = await showDialog<Set<String>?>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Kalender im Widget'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final cal in state.calendars)
                CheckboxListTile(
                  value: sel.contains(cal.key),
                  title: Text(cal.name),
                  secondary: CircleAvatar(radius: 8, backgroundColor: Color(cal.color)),
                  onChanged: (v) => set(() => v == true ? sel.add(cal.key) : sel.remove(cal.key)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, {'__app__'}), child: const Text('Wie App')),
            FilledButton(onPressed: () => Navigator.pop(c, sel), child: const Text('Übernehmen')),
          ],
        ),
      ),
    );
    if (result == null) return;
    s.widgetCalendars = result.contains('__app__') ? null : result;
    state.settingsChanged();
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.state, required this.src});
  final AppState state;
  final SourceRuntime src;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = src.config;
    final last = src.store.lastSync;
    return ListTile(
      leading: Icon(c.isMock ? Icons.science_outlined : Icons.lock_outline),
      title: Text(c.label),
      subtitle: Text(
        '${c.owner}/${c.repo}\n'
        '${src.error ?? (last == null ? 'noch nicht synchronisiert' : 'Sync ${fmtDate(last)} ${fmtTime(last)}')}'
        '${src.store.pendingCount > 0 ? ' · ${src.store.pendingCount} ausstehend' : ''}',
        style: src.error != null ? TextStyle(color: theme.colorScheme.error) : null,
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          if (v == 'sync') await state.syncNow();
          if (v == 'remove' && context.mounted) {
            final ok = await showDialog<bool>(
              context: context,
              builder: (d) => AlertDialog(
                title: Text('„${c.label}“ entfernen?'),
                content: const Text('Die Datenquelle wird nur von diesem Gerät entfernt. '
                    'Die verschlüsselten Daten im Repository bleiben erhalten.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
                  FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Entfernen')),
                ],
              ),
            );
            if (ok == true) await state.removeSource(src);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'sync', child: Text('Jetzt synchronisieren')),
          PopupMenuItem(value: 'remove', child: Text('Von diesem Gerät entfernen')),
        ],
      ),
    );
  }
}

Future<String?> _ask(BuildContext context, String title, String initial) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('OK')),
      ],
    ),
  );
}

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../calendar_repository.dart';
import '../core/github_api.dart';
import '../core/werkstatt.dart';
import '../werkstatt/demo_data.dart';
import 'calendar_templates.dart';
import 'source_setup_screen.dart';

/// Erster Start: Name + erste Datenquelle.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.state});
  final AppState state;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final _name = TextEditingController(
      text: widget.state.settings.userName.isNotEmpty
          ? widget.state.settings.userName
          : (kWerkstatt ? kWerkstattUser : ''));
  bool _busy = false;
  String? _error;

  AppState get state => widget.state;

  bool _checkName() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Bitte gib deinen Namen ein – er erscheint bei Änderungen.');
      return false;
    }
    state.setUserName(_name.text);
    return true;
  }

  Future<void> _connect() async {
    if (!_checkName()) return;
    if (state.repo.sources.isNotEmpty) {
      state.settingsChanged();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SourceSetupScreen(state: state)));
    state.settingsChanged();
  }

  /// Werkstatt: gemeinsame + private Datenquelle gegen das Mock-Backend
  /// verbinden und (bei leerem Repo) mit Demo-Terminen füllen.
  Future<void> _quickstart() async {
    if (!_checkName()) return;
    setState(() { _busy = true; _error = null; });
    try {
      Future<void> add(String label, String repo, bool private) async {
        final (rt, fresh) = await state.addSource(
          label: label,
          github: GithubConfig(owner: kWerkstattOwner, repo: repo, token: kWerkstattToken,
              apiBase: kWerkstattApiBase),
          passphrase: kWerkstattPassphrase,
        );
        if (fresh || state.repo.calendarsOf(rt.id).isEmpty) {
          await state.createCalendars(rt.id, calendarTemplates(rt.id, private: private));
          await state.saveEvents(demoEvents(state.repo.calendarsOf(rt.id), user: state.settings.userName));
        }
      }
      await add('Gemeinsam', 'kalender-gemeinsam', false);
      await add('Privat', 'kalender-${kWerkstattUser.toLowerCase()}', true);
      await state.syncNow(silent: true);
    } on SetupException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Fehler: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(28, 48, 28, 28), children: [
          Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(Icons.calendar_month, size: 40, color: theme.colorScheme.onPrimaryContainer),
          ),
          const SizedBox(height: 24),
          Text('Euer Kalender', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Text('Gemeinsame und private Kalender – verschlüsselt in euren eigenen '
              'GitHub-Repositories. Niemand außer euch kann die Termine lesen.',
              style: theme.textTheme.bodyLarge),
          const SizedBox(height: 32),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Dein Name',
              helperText: 'Wird bei Änderungen angezeigt („geändert von …“)',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 28),
          FilledButton.icon(
            icon: const Icon(Icons.link),
            label: const Text('Datenquelle verbinden'),
            onPressed: _busy ? null : _connect,
          ),
          if (kWerkstatt) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bolt),
              label: const Text('Werkstatt-Schnellstart mit Demo-Terminen'),
              onPressed: _busy ? null : _quickstart,
            ),
            const SizedBox(height: 8),
            Text('Verbindet „Gemeinsam“ und „Privat“ mit dem Mock-Backend.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          ],
        ]),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../calendar_repository.dart';
import '../core/github_api.dart';
import '../core/werkstatt.dart';
import '../models/calendar_models.dart';
import 'calendar_templates.dart';

/// Datenquelle (privates GitHub-Repo + Passphrase) verbinden.
class SourceSetupScreen extends StatefulWidget {
  const SourceSetupScreen({super.key, required this.state, this.suggestPrivate = false});
  final AppState state;
  final bool suggestPrivate;

  @override
  State<SourceSetupScreen> createState() => _SourceSetupScreenState();
}

class _SourceSetupScreenState extends State<SourceSetupScreen> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.suggestPrivate ? 'Privat' : 'Gemeinsam');
  final _owner = TextEditingController(text: kWerkstatt ? kWerkstattOwner : '');
  late final _repo = TextEditingController(
      text: kWerkstatt ? (widget.suggestPrivate ? 'kalender-${kWerkstattUser.toLowerCase()}' : 'kalender-gemeinsam') : '');
  final _branch = TextEditingController(text: 'main');
  final _token = TextEditingController(text: kWerkstatt ? kWerkstattToken : '');
  final _api = TextEditingController(text: kWerkstatt ? kWerkstattApiBase : kGithubApiBase);
  final _pass = TextEditingController(text: kWerkstatt ? kWerkstattPassphrase : '');
  bool _showAdvanced = kWerkstatt;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  GithubConfig get _github => GithubConfig(
        owner: _owner.text.trim(),
        repo: _repo.text.trim(),
        branch: _branch.text.trim().isEmpty ? 'main' : _branch.text.trim(),
        token: _token.text.trim(),
        apiBase: _api.text.trim().isEmpty ? kGithubApiBase : _api.text.trim(),
      );

  Future<void> _test() async {
    setState(() { _busy = true; _error = null; });
    final err = await CalendarRepository.testConnection(_github);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err ?? 'Verbindung erfolgreich ✓')));
  }

  Future<void> _connect() async {
    if (!_form.currentState!.validate()) return;
    setState(() { _busy = true; _error = null; });
    try {
      final (rt, fresh) = await widget.state.addSource(
          label: _label.text.trim(), github: _github, passphrase: _pass.text);
      if (!mounted) return;
      if (fresh || widget.state.repo.calendarsOf(rt.id).isEmpty) {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => _TemplatePage(
                state: widget.state, sourceId: rt.id, private: widget.suggestPrivate)));
      }
      if (mounted) Navigator.of(context).pop(true);
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
      appBar: AppBar(title: const Text('Datenquelle verbinden')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text('Ein privates GitHub-Repository speichert die Termine – jede Datei '
              'einzeln verschlüsselt. Für gemeinsame Kalender nutzt ihr dasselbe '
              'Repo und dieselbe Passphrase; für private Kalender ein eigenes.',
              style: theme.textTheme.bodyMedium),
          if (kWerkstatt)
            Card(
              margin: const EdgeInsets.only(top: 12),
              color: theme.colorScheme.tertiaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Werkstatt-Modus: Felder sind für das Mock-Backend vorbelegt.'),
              ),
            ),
          const SizedBox(height: 16),
          _field(_label, 'Name der Datenquelle', hint: 'z. B. Gemeinsam, Privat'),
          _field(_owner, 'GitHub-Besitzer', hint: 'z. B. SebastianWeber'),
          _field(_repo, 'Repository', hint: 'z. B. encrypted-calendar-gemeinsam'),
          TextFormField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Fine-grained Personal Access Token',
              helperText: 'Nur „Contents: Read and write“ auf genau dieses Repo',
            ),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Pflichtfeld' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _pass,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Passphrase',
              helperText: 'Neues Repo: wird festgelegt. Bestehendes: gleiche Passphrase wie auf den anderen Geräten.',
              helperMaxLines: 3,
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            validator: (v) => (v ?? '').length < 8 ? 'Mindestens 8 Zeichen' : null,
          ),
          const SizedBox(height: 8),
          Text('⚠ Passphrase vergessen = Daten verloren. Es gibt keine Wiederherstellung.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Erweitert'),
            initiallyExpanded: _showAdvanced,
            onExpansionChanged: (v) => _showAdvanced = v,
            children: [
              _field(_branch, 'Branch'),
              _field(_api, 'API-Adresse', hint: kGithubApiBase),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 20),
          Row(children: [
            OutlinedButton(onPressed: _busy ? null : _test, child: const Text('Verbindung testen')),
            const Spacer(),
            FilledButton(
              onPressed: _busy ? null : _connect,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Verbinden'),
            ),
          ]),
          const SizedBox(height: 8),
          Text('Das Ableiten des Schlüssels dauert einige Sekunden.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        ]),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, {String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: c,
          decoration: InputDecoration(labelText: label, hintText: hint),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Pflichtfeld' : null,
        ),
      );
}

/// Nach dem Anlegen eines leeren Repos: erste Kalender auswählen.
class _TemplatePage extends StatefulWidget {
  const _TemplatePage({required this.state, required this.sourceId, required this.private});
  final AppState state;
  final String sourceId;
  final bool private;

  @override
  State<_TemplatePage> createState() => _TemplatePageState();
}

class _TemplatePageState extends State<_TemplatePage> {
  late final List<CalendarDef> _templates = calendarTemplates(widget.sourceId, private: widget.private);
  late final Set<int> _selected = {for (var i = 0; i < _templates.length; i++) i};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kalender anlegen')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('Welche Kalender sollen in dieser Datenquelle entstehen? '
              'Name, Farbe und weitere Kalender lassen sich später in den Einstellungen ändern.'),
        ),
        for (var i = 0; i < _templates.length; i++)
          CheckboxListTile(
            value: _selected.contains(i),
            onChanged: (v) => setState(() => v == true ? _selected.add(i) : _selected.remove(i)),
            secondary: CircleAvatar(
              backgroundColor: Color(_templates[i].color),
              child: Text(_templates[i].emoji),
            ),
            title: Text(_templates[i].name),
            subtitle: Text(_templates[i].kind.label),
          ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: () async {
              await widget.state.createCalendars(widget.sourceId,
                  [for (var i = 0; i < _templates.length; i++) if (_selected.contains(i)) _templates[i]]);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Fertig'),
          ),
        ),
      ),
    );
  }
}

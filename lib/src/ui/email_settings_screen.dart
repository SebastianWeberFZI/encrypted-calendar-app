import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/werkstatt.dart';
import '../services/email_service.dart';
import '../settings.dart';

/// SMTP-Zugang für E-Mail-Erinnerungen (gilt nur für dieses Gerät).
class EmailSettingsScreen extends StatefulWidget {
  const EmailSettingsScreen({super.key, required this.state});
  final AppState state;

  @override
  State<EmailSettingsScreen> createState() => _EmailSettingsScreenState();
}

class _EmailSettingsScreenState extends State<EmailSettingsScreen> {
  late EmailSettings _s = widget.state.settings.email;
  late final _host = TextEditingController(text: _s.host);
  late final _port = TextEditingController(text: '${_s.port}');
  late final _user = TextEditingController(text: _s.username);
  late final _from = TextEditingController(text: _s.from);
  late final _to = TextEditingController(text: _s.to);
  final _pass = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.state.configStore.readSecret('smtp_password').then((v) {
      if (mounted && v != null) _pass.text = v;
    });
  }

  EmailSettings _collect() => EmailSettings(
        enabled: _s.enabled,
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? 587,
        ssl: _s.ssl,
        username: _user.text.trim(),
        from: _from.text.trim(),
        to: _to.text.trim(),
        dailyAgenda: _s.dailyAgenda,
        dailyAgendaHour: _s.dailyAgendaHour,
        excludedCalendars: _s.excludedCalendars,
      );

  Future<void> _persist() async {
    _s = _collect();
    widget.state.settings.email = _s;
    await widget.state.configStore.writeSecret('smtp_password', _pass.text.isEmpty ? null : _pass.text);
    widget.state.settingsChanged();
  }

  Future<void> _test() async {
    await _persist();
    setState(() => _busy = true);
    try {
      await EmailService.send(_s, _pass.text,
          subject: 'Test vom Kalender',
          body: 'Wenn du diese Mail liest, funktionieren E-Mail-Erinnerungen. 🎉');
      _snack('Test-Mail an ${_s.to} verschickt.');
    } catch (e) {
      _snack('Versand fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _useWerkstatt() {
    setState(() {
      _host.text = kWerkstattHost;
      _port.text = '2525';
      _s.ssl = false;
      _user.text = 'werkstatt';
      _pass.text = 'werkstatt';
      _from.text = 'kalender@werkstatt.local';
      _to.text = '${kWerkstattUser.toLowerCase()}@example.org';
      _s.enabled = true;
    });
  }

  @override
  void dispose() {
    _persist();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cals = widget.state.calendars;
    return Scaffold(
      appBar: AppBar(title: const Text('E-Mail-Benachrichtigungen')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('E-Mails verschicken'),
          subtitle: const Text('Für Erinnerungen mit „Mail“ – direkt von diesem Handy'),
          value: _s.enabled,
          onChanged: (v) => setState(() => _s.enabled = v),
        ),
        Text('Mails gehen nur raus, wenn das Handy an und online ist; sie können '
            'bis zu 15 Minuten früher ankommen. Aktiviere das nur auf einem deiner Geräte.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        if (kWerkstatt)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.science_outlined),
              label: const Text('Werkstatt-Postausgang verwenden'),
              onPressed: _useWerkstatt,
            ),
          ),
        const SizedBox(height: 12),
        TextField(controller: _to, keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Empfänger', hintText: 'du@example.org')),
        const SizedBox(height: 20),
        Text('SMTP-Server', style: theme.textTheme.titleSmall),
        Row(children: [
          Expanded(flex: 3, child: TextField(controller: _host,
              decoration: const InputDecoration(labelText: 'Server', hintText: 'smtp.web.de'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: _port, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'))),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('SSL/TLS direkt (Port 465)'),
          subtitle: const Text('Aus = STARTTLS (Port 587)'),
          value: _s.ssl,
          onChanged: (v) => setState(() {
            _s.ssl = v;
            _port.text = v ? '465' : '587';
          }),
        ),
        TextField(controller: _user, decoration: const InputDecoration(labelText: 'Benutzername')),
        TextField(controller: _pass, obscureText: true,
            decoration: const InputDecoration(labelText: 'Passwort / App-Passwort',
                helperText: 'Wird im Android-Keystore gespeichert')),
        TextField(controller: _from, decoration: const InputDecoration(
            labelText: 'Absender (optional)', hintText: 'Standard: Benutzername')),
        const SizedBox(height: 20),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Tägliche Übersicht per Mail'),
          subtitle: Text('Alle Termine des Tages um ${_s.dailyAgendaHour}:00 Uhr'),
          value: _s.dailyAgenda,
          onChanged: (v) => setState(() => _s.dailyAgenda = v),
        ),
        if (_s.dailyAgenda)
          Slider(
            value: _s.dailyAgendaHour.toDouble(),
            min: 4, max: 12, divisions: 8,
            label: '${_s.dailyAgendaHour}:00',
            onChanged: (v) => setState(() => _s.dailyAgendaHour = v.round()),
          ),
        const SizedBox(height: 12),
        Text('Kalender mit Mail-Benachrichtigungen', style: theme.textTheme.titleSmall),
        for (final c in cals)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: !_s.excludedCalendars.contains(c.key),
            title: Text(c.name),
            secondary: CircleAvatar(radius: 8, backgroundColor: Color(c.color)),
            onChanged: (v) => setState(() {
              if (v == true) {
                _s.excludedCalendars.remove(c.key);
              } else {
                _s.excludedCalendars.add(c.key);
              }
            }),
          ),
        const SizedBox(height: 16),
        Row(children: [
          OutlinedButton.icon(
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_outlined),
            label: const Text('Test-Mail senden'),
            onPressed: _busy ? null : _test,
          ),
          const Spacer(),
          FilledButton(
            onPressed: () async {
              await _persist();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Speichern'),
          ),
        ]),
      ]),
    );
  }
}

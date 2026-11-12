import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/calendar_models.dart';
import 'format.dart';
import 'theme.dart';

/// Kalender-Editor öffnen (neu: [existing] = null).
Future<void> openCalendarEditor(BuildContext context, AppState state, CalendarDef? existing) =>
    Navigator.push(context, MaterialPageRoute(
        fullscreenDialog: true, builder: (_) => CalendarEditor(state: state, existing: existing)));

/// Kalender verwalten: anlegen, umbenennen, Farbe/Symbol, Bedeutungen der Farben,
/// Standard-Erinnerungen, löschen.
class CalendarsScreen extends StatelessWidget {
  const CalendarsScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(title: const Text('Kalender')),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add),
            label: const Text('Kalender'),
            onPressed: () => _edit(context, null),
          ),
          body: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            for (final src in state.sources) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                child: Text('${src.config.label}  ·  ${src.config.repo}',
                    style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
              ),
              for (final c in state.repo.calendarsOf(src.id))
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Color(c.color),
                    child: Text(c.emoji.isEmpty ? c.name.characters.first : c.emoji,
                        style: TextStyle(color: onColor(Color(c.color)))),
                  ),
                  title: Text(c.name),
                  subtitle: Text([
                    c.kind.label,
                    '${state.repo.events.where((e) => e.calendarKey == c.key).length} Termine',
                    if (c.colorLabels.isNotEmpty) '${c.colorLabels.length} Farbbedeutungen',
                    if (c.defaultReminders.isNotEmpty)
                      'Erinnerung: ${reminderLabel(c.defaultReminders.first, allDay: c.kind == CalendarKind.birthdays)}',
                  ].join(' · ')),
                  trailing: Switch(value: state.isVisible(c), onChanged: (_) => state.toggleCalendar(c)),
                  onTap: () => _edit(context, c),
                ),
            ],
          ]),
        );
      },
    );
  }

  Future<void> _edit(BuildContext context, CalendarDef? existing) =>
      openCalendarEditor(context, state, existing);
}

class _LabelRow {
  _LabelRow(this.color, String text) : text = TextEditingController(text: text);
  int color;
  final TextEditingController text;
}

class CalendarEditor extends StatefulWidget {
  const CalendarEditor({super.key, required this.state, this.existing});
  final AppState state;
  final CalendarDef? existing;

  @override
  State<CalendarEditor> createState() => _CalendarEditorState();
}

class _CalendarEditorState extends State<CalendarEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _emoji = TextEditingController(text: widget.existing?.emoji ?? '');
  late int _color = widget.existing?.color ?? kCalendarColors[widget.state.calendars.length % kCalendarColors.length];
  late CalendarKind _kind = widget.existing?.kind ?? CalendarKind.standard;
  late String _sourceId = widget.existing?.sourceId ?? widget.state.sources.first.id;
  late List<Reminder> _reminders = List.of(widget.existing?.defaultReminders ?? const []);
  late final List<_LabelRow> _labels = [
    for (final l in widget.existing?.colorLabels ?? const <ColorLabel>[]) _LabelRow(l.color, l.label),
  ];

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    for (final r in _labels) {
      r.text.dispose();
    }
    super.dispose();
  }

  void _addLabel() {
    final used = {_color, for (final r in _labels) r.color};
    final next = kCalendarColors.firstWhere((c) => !used.contains(c), orElse: () => kCalendarColors.first);
    setState(() => _labels.add(_LabelRow(next, '')));
  }

  Future<void> _pickColorFor(_LabelRow row) async {
    final c = await showDialog<int>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Farbe wählen'),
        content: Wrap(spacing: 10, runSpacing: 10, children: [
          for (final c in kCalendarColors)
            GestureDetector(
              onTap: () => Navigator.pop(d, c),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: Color(c),
                child: row.color == c ? const Icon(Icons.check, color: Colors.white) : null,
              ),
            ),
        ]),
      ),
    );
    if (c != null) setState(() => row.color = c);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    final c = widget.existing ??
        CalendarDef(sourceId: _sourceId, name: '', color: _color,
            sortOrder: widget.state.calendars.length);
    c
      ..name = _name.text.trim()
      ..emoji = _emoji.text.trim()
      ..color = _color
      ..kind = _kind
      ..defaultReminders = _reminders
      ..colorLabels = [
        for (final r in _labels)
          if (r.text.text.trim().isNotEmpty)
            ColorLabel(
                color: r.color,
                label: r.text.text.trim(),
                extra: c.colorLabels.where((l) => l.color == r.color).firstOrNull?.extra ??
                    const {}),
      ];
    await widget.state.saveCalendar(c);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final c = widget.existing!;
    final n = widget.state.repo.events.where((e) => e.calendarKey == c.key).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('„${c.name}“ löschen?'),
        content: Text('Der Kalender und seine $n Termine werden für alle gelöscht, '
            'die diese Datenquelle nutzen.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.state.deleteCalendar(c);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allDay = _kind == CalendarKind.birthdays;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Neuer Kalender' : 'Kalender bearbeiten'),
        actions: [
          if (!_isNew) IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('Speichern')),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Row(children: [
          SizedBox(
            width: 70,
            child: TextField(
              controller: _emoji,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24),
              decoration: const InputDecoration(labelText: 'Symbol', hintText: '🙂'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _name,
              autofocus: _isNew,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
          ),
        ]),
        const SizedBox(height: 20),
        Text('Farbe', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final c in kCalendarColors)
            GestureDetector(
              onTap: () => setState(() => _color = c),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: Color(c),
                child: _color == c ? const Icon(Icons.check, color: Colors.white) : null,
              ),
            ),
        ]),
        if (_isNew) ...[
          const SizedBox(height: 20),
          Text('Art', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<CalendarKind>(
            segments: [
              for (final k in CalendarKind.values) ButtonSegment(value: k, label: Text(k.label)),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          if (widget.state.sources.length > 1) ...[
            const SizedBox(height: 20),
            Text('Datenquelle', style: theme.textTheme.titleSmall),
            RadioGroup<String>(
              groupValue: _sourceId,
              onChanged: (v) => setState(() => _sourceId = v ?? _sourceId),
              child: Column(children: [
                for (final s in widget.state.sources)
                  RadioListTile<String>(
                    value: s.id,
                    title: Text(s.config.label),
                    subtitle: Text(s.config.repo),
                  ),
              ]),
            ),
          ],
        ],
        const SizedBox(height: 24),
        Text('Farben & Bedeutungen', style: theme.textTheme.titleSmall),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          child: Text('Termine in diesem Kalender können eine dieser Farben bekommen. '
              'Die Bedeutung sehen alle, die den Kalender nutzen.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        ),
        for (final row in _labels)
          Row(children: [
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _pickColorFor(row),
              child: CircleAvatar(radius: 14, backgroundColor: Color(row.color)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: TextField(
                controller: row.text,
                autofocus: row.text.text.isEmpty,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Bedeutung, z. B. Arzt'),
              ),
            ),
            IconButton(
              tooltip: 'Entfernen',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _labels.remove(row);
                row.text.dispose();
              }),
            ),
          ]),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Farbe mit Bedeutung hinzufügen'),
            onPressed: _addLabel,
          ),
        ),
        const SizedBox(height: 20),
        Text('Standard-Erinnerungen für neue Termine', style: theme.textTheme.titleSmall),
        for (var i = 0; i < _reminders.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_none),
            title: Text(reminderLabel(_reminders[i], allDay: allDay)),
            subtitle: Text([if (_reminders[i].push) 'Push', if (_reminders[i].email) 'E-Mail'].join(' + ')),
            trailing: IconButton(
                icon: const Icon(Icons.close), onPressed: () => setState(() => _reminders.removeAt(i))),
            onTap: () => setState(() => _reminders[i] = _reminders[i].copyWith(email: !_reminders[i].email)),
          ),
        Wrap(spacing: 8, children: [
          for (final m in allDay ? [0, 1440, 10080] : [0, 15, 60, 1440])
            ActionChip(
              label: Text(reminderLabel(Reminder(minutesBefore: m), allDay: allDay)),
              onPressed: () => setState(() {
                if (!_reminders.any((r) => r.minutesBefore == m)) {
                  _reminders = [..._reminders, Reminder(minutesBefore: m)];
                }
              }),
            ),
        ]),
        const SizedBox(height: 8),
        Text('Antippen einer Erinnerung schaltet zusätzlich E-Mail ein/aus.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
      ]),
    );
  }
}

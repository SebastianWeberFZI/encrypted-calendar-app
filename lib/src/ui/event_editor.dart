import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/calendar_models.dart';
import 'calendars_screen.dart';
import 'format.dart';
import 'theme.dart';

/// Öffnet den Editor. [multiDays]: gleicher Termin an mehreren Tagen
/// (Mehrfachauswahl im Monat, z. B. Schichten).
Future<void> openEventEditor(BuildContext context, AppState state,
    {CalendarEvent? event, bool isNew = false, DateTime? initialDay, List<DateTime>? multiDays}) {
  if (state.calendars.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Lege zuerst unter Einstellungen → Kalender einen Kalender an.')));
    return Future.value();
  }
  return Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => EventEditor(
        state: state, event: event, isNew: isNew || event == null,
        initialDay: initialDay, multiDays: multiDays),
  ));
}

class EventEditor extends StatefulWidget {
  const EventEditor({
    super.key,
    required this.state,
    this.event,
    required this.isNew,
    this.initialDay,
    this.multiDays,
  });

  final AppState state;
  final CalendarEvent? event;
  final bool isNew;
  final DateTime? initialDay;
  final List<DateTime>? multiDays;

  @override
  State<EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<EventEditor> {
  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _description;
  late final TextEditingController _birthYear;
  late CalendarDef _cal;
  late bool _allDay;
  late DateTime _start;
  late DateTime _end;
  Recurrence? _recurrence;
  late List<Reminder> _reminders;
  bool _remindersTouched = false;
  int? _color;
  String? _originalSourceId;

  AppState get state => widget.state;
  bool get _isBirthday => _cal.kind == CalendarKind.birthdays;
  bool get _multi => (widget.multiDays?.length ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    final cals = state.calendars;
    if (e != null) {
      _cal = cals.firstWhere((c) => c.key == e.calendarKey, orElse: () => cals.first);
      _title = TextEditingController(text: e.title);
      _location = TextEditingController(text: e.location);
      _description = TextEditingController(text: e.description);
      _birthYear = TextEditingController(text: e.birthYear?.toString() ?? '');
      _allDay = e.allDay;
      _start = e.start;
      _end = e.end;
      _recurrence = e.recurrence;
      _reminders = List.of(e.reminders);
      _remindersTouched = true;
      _color = e.color;
      _originalSourceId = widget.isNew ? null : e.sourceId;
    } else {
      final visible = cals.where((c) => state.isVisible(c) && c.kind == CalendarKind.standard);
      _cal = visible.isNotEmpty ? visible.first : cals.first;
      _title = TextEditingController();
      _location = TextEditingController();
      _description = TextEditingController();
      _birthYear = TextEditingController();
      final day = dateOnly(widget.multiDays?.first ?? widget.initialDay ?? DateTime.now());
      final now = DateTime.now();
      final hour = sameDay(day, now) ? (now.hour + 1).clamp(8, 22) : 10;
      _start = DateTime(day.year, day.month, day.day, hour);
      _end = _start.add(const Duration(hours: 1));
      _allDay = false;
      _reminders = List.of(_cal.defaultReminders);
      _applyCalendarKind();
    }
  }

  void _applyCalendarKind() {
    if (_isBirthday) {
      _allDay = true;
      _start = dateOnly(_start);
      _end = _start;
      _recurrence = const Recurrence(freq: RecurrenceFreq.yearly);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _description.dispose();
    _birthYear.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ Aktionen

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Bitte einen Titel eingeben.')));
      return;
    }
    var start = _allDay ? dateOnly(_start) : _start;
    var end = _allDay ? dateOnly(_end) : _end;
    if (end.isBefore(start)) end = start;
    CalendarEvent build(DateTime s, DateTime en, {String? id}) {
      final e = (widget.event != null && id == null)
          ? widget.event!
          : CalendarEvent(sourceId: _cal.sourceId, calendarId: _cal.id, start: s, end: en);
      return e
        ..sourceId = _cal.sourceId
        ..calendarId = _cal.id
        ..title = title
        ..allDay = _allDay
        ..start = s
        ..end = en
        ..location = _location.text.trim()
        ..description = _description.text.trim()
        ..recurrence = _recurrence
        ..reminders = _reminders
        ..color = _color
        ..birthYear = _isBirthday ? int.tryParse(_birthYear.text.trim()) : null;
    }

    if (_multi) {
      final dur = end.difference(start);
      final list = [
        for (final d in widget.multiDays!)
          build(DateTime(d.year, d.month, d.day, start.hour, start.minute),
              DateTime(d.year, d.month, d.day, start.hour, start.minute).add(dur),
              id: 'new'),
      ];
      await state.saveEvents(list);
    } else {
      final e = build(start, end);
      await state.saveEvent(e, previousSourceId: _originalSourceId);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pickDate(bool isStart) async {
    final current = isStart ? _start : _end;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      final d = DateTime(picked.year, picked.month, picked.day, current.hour, current.minute);
      if (isStart) {
        final dur = _end.difference(_start);
        _start = d;
        _end = d.add(dur);
      } else {
        _end = d.isBefore(_start) ? _start : d;
      }
    });
  }

  Future<void> _pickTime(bool isStart) async {
    final current = isStart ? _start : _end;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (t == null) return;
    setState(() {
      final d = DateTime(current.year, current.month, current.day, t.hour, t.minute);
      if (isStart) {
        final dur = _end.difference(_start);
        _start = d;
        _end = d.add(dur);
      } else {
        _end = d.isBefore(_start) ? _start.add(const Duration(hours: 1)) : d;
      }
    });
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        title: Text(widget.isNew
            ? (_multi ? 'Termin an ${widget.multiDays!.length} Tagen' : 'Neuer Termin')
            : 'Termin bearbeiten'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('Speichern')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
        children: [
          TextField(
            controller: _title,
            autofocus: widget.isNew,
            textCapitalization: TextCapitalization.sentences,
            style: theme.textTheme.headlineSmall,
            decoration: InputDecoration(
              hintText: _isBirthday ? 'Name' : 'Titel',
              border: InputBorder.none,
            ),
          ),
          const SizedBox(height: 4),
          _calendarPicker(theme),
          const Divider(height: 28),
          if (!_isBirthday)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.wb_sunny_outlined),
              title: const Text('Ganztägig'),
              value: _allDay,
              onChanged: (v) => setState(() {
                _allDay = v;
                if (!_remindersTouched) _reminders = List.of(_cal.defaultReminders);
              }),
            ),
          if (_multi)
            _multiDaysInfo(theme)
          else ...[
            _dateTimeRow(theme, 'Beginn', _start, true),
            if (!_isBirthday) _dateTimeRow(theme, 'Ende', _end, false),
          ],
          if (_multi && !_allDay) ...[
            _timeOnlyRow(theme, 'Beginn', _start, true),
            _timeOnlyRow(theme, 'Ende', _end, false),
          ],
          if (_isBirthday)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _birthYear,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.cake_outlined),
                  labelText: 'Geburtsjahr (optional, für das Alter)',
                ),
              ),
            ),
          const Divider(height: 28),
          if (!_isBirthday && !_multi)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.repeat),
              title: Text(_recurrence == null ? 'Wiederholt sich nicht' : recurrenceText(_recurrence!, _start)),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editRecurrence,
            ),
          _remindersSection(theme),
          const Divider(height: 28),
          TextField(
            controller: _location,
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.place_outlined), hintText: 'Ort', border: InputBorder.none),
          ),
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.notes), hintText: 'Notiz', border: InputBorder.none),
          ),
          const Divider(height: 28),
          _colorPicker(theme),
        ],
      ),
    );
  }

  Widget _calendarPicker(ThemeData theme) {
    final cals = state.calendars;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final c in cals)
        ChoiceChip(
          avatar: CircleAvatar(backgroundColor: Color(c.color), radius: 7),
          label: Text('${c.emoji.isEmpty ? '' : '${c.emoji} '}${c.name}'),
          selected: c.key == _cal.key,
          showCheckmark: false,
          onSelected: (_) => setState(() {
            _cal = c;
            _applyCalendarKind();
            if (!_remindersTouched) _reminders = List.of(c.defaultReminders);
          }),
        ),
    ]);
  }

  Widget _dateTimeRow(ThemeData theme, String label, DateTime value, bool isStart) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 56, child: Text(label, style: theme.textTheme.bodyMedium)),
        Expanded(
          child: TextButton(
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            onPressed: () => _pickDate(isStart),
            child: Text(fmtDateLong(value), style: theme.textTheme.bodyLarge),
          ),
        ),
        if (!_allDay)
          TextButton(
            onPressed: () => _pickTime(isStart),
            child: Text(fmtTime(value), style: theme.textTheme.bodyLarge),
          ),
      ]),
    );
  }

  Widget _timeOnlyRow(ThemeData theme, String label, DateTime value, bool isStart) => Row(children: [
        SizedBox(width: 56, child: Text(label)),
        TextButton(onPressed: () => _pickTime(isStart), child: Text('${fmtTime(value)} Uhr')),
      ]);

  Widget _multiDaysInfo(ThemeData theme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Wrap(spacing: 6, runSpacing: 6, children: [
          for (final d in widget.multiDays!)
            Chip(label: Text('${kWeekdaysShort[d.weekday - 1]} ${fmtDateShort(d)}')),
        ]),
      );

  Widget _remindersSection(ThemeData theme) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < _reminders.length; i++)
        Row(children: [
          Icon(Icons.notifications_none, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(child: Text(reminderLabel(_reminders[i], allDay: _allDay))),
          FilterChip(
            label: const Text('Push'),
            selected: _reminders[i].push,
            visualDensity: VisualDensity.compact,
            onSelected: (v) => setState(() {
              _remindersTouched = true;
              _reminders[i] = _reminders[i].copyWith(push: v);
            }),
          ),
          const SizedBox(width: 4),
          FilterChip(
            label: const Text('Mail'),
            selected: _reminders[i].email,
            visualDensity: VisualDensity.compact,
            onSelected: (v) => setState(() {
              _remindersTouched = true;
              _reminders[i] = _reminders[i].copyWith(email: v);
            }),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() {
              _remindersTouched = true;
              _reminders.removeAt(i);
            }),
          ),
        ]),
      TextButton.icon(
        icon: const Icon(Icons.add_alert_outlined),
        label: const Text('Erinnerung hinzufügen'),
        onPressed: _addReminder,
      ),
    ]);
  }

  Future<void> _addReminder() async {
    final presets = _allDay
        ? [0, 1440, 2880, 10080]
        : [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080];
    final m = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final p in presets)
            ListTile(
              title: Text(reminderLabel(Reminder(minutesBefore: p), allDay: _allDay)),
              onTap: () => Navigator.pop(c, p),
            ),
        ]),
      ),
    );
    if (m == null) return;
    setState(() {
      _remindersTouched = true;
      if (!_reminders.any((r) => r.minutesBefore == m)) {
        _reminders.add(Reminder(minutesBefore: m));
        _reminders.sort((a, b) => b.minutesBefore.compareTo(a.minutesBefore));
      }
    });
  }

  Future<void> _editRecurrence() async {
    final r = await showModalBottomSheet<_RecResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => _RecurrenceSheet(initial: _recurrence, start: _start),
    );
    if (r != null) setState(() => _recurrence = r.value);
  }

  Widget _colorPicker(ThemeData theme) {
    final labels = _cal.colorLabels.where((l) => l.label.isNotEmpty).toList();
    final taken = {_cal.color, for (final l in labels) l.color};
    final current = _color ?? _cal.color;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.palette_outlined, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 16),
        Expanded(child: Text('Farbe', style: theme.textTheme.titleSmall)),
        TextButton(
          onPressed: () async {
            await openCalendarEditor(context, state, _cal);
            if (!mounted) return;
            setState(() => _cal = state.calendars.firstWhere((c) => c.key == _cal.key, orElse: () => _cal));
          },
          child: const Text('Bedeutungen bearbeiten'),
        ),
      ]),
      const SizedBox(height: 4),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _MeaningChip(
          color: Color(_cal.color),
          label: _cal.labelFor(_cal.color) ?? 'Kalenderfarbe',
          selected: current == _cal.color,
          onTap: () => setState(() => _color = null),
        ),
        for (final l in labels)
          if (l.color != _cal.color)
            _MeaningChip(
              color: Color(l.color),
              label: l.label,
              selected: current == l.color,
              onTap: () => setState(() => _color = l.color),
            ),
      ]),
      if (labels.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Tipp: Unter „Bedeutungen bearbeiten“ legst du fest, wofür eine Farbe in '
              '„${_cal.name}“ steht – z. B. Blau = Arzt.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        ),
      const SizedBox(height: 12),
      Text('Weitere Farben (ohne Bedeutung)',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final c in kCalendarColors)
          if (!taken.contains(c))
            _ColorDot(color: Color(c), selected: current == c, onTap: () => setState(() => _color = c)),
      ]),
    ]);
  }
}

class _MeaningChip extends StatelessWidget {
  const _MeaningChip({required this.color, required this.label, required this.selected, required this.onTap});
  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ChoiceChip(
        avatar: CircleAvatar(
          backgroundColor: color,
          radius: 9,
          child: selected ? Icon(Icons.check, size: 12, color: onColor(color)) : null,
        ),
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        selectedColor: color.withValues(alpha: 0.18),
        side: BorderSide(color: selected ? color : Theme.of(context).colorScheme.outlineVariant),
        onSelected: (_) => onTap(),
      );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, required this.selected, required this.onTap});
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: selected ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 2.5) : null,
        ),
        child: selected ? Icon(Icons.check, size: 16, color: onColor(color)) : null,
      ),
    );
  }
}

class _RecResult {
  const _RecResult(this.value);
  final Recurrence? value;
}

class _RecurrenceSheet extends StatefulWidget {
  const _RecurrenceSheet({required this.initial, required this.start});
  final Recurrence? initial;
  final DateTime start;

  @override
  State<_RecurrenceSheet> createState() => _RecurrenceSheetState();
}

class _RecurrenceSheetState extends State<_RecurrenceSheet> {
  RecurrenceFreq? _freq;
  int _interval = 1;
  Set<int> _days = {};
  String _endMode = 'never';
  DateTime? _until;
  int _count = 10;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _freq = r?.freq;
    _interval = r?.interval ?? 1;
    _days = {...?r?.byWeekday};
    if (_days.isEmpty) _days = {widget.start.weekday};
    if (r?.until != null) {
      _endMode = 'until';
      _until = r!.until;
    } else if (r?.count != null) {
      _endMode = 'count';
      _count = r!.count!;
    }
  }

  Recurrence? get _value => _freq == null
      ? null
      : Recurrence(
          freq: _freq!,
          interval: _interval,
          byWeekday: _freq == RecurrenceFreq.weekly ? (_days.toList()..sort()) : const [],
          until: _endMode == 'until' ? (_until ?? widget.start.add(const Duration(days: 90))) : null,
          count: _endMode == 'count' ? _count : null,
        );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Wiederholung', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(label: const Text('Keine'), selected: _freq == null, onSelected: (_) => setState(() => _freq = null)),
            for (final f in RecurrenceFreq.values)
              ChoiceChip(label: Text(f.label), selected: _freq == f, onSelected: (_) => setState(() => _freq = f)),
          ]),
          if (_freq != null) ...[
            const SizedBox(height: 16),
            Row(children: [
              const Text('Alle'),
              IconButton(
                  onPressed: _interval > 1 ? () => setState(() => _interval--) : null,
                  icon: const Icon(Icons.remove_circle_outline)),
              Text('$_interval', style: theme.textTheme.titleMedium),
              IconButton(onPressed: () => setState(() => _interval++), icon: const Icon(Icons.add_circle_outline)),
              Text(_interval == 1 ? _freq!.unit : _freq!.unitPlural),
            ]),
            if (_freq == RecurrenceFreq.weekly)
              Wrap(spacing: 6, children: [
                for (var d = 1; d <= 7; d++)
                  FilterChip(
                    label: Text(kWeekdaysShort[d - 1]),
                    selected: _days.contains(d),
                    showCheckmark: false,
                    onSelected: (v) => setState(() {
                      if (v) {
                        _days.add(d);
                      } else if (_days.length > 1) {
                        _days.remove(d);
                      }
                    }),
                  ),
              ]),
            const SizedBox(height: 12),
            Text('Endet', style: theme.textTheme.titleSmall),
            RadioGroup<String>(
              groupValue: _endMode,
              onChanged: (v) => setState(() => _endMode = v ?? 'never'),
              child: Column(children: [
                const RadioListTile(value: 'never', title: Text('Nie'), contentPadding: EdgeInsets.zero),
                RadioListTile(
                  value: 'until',
                  contentPadding: EdgeInsets.zero,
                  title: Text(_until == null ? 'Am Datum …' : 'Am ${fmtDate(_until!)}'),
                  secondary: IconButton(
                    icon: const Icon(Icons.event),
                    onPressed: () async {
                      final d = await showDatePicker(
                          context: context,
                          initialDate: _until ?? widget.start.add(const Duration(days: 90)),
                          firstDate: widget.start,
                          lastDate: DateTime(2100));
                      if (d != null) setState(() { _until = d; _endMode = 'until'; });
                    },
                  ),
                ),
                RadioListTile(
                  value: 'count',
                  contentPadding: EdgeInsets.zero,
                  title: Row(children: [
                    const Text('Nach'),
                    IconButton(
                        onPressed: _count > 1 ? () => setState(() { _count--; _endMode = 'count'; }) : null,
                        icon: const Icon(Icons.remove, size: 18)),
                    Text('$_count'),
                    IconButton(
                        onPressed: () => setState(() { _count++; _endMode = 'count'; }),
                        icon: const Icon(Icons.add, size: 18)),
                    const Text('Terminen'),
                  ]),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
                onPressed: () => Navigator.pop(context, _RecResult(_value)), child: const Text('Übernehmen')),
          ),
        ]),
      ),
    );
  }
}

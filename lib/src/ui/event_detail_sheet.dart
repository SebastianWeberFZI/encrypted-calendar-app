import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../models/calendar_models.dart';
import '../models/occurrences.dart';
import 'event_editor.dart';
import 'format.dart';

Future<void> showEventDetail(BuildContext context, AppState state, Occurrence occ) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => EventDetailSheet(state: state, occ: occ),
  );
}

class EventDetailSheet extends StatelessWidget {
  const EventDetailSheet({super.key, required this.state, required this.occ});
  final AppState state;
  final Occurrence occ;

  @override
  Widget build(BuildContext context) {
    final e = occ.event!;
    final theme = Theme.of(context);
    final color = Color(occ.color);
    final cal = occ.calendar;
    final source = state.repo.source(e.sourceId);
    final when = occ.allDay
        ? (occ.isMultiDay
            ? '${fmtDateLong(occ.startDay)} –\n${fmtDateLong(occ.endDay)}'
            : fmtDateLong(occ.start))
        : occ.isMultiDay
            ? '${fmtDateLong(occ.start)}, ${fmtTime(occ.start)} –\n'
                '${fmtDateLong(occ.end)}, ${fmtTime(occ.end)}'
            : '${fmtDateLong(occ.start)}\n${occurrenceTimeText(occ)} Uhr';

    Widget row(IconData icon, Widget child) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(child: child),
          ]),
        );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 16,
                height: 16,
                margin: const EdgeInsets.only(top: 6, right: 14),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5)),
              ),
              Expanded(
                child: Text('${occ.emoji.isEmpty ? '' : '${occ.emoji} '}${occ.title}',
                    style: theme.textTheme.headlineSmall),
              ),
            ]),
            const SizedBox(height: 8),
            row(Icons.schedule, Text(when, style: theme.textTheme.bodyLarge)),
            if (e.recurrence != null)
              row(Icons.repeat, Text(recurrenceText(e.recurrence!, e.start))),
            if (occ.colorLabel != null)
              row(Icons.palette_outlined, Row(children: [
                Container(width: 12, height: 12, margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                Text(occ.colorLabel!),
              ])),
            if (cal != null)
              row(Icons.calendar_today_outlined,
                  Text('${cal.name}${source != null && state.sources.length > 1 ? '  ·  ${source.config.label}' : ''}')),
            if (e.location.isNotEmpty)
              row(Icons.place_outlined, InkWell(
                onTap: () => _openMap(e.location),
                child: Text(e.location,
                    style: TextStyle(
                        color: theme.colorScheme.primary,
                        decoration: TextDecoration.underline)),
              )),
            if (e.reminders.isNotEmpty)
              row(Icons.notifications_none, Text(e.reminders.map((r) {
                final ch = [if (r.push) 'Push', if (r.email) 'E-Mail'].join(' + ');
                return '${reminderLabel(r, allDay: e.allDay)} ($ch)';
              }).join('\n'))),
            if (e.description.isNotEmpty)
              row(Icons.notes, SelectableText(e.description)),
            if (e.url.isNotEmpty)
              row(Icons.link, InkWell(
                onTap: () => launchUrl(Uri.parse(e.url), mode: LaunchMode.externalApplication),
                child: Text(e.url, style: TextStyle(color: theme.colorScheme.primary)),
              )),
            if (e.updatedBy.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    'Zuletzt geändert von ${e.updatedBy}, ${fmtDate(e.updatedAt)} ${fmtTime(e.updatedAt)}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ),
            const SizedBox(height: 16),
            Row(children: [
              FilledButton.tonalIcon(
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Bearbeiten'),
                onPressed: () {
                  Navigator.pop(context);
                  openEventEditor(context, state, event: e);
                },
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Duplizieren',
                icon: const Icon(Icons.copy_outlined),
                onPressed: () {
                  Navigator.pop(context);
                  final copy = e.copy(id: newId());
                  copy.recurrence = null;
                  copy.start = occ.start;
                  copy.end = occ.end;
                  openEventEditor(context, state, event: copy, isNew: true);
                },
              ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('Löschen'),
                style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                onPressed: () => _delete(context, e),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, CalendarEvent e) async {
    String? choice = 'all';
    if (e.recurrence != null) {
      choice = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Wiederkehrenden Termin löschen'),
          children: [
            SimpleDialogOption(
                onPressed: () => Navigator.pop(c, 'one'),
                child: const Text('Nur diesen Termin')),
            SimpleDialogOption(
                onPressed: () => Navigator.pop(c, 'following'),
                child: const Text('Diesen und alle folgenden')),
            SimpleDialogOption(
                onPressed: () => Navigator.pop(c, 'all'),
                child: const Text('Alle Termine der Serie')),
          ],
        ),
      );
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Termin löschen?'),
          content: Text('„${occ.title}“ wird auf allen Geräten gelöscht.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Löschen')),
          ],
        ),
      );
      if (ok != true) choice = null;
    }
    if (choice == null) return;
    switch (choice) {
      case 'one':
        await state.deleteOccurrence(e, occ.start);
      case 'following':
        await state.endSeriesBefore(e, occ.start);
      default:
        await state.deleteEvent(e);
    }
    if (context.mounted) Navigator.pop(context);
  }

  Future<void> _openMap(String location) async {
    final geo = Uri.parse('geo:0,0?q=${Uri.encodeComponent(location)}');
    try {
      if (await launchUrl(geo, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    try {
      await launchUrl(
          Uri.parse('https://www.openstreetmap.org/search?query=${Uri.encodeComponent(location)}'),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      // Kein Browser verfügbar (z. B. Linux-Vorschau) – ignorieren.
    }
  }
}

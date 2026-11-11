import 'package:flutter/material.dart';

import '../app_state.dart';
import 'calendars_screen.dart';

/// Farblegende: was die Farben in den sichtbaren Kalendern bedeuten.
Future<void> showLegend(BuildContext context, AppState state) => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => _Legend(state: state),
    );

class _Legend extends StatelessWidget {
  const _Legend({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cals = state.calendars.where(state.isVisible).toList();
    Widget dot(int c, {double size = 14}) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle),
        );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Text('Farblegende', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Was die Farben in den angezeigten Kalendern bedeuten.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          for (final c in cals) ...[
            const SizedBox(height: 16),
            Row(children: [
              dot(c.color, size: 16),
              const SizedBox(width: 10),
              Expanded(
                child: Text('${c.emoji.isEmpty ? '' : '${c.emoji} '}${c.name}',
                    style: theme.textTheme.titleSmall),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await openCalendarEditor(context, state, c);
                },
                child: const Text('Bearbeiten'),
              ),
            ]),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Wrap(spacing: 16, runSpacing: 6, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  dot(c.color, size: 10),
                  const SizedBox(width: 6),
                  Text(c.labelFor(c.color) ?? 'Standard', style: theme.textTheme.bodyMedium),
                ]),
                for (final l in c.colorLabels)
                  if (l.color != c.color && l.label.isNotEmpty)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      dot(l.color, size: 10),
                      const SizedBox(width: 6),
                      Text(l.label, style: theme.textTheme.bodyMedium),
                    ]),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

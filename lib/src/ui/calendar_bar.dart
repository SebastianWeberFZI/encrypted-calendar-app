import 'package:flutter/material.dart';

import '../app_state.dart';

/// Leiste mit allen Kalendern: Antippen blendet ein/aus, langes Tippen zeigt
/// nur diesen Kalender. "Alle" blendet alles wieder ein.
class CalendarBar extends StatelessWidget {
  const CalendarBar({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final cals = state.calendars;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          _Chip(
            label: 'Alle',
            color: scheme.primary,
            selected: state.allVisible,
            onTap: state.showAllCalendars,
          ),
          for (final c in cals)
            _Chip(
              label: '${c.emoji.isEmpty ? '' : '${c.emoji} '}${c.name}',
              color: Color(c.color),
              selected: state.isVisible(c),
              onTap: () => state.toggleCalendar(c),
              onLongPress: () {
                state.soloCalendar(c);
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                    content: Text('Nur „${c.name}“ wird angezeigt'),
                    action: SnackBarAction(
                        label: 'Alle zeigen', onPressed: state.showAllCalendars),
                  ));
              },
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: selected ? color.withValues(alpha: 0.14) : Colors.transparent,
        shape: StadiumBorder(
            side: BorderSide(
                color: selected ? color.withValues(alpha: 0.6) : scheme.outlineVariant)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: selected ? color : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 2),
                ),
              ),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? scheme.onSurface : scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}

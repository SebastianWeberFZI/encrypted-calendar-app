import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/calendar_models.dart';
import '../models/occurrences.dart';
import 'calendar_nav.dart';
import 'event_tile.dart';
import 'format.dart';
import 'theme.dart';

/// Fortlaufende Liste aller kommenden Termine (180 Tage), gruppiert nach Tag.
class AgendaView extends StatelessWidget {
  const AgendaView({super.key, required this.state, required this.nav});
  final AppState state;
  final CalendarNav nav;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = dateOnly(DateTime.now());
    final occ = state.occurrences(today, today.add(const Duration(days: 180)));
    final byDay = <DateTime, List<Occurrence>>{};
    for (final o in occ) {
      // mehrtägige nur am ersten sichtbaren Tag
      final d = o.startDay.isBefore(today) ? today : o.startDay;
      byDay.putIfAbsent(d, () => []).add(o);
    }
    byDay.putIfAbsent(today, () => []);
    final days = byDay.keys.toList()..sort();
    if (days.length == 1 && byDay[today]!.isEmpty) {
      return Center(
        child: Text('Keine Termine in den nächsten 6 Monaten.',
            style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    var lastMonth = -1;
    final children = <Widget>[];
    for (final d in days) {
      if (d.month != lastMonth) {
        lastMonth = d.month;
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
          child: Text(fmtMonthYear(d),
              style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
        ));
      }
      final list = byDay[d]!;
      final holiday = list.any((o) => o.holiday);
      final c = d.weekday == 7 || holiday
          ? kSundayColor
          : d.weekday == 6
              ? kSaturdayColor
              : theme.colorScheme.onSurfaceVariant;
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
        child: Text(relativeDay(d).contains(',') ? relativeDay(d) : '${relativeDay(d)} · ${fmtDayHeader(d)}',
            style: theme.textTheme.labelLarge?.copyWith(color: c, fontWeight: FontWeight.w600)),
      ));
      if (list.isEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Text('Heute keine Termine', style: TextStyle(color: theme.colorScheme.outline)),
        ));
      }
      for (final o in list) {
        children.add(EventTile(state: state, occ: o, day: d, dense: true));
      }
    }
    return ListView(padding: const EdgeInsets.only(bottom: 96), children: children);
  }
}

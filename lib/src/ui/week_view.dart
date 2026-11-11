import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/calendar_models.dart';
import '../models/occurrences.dart';
import 'calendar_nav.dart';
import 'event_editor.dart';
import 'event_tile.dart';
import 'format.dart';
import 'theme.dart';

/// Wochenplaner: sieben Tage untereinander, Wischen wechselt die Woche.
class WeekView extends StatefulWidget {
  const WeekView({super.key, required this.state, required this.nav});
  final AppState state;
  final CalendarNav nav;

  @override
  State<WeekView> createState() => _WeekViewState();
}

class _WeekViewState extends State<WeekView> {
  static const _base = 5000;
  late final DateTime _origin = _monday(DateTime.now());
  late final PageController _pc = PageController(initialPage: _pageFor(widget.nav.focused));
  late int _jumpToken = widget.nav.jumpToken;

  static DateTime _monday(DateTime d) {
    final x = dateOnly(d);
    return x.subtract(Duration(days: x.weekday - 1));
  }

  int _pageFor(DateTime d) => _base + _monday(d).difference(_origin).inDays ~/ 7;
  DateTime _weekFor(int p) => DateTime(_origin.year, _origin.month, _origin.day + (p - _base) * 7);

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.nav.jumpToken != _jumpToken) {
      _jumpToken = widget.nav.jumpToken;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pc.hasClients) _pc.jumpToPage(_pageFor(widget.nav.focused));
      });
    }
    return PageView.builder(
      controller: _pc,
      onPageChanged: (p) {
        final w = _weekFor(p);
        final today = dateOnly(DateTime.now());
        final inWeek = !today.isBefore(w) && today.isBefore(w.add(const Duration(days: 7)));
        widget.nav.setFocused(inWeek ? today : w);
      },
      itemBuilder: (context, p) => _WeekPage(weekStart: _weekFor(p), state: widget.state),
    );
  }
}

class _WeekPage extends StatelessWidget {
  const _WeekPage({required this.weekStart, required this.state});
  final DateTime weekStart;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final occ = state.occurrences(weekStart, weekStart.add(const Duration(days: 7)));
    final today = dateOnly(DateTime.now());
    final kw = _isoWeek(weekStart);
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
              'KW $kw · ${fmtDateShort(weekStart)} – ${fmtDateShort(weekStart.add(const Duration(days: 6)))}',
              style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        for (var i = 0; i < 7; i++)
          _DayBlock(
            day: DateTime(weekStart.year, weekStart.month, weekStart.day + i),
            occ: occ.where((o) => o.coversDay(DateTime(weekStart.year, weekStart.month, weekStart.day + i))).toList(),
            isToday: DateTime(weekStart.year, weekStart.month, weekStart.day + i) == today,
            state: state,
          ),
      ],
    );
  }

  static int _isoWeek(DateTime d) {
    final thursday = d.add(Duration(days: 4 - d.weekday));
    final firstThursday = DateTime(thursday.year, 1, 4);
    final fw = firstThursday.subtract(Duration(days: firstThursday.weekday - 1));
    return thursday.difference(fw).inDays ~/ 7 + 1;
  }
}

class _DayBlock extends StatelessWidget {
  const _DayBlock({required this.day, required this.occ, required this.isToday, required this.state});
  final DateTime day;
  final List<Occurrence> occ;
  final bool isToday;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wd = day.weekday;
    final holiday = occ.any((o) => o.holiday);
    final c = wd == 7 || holiday ? kSundayColor : wd == 6 ? kSaturdayColor : theme.colorScheme.onSurface;
    return InkWell(
      onTap: () => openEventEditor(context, state, initialDay: day),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: isToday ? theme.colorScheme.primary.withValues(alpha: 0.07) : theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 52,
            child: Column(children: [
              Text(kWeekdaysShort[wd - 1], style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w600)),
              Container(
                margin: const EdgeInsets.only(top: 2),
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: isToday ? BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle) : null,
                child: Text('${day.day}',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: isToday ? theme.colorScheme.onPrimary : c)),
              ),
            ]),
          ),
          Expanded(
            child: occ.isEmpty
                ? Padding(
                    padding: const EdgeInsets.only(top: 14, left: 4),
                    child: Text('—', style: TextStyle(color: theme.colorScheme.outlineVariant)),
                  )
                : Column(children: [
                    for (final o in occ) EventTile(state: state, occ: o, day: day, dense: true),
                  ]),
          ),
        ]),
      ),
    );
  }
}

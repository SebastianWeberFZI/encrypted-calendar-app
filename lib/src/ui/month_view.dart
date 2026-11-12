import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/calendar_models.dart';
import '../models/holidays.dart';
import '../models/occurrences.dart';
import '../models/week_layout.dart';
import 'calendar_nav.dart';
import 'event_editor.dart';
import 'event_tile.dart';
import 'format.dart';
import 'theme.dart';

/// Monatsansicht nach Vorbild Komorebi: großes Raster mit farbigen
/// Termin-Labels in den Zellen, darunter (einklappbar) die Tagesliste.
class MonthView extends StatefulWidget {
  const MonthView({super.key, required this.state, required this.nav});
  final AppState state;
  final CalendarNav nav;

  @override
  State<MonthView> createState() => _MonthViewState();
}

class _MonthViewState extends State<MonthView> {
  static const _base = 1200;
  final DateTime _origin = DateTime(DateTime.now().year, DateTime.now().month);
  late final PageController _pc =
      PageController(initialPage: _pageFor(widget.nav.focused));
  late int _jumpToken = widget.nav.jumpToken;

  int _pageFor(DateTime d) =>
      _base + (d.year - _origin.year) * 12 + d.month - _origin.month;
  DateTime _monthFor(int page) =>
      DateTime(_origin.year, _origin.month + page - _base);

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _onPage(int p) {
    final m = _monthFor(p);
    final nav = widget.nav;
    if (nav.focused.year == m.year && nav.focused.month == m.month) return;
    final today = dateOnly(DateTime.now());
    final sel = (today.year == m.year && today.month == m.month) ? today : m;
    nav.focused = sel;
    nav.selected = sel;
    nav.setFocused(sel);
  }

  @override
  Widget build(BuildContext context) {
    final nav = widget.nav;
    if (nav.jumpToken != _jumpToken) {
      _jumpToken = nav.jumpToken;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pc.hasClients) {
          final target = _pageFor(nav.focused);
          if ((target - (_pc.page ?? target).round()).abs() > 2) {
            _pc.jumpToPage(target);
          } else {
            _pc.animateToPage(target,
                duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
          }
        }
      });
    }
    final showPanel = nav.panelOpen && nav.selected != null;
    // Die Zeitraum-Anzeige schwebt über dem Raster: Während des Ziehens darf
    // sich das Layout nicht verschieben, sonst passen die Koordinaten nicht mehr.
    return Stack(children: [
      Column(children: [
        const _WeekdayHeader(),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final gridH = showPanel ? c.maxHeight * 0.56 : c.maxHeight;
            return Column(children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                height: gridH,
                child: PageView.builder(
                  controller: _pc,
                  onPageChanged: _onPage,
                  itemBuilder: (context, p) =>
                      MonthGrid(month: _monthFor(p), state: widget.state, nav: nav),
                ),
              ),
              if (showPanel)
                Expanded(child: DayPanel(day: nav.selected!, state: widget.state, nav: nav)),
            ]);
          }),
        ),
      ]),
      if (nav.rangeActive)
        Positioned(left: 0, right: 0, top: 26, child: Center(child: _RangeChip(nav: nav))),
    ]);
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Row(children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Text(kWeekdaysShort[i],
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: i == 6 ? kSundayColor : i == 5 ? kSaturdayColor : muted)),
          ),
      ]),
    );
  }
}

class MonthGrid extends StatelessWidget {
  const MonthGrid({super.key, required this.month, required this.state, required this.nav});
  final DateTime month;
  final AppState state;
  final CalendarNav nav;

  static const numberH = 22.0;
  static const slotH = 16.0;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month, 1);
    final gridStart = first.subtract(Duration(days: first.weekday - 1));
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final weeks = ((first.weekday - 1 + daysInMonth) / 7).ceil();
    final occ = state.occurrences(gridStart, gridStart.add(Duration(days: weeks * 7)));
    final holidays = state.settings.showHolidays
        ? {
            for (final y in {gridStart.year, gridStart.add(Duration(days: weeks * 7)).year})
              ...holidaysFor(y, state.settings.holidayState)
          }
        : <DateTime, String>{};
    return LayoutBuilder(builder: (context, c) {
      final rowH = c.maxHeight / weeks;
      final cellW = c.maxWidth / 7;
      final maxSlots = max(0, ((rowH - numberH - 2) / slotH).floor());
      DateTime dayAt(Offset p) {
        final row = (p.dy / rowH).floor().clamp(0, weeks - 1);
        final col = (p.dx / cellW).floor().clamp(0, 6);
        return DateTime(gridStart.year, gridStart.month, gridStart.day + row * 7 + col);
      }

      // Gedrückt halten = Beginn, ziehen = Ende, loslassen = ein Termin über
      // den ganzen Zeitraum (mehrtägig statt vieler Einzeltermine).
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (d) {
          HapticFeedback.mediumImpact();
          nav.startRange(dayAt(d.localPosition));
        },
        onLongPressMoveUpdate: (d) {
          if (nav.updateRange(dayAt(d.localPosition))) HapticFeedback.selectionClick();
        },
        onLongPressEnd: (_) async {
          final r = nav.finishRange();
          if (r != null) await openEventEditor(context, state, initialRange: r);
        },
        onLongPressCancel: () {
          if (nav.rangeActive) nav.finishRange();
        },
        child: Column(children: [
          for (var w = 0; w < weeks; w++)
            SizedBox(
              height: rowH,
              child: _WeekRow(
                weekStart: DateTime(gridStart.year, gridStart.month, gridStart.day + w * 7),
                month: month,
                occ: occ,
                holidays: holidays,
                cellW: cellW,
                maxSlots: maxSlots,
                state: state,
                nav: nav,
              ),
            ),
        ]),
      );
    });
  }
}

class _WeekRow extends StatelessWidget {
  const _WeekRow({
    required this.weekStart,
    required this.month,
    required this.occ,
    required this.holidays,
    required this.cellW,
    required this.maxSlots,
    required this.state,
    required this.nav,
  });

  final DateTime weekStart;
  final DateTime month;
  final List<Occurrence> occ;
  final Map<DateTime, String> holidays;
  final double cellW;
  final int maxSlots;
  final AppState state;
  final CalendarNav nav;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final layout = layoutWeek(weekStart, occ, maxSlots);
    final today = dateOnly(DateTime.now());
    const nH = MonthGrid.numberH, sH = MonthGrid.slotH;

    return Stack(children: [
      Row(children: [
        for (var i = 0; i < 7; i++)
          _DayCell(
            day: DateTime(weekStart.year, weekStart.month, weekStart.day + i),
            inMonth: DateTime(weekStart.year, weekStart.month, weekStart.day + i).month == month.month,
            isToday: DateTime(weekStart.year, weekStart.month, weekStart.day + i) == today,
            holiday: holidays.containsKey(DateTime(weekStart.year, weekStart.month, weekStart.day + i)),
            col: i,
            state: state,
            nav: nav,
          ),
      ]),
      for (final it in layout.visible)
        Positioned(
          left: it.startCol * cellW + 2,
          width: it.span * cellW - 4,
          top: nH + it.slot * sH,
          height: sH - 2,
          child: IgnorePointer(child: _Label(item: it)),
        ),
      for (var col = 0; col < 7; col++)
        if (layout.hiddenPerCol[col] > 0 && maxSlots > 0)
          Positioned(
            left: col * cellW + 2,
            width: cellW - 4,
            top: nH + (maxSlots - 1) * sH,
            height: sH - 2,
            child: IgnorePointer(
              child: Text('+${layout.hiddenPerCol[col]}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant)),
            ),
          ),
    ]);
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.holiday,
    required this.col,
    required this.state,
    required this.nav,
  });

  final DateTime day;
  final bool inMonth;
  final bool isToday;
  final bool holiday;
  final int col;
  final AppState state;
  final CalendarNav nav;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = nav.selected == day && !nav.rangeActive;
    final inRange = nav.inRange(day);
    var numColor = col == 6 || holiday
        ? kSundayColor
        : col == 5
            ? kSaturdayColor
            : scheme.onSurface;
    if (!inMonth) numColor = numColor.withValues(alpha: 0.35);
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => nav.select(day),
        onDoubleTap: () => openEventEditor(context, state, initialDay: day),
        child: Container(
          decoration: BoxDecoration(
            color: inRange
                ? scheme.primary.withValues(alpha: 0.2)
                : selected
                    ? scheme.primary.withValues(alpha: 0.07)
                    : inMonth
                        ? null
                        : scheme.surfaceContainerHighest.withValues(alpha: 0.25),
            border: Border(
              top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6), width: 0.5),
              left: col == 0
                  ? BorderSide.none
                  : BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35), width: 0.5),
            ),
          ),
          alignment: Alignment.topCenter,
          padding: const EdgeInsets.only(top: 2),
          child: Container(
            width: 20,
            height: 18,
            alignment: Alignment.center,
            decoration: isToday
                ? BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(9))
                : selected
                    ? BoxDecoration(
                        border: Border.all(color: scheme.primary, width: 1.2),
                        borderRadius: BorderRadius.circular(9))
                    : null,
            child: Text('${day.day}',
                style: TextStyle(
                    fontSize: 12,
                    height: 1.0,
                    fontWeight: isToday || selected ? FontWeight.w700 : FontWeight.w500,
                    color: isToday ? scheme.onPrimary : numColor)),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.item});
  final WeekItem item;

  @override
  Widget build(BuildContext context) {
    final o = item.occ;
    final c = Color(o.color);
    final Color bg, fg;
    if (o.holiday) {
      bg = kSundayColor.withValues(alpha: 0.08);
      fg = kSundayColor;
    } else if (o.allDay || o.isMultiDay) {
      bg = c;
      fg = onColor(c);
    } else {
      bg = c.withValues(alpha: 0.16);
      fg = HSLColor.fromColor(c).withLightness(
              (HSLColor.fromColor(c).lightness * 0.72).clamp(0.0, 1.0)).toColor();
    }
    const r = Radius.circular(4);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.horizontal(
            left: item.continuesLeft ? Radius.zero : r,
            right: item.continuesRight ? Radius.zero : r),
      ),
      child: Text(
        o.title, // Emojis nur in Listen – im Raster zählt jeder Pixel
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: TextStyle(fontSize: 10.5, height: 1.15, color: fg, fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// Tagesliste unter dem Monatsraster.
class DayPanel extends StatelessWidget {
  const DayPanel({super.key, required this.day, required this.state, required this.nav});
  final DateTime day;
  final AppState state;
  final CalendarNav nav;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final occ = state.occurrences(day, day.add(const Duration(days: 1)));
    final rel = relativeDay(day);
    return GestureDetector(
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 250) nav.closePanel();
      },
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(0, -2)),
          ],
        ),
        child: Column(children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 8, 4),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(rel.contains(',') ? rel : '$rel · ${fmtDayHeader(day)}',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                ]),
              ),
              IconButton(
                tooltip: 'Neuer Termin',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => openEventEditor(context, state, initialDay: day),
              ),
              IconButton(
                tooltip: 'Einklappen',
                icon: const Icon(Icons.expand_more),
                onPressed: nav.closePanel,
              ),
            ]),
          ),
          Expanded(
            child: occ.isEmpty
                ? Center(
                    child: Text('Keine Termine.\nDoppelt tippen legt einen an, gedrückt halten\nund ziehen einen mehrtägigen.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 80),
                    children: [for (final o in occ) EventTile(state: state, occ: o, day: day)],
                  ),
          ),
        ]),
      ),
    );
  }
}

/// Schwebende Anzeige des Zeitraums während des Ziehens.
class _RangeChip extends StatelessWidget {
  const _RangeChip({required this.nav});
  final CalendarNav nav;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = nav.range!;
    final days = r.$2.difference(r.$1).inDays + 1;
    final text = days == 1
        ? fmtDateShort(r.$1)
        : r.$1.month == r.$2.month && r.$1.year == r.$2.year
            ? '${r.$1.day}.–${fmtDateShort(r.$2)}'
            : '${fmtDateShort(r.$1)} – ${fmtDateShort(r.$2)}';
    return IgnorePointer(
      child: Material(
        elevation: 4,
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text('$text · $days Tag${days == 1 ? '' : 'e'}',
              style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onPrimary)),
        ),
      ),
    );
  }
}

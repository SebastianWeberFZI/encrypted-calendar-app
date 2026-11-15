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
/// Die Wochen laufen als durchgehende Liste: frei nach oben und unten scrollen,
/// der Monat in der Mitte des Rasters ist hervorgehoben und steht im Titel.
class MonthView extends StatefulWidget {
  const MonthView({super.key, required this.state, required this.nav});
  final AppState state;
  final CalendarNav nav;

  @override
  State<MonthView> createState() => _MonthViewState();
}

class _MonthViewState extends State<MonthView> {
  /// Wochen vor und nach heute (gut 100 Jahre).
  static const _base = 5300;

  /// So viele Wochen passen bei eingeklappter Tagesliste ins Raster.
  static const _rows = 6;

  final DateTime _origin = _mondayOf(dateOnly(DateTime.now()));
  late int _jumpToken = widget.nav.jumpToken;
  ScrollController? _sc;
  double _rowH = 0;
  double _viewH = 0;

  /// Oberkante des Rasters in Wochen (bleibt beim Drehen des Handys erhalten).
  double _topWeek = 0;
  DateTime? _shownSelected;
  bool _shownPanel = false;
  final Map<String, Map<DateTime, String>> _holidays = {};

  static DateTime _mondayOf(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

  static int _daysBetween(DateTime a, DateTime b) =>
      DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  DateTime _weekStart(int i) => DateTime(_origin.year, _origin.month, _origin.day + (i - _base) * 7);
  int _indexOf(DateTime d) => _base + (_daysBetween(_origin, _mondayOf(d)) / 7).round();

  /// Oberkante (in Wochen) für ein Datum: sein Monat beginnt oben, der Tag
  /// selbst bleibt aber sichtbar, auch wenn die Tagesliste offen ist.
  double _topFor(DateTime d, double viewH) {
    var top = _indexOf(DateTime(d.year, d.month, 1)).toDouble();
    final visible = viewH / _rowH;
    final row = _indexOf(d);
    if (row + 1 > top + visible) top = row + 1 - visible;
    return top;
  }

  Map<DateTime, String> _holidaysFor(int year) {
    final region = widget.state.settings.holidayState;
    return _holidays.putIfAbsent('$region|$year', () => holidaysFor(year, region));
  }

  @override
  void dispose() {
    _sc?.dispose();
    super.dispose();
  }

  void _onScroll() {
    final sc = _sc!;
    if (_rowH <= 0 || !sc.hasClients) return;
    _topWeek = sc.offset / _rowH;
    // Der Monat in der Mitte des sichtbaren Rasters gilt als aktueller Monat.
    final mid = ((sc.offset + sc.position.viewportDimension / 2) / _rowH).floor();
    final thu = _weekStart(mid).add(const Duration(days: 3));
    final nav = widget.nav;
    if (nav.focused.year == thu.year && nav.focused.month == thu.month) return;
    final today = dateOnly(DateTime.now());
    nav.setFocused(today.year == thu.year && today.month == thu.month ? today : DateTime(thu.year, thu.month));
  }

  void _scrollTo(double top, {bool animate = true}) {
    final sc = _sc;
    if (sc == null || !sc.hasClients) return;
    final target = top * _rowH;
    if (!animate || (target - sc.offset).abs() > _rowH * 12) {
      sc.jumpTo(target);
    } else {
      sc.animateTo(target, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    }
  }

  /// Ausgewählten Tag sichtbar halten (z. B. wenn sich die Tagesliste öffnet).
  void _ensureVisible(DateTime day, double viewH) {
    final row = _indexOf(day).toDouble();
    final visible = viewH / _rowH;
    if (row < _topWeek) {
      _scrollTo(row);
    } else if (row + 1 > _topWeek + visible) {
      _scrollTo(row + 1 - visible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = widget.nav;
    final showPanel = nav.panelOpen && nav.selected != null;
    final focusedMonth = DateTime(nav.focused.year, nav.focused.month);
    // Die Zeitraum-Anzeige schwebt über dem Raster: Während des Ziehens darf
    // sich das Layout nicht verschieben, sonst passen die Koordinaten nicht mehr.
    return Stack(children: [
      Column(children: [
        const _WeekdayHeader(),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final rowH = c.maxHeight / _rows;
            final gridH = showPanel ? c.maxHeight * 0.56 : c.maxHeight;
            if (_sc == null) {
              _rowH = rowH;
              _topWeek = _topFor(nav.focused, gridH);
              _sc = ScrollController(initialScrollOffset: _topWeek * rowH)..addListener(_onScroll);
              _shownSelected = nav.selected;
              _shownPanel = showPanel;
            } else if (rowH != _rowH) {
              // Andere Höhe (Drehen, Kalenderleiste): dieselbe Woche bleibt oben.
              _rowH = rowH;
              final top = _topWeek;
              WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(top, animate: false));
            }
            _viewH = gridH;
            if (nav.jumpToken != _jumpToken) {
              _jumpToken = nav.jumpToken;
              final target = nav.focused;
              WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(_topFor(target, _viewH)));
            } else if (showPanel && (nav.selected != _shownSelected || !_shownPanel)) {
              final day = nav.selected!;
              // erst nach dem Aufklappen der Tagesliste nachsehen
              Future.delayed(const Duration(milliseconds: 240), () {
                if (mounted) _ensureVisible(day, _viewH);
              });
            }
            _shownSelected = nav.selected;
            _shownPanel = showPanel;
            final cellW = c.maxWidth / 7;
            final maxSlots = max(0, ((rowH - _numberH - 2) / _slotH).floor());
            final showHolidays = widget.state.settings.showHolidays;

            DateTime dayAt(Offset p) {
              final row = ((_sc!.offset + p.dy) / rowH).floor();
              final col = (p.dx / cellW).floor().clamp(0, 6);
              final ws = _weekStart(row);
              return DateTime(ws.year, ws.month, ws.day + col);
            }

            return Column(children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                height: gridH,
                // Gedrückt halten = Beginn, ziehen = Ende, loslassen = ein Termin
                // über den ganzen Zeitraum (mehrtägig statt vieler Einzeltermine).
                child: GestureDetector(
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
                    if (r != null) await openEventEditor(context, widget.state, initialRange: r);
                  },
                  onLongPressCancel: () {
                    if (nav.rangeActive) nav.finishRange();
                  },
                  child: ListView.builder(
                    controller: _sc,
                    itemExtent: rowH,
                    itemCount: 2 * _base,
                    itemBuilder: (context, i) {
                      final ws = _weekStart(i);
                      final we = ws.add(const Duration(days: 7));
                      return _WeekRow(
                        weekStart: ws,
                        month: focusedMonth,
                        occ: widget.state.occurrences(ws, we),
                        holidays: showHolidays
                            ? {..._holidaysFor(ws.year), if (we.year != ws.year) ..._holidaysFor(we.year)}
                            : const {},
                        cellW: cellW,
                        maxSlots: maxSlots,
                        state: widget.state,
                        nav: nav,
                      );
                    },
                  ),
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

const _numberH = 22.0;
const _slotH = 16.0;

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
    const nH = _numberH, sH = _slotH;

    return Stack(children: [
      Row(children: [
        for (var i = 0; i < 7; i++)
          _DayCell(
            day: DateTime(weekStart.year, weekStart.month, weekStart.day + i),
            inMonth: DateTime(weekStart.year, weekStart.month, weekStart.day + i).month == month.month &&
                DateTime(weekStart.year, weekStart.month, weekStart.day + i).year == month.year,
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
            constraints: const BoxConstraints(minWidth: 20),
            padding: const EdgeInsets.symmetric(horizontal: 3),
            height: 18,
            alignment: Alignment.center,
            decoration: isToday
                ? BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(9))
                : selected
                    ? BoxDecoration(
                        border: Border.all(color: scheme.primary, width: 1.2),
                        borderRadius: BorderRadius.circular(9))
                    : null,
            // Am 1. steht der Monat dabei – beim Scrollen die Orientierung.
            child: Text(day.day == 1 ? '1. ${kMonthsShort[day.month - 1]}' : '${day.day}',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.0,
                    fontWeight: isToday || selected || day.day == 1 ? FontWeight.w700 : FontWeight.w500,
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

import 'calendar_models.dart';
import 'occurrences.dart';

/// Ein Eintrag in einer Wochenzeile des Monatsrasters.
class WeekItem {
  WeekItem(this.occ, this.startCol, this.endCol, this.slot);
  final Occurrence occ;
  final int startCol; // 0 = Montag
  final int endCol; // inklusive
  final int slot; // Zeile innerhalb der Zelle
  int get span => endCol - startCol + 1;

  /// Balken beginnt/endet außerhalb dieser Woche.
  bool continuesLeft = false;
  bool continuesRight = false;
}

class WeekLayout {
  WeekLayout(this.visible, this.hiddenPerCol);
  final List<WeekItem> visible;

  /// Anzahl ausgeblendeter Einträge je Spalte ("+N").
  final List<int> hiddenPerCol;
}

/// Verteilt die Vorkommen einer Woche auf Zeilen (Slots). Mehrtägige Einträge
/// belegen denselben Slot über alle ihre Tage. Passen nicht alle Einträge in
/// [maxSlots], wird in betroffenen Spalten der letzte Slot für "+N" reserviert.
WeekLayout layoutWeek(
    DateTime weekStart, List<Occurrence> occs, int maxSlots) {
  final ws = dateOnly(weekStart);
  final we = ws.add(const Duration(days: 6));
  final relevant = occs
      .where((o) => !o.endDay.isBefore(ws) && !o.startDay.isAfter(we))
      .toList()
    ..sort((a, b) {
      // Feiertage zuerst, dann längere Balken, dann chronologisch
      int rank(Occurrence o) => o.holiday ? 0 : o.isMultiDay ? 1 : o.allDay ? 2 : 3;
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      if (a.isMultiDay && b.isMultiDay) {
        final s = a.startDay.compareTo(b.startDay);
        if (s != 0) return s;
        return b.endDay.compareTo(a.endDay);
      }
      return compareOccurrences(a, b);
    });

  final used = List.generate(7, (_) => <int>{});
  final all = <WeekItem>[];
  for (final o in relevant) {
    final sc = o.startDay.isBefore(ws) ? 0 : o.startDay.difference(ws).inDays;
    final ec = o.endDay.isAfter(we) ? 6 : o.endDay.difference(ws).inDays;
    var slot = 0;
    while (true) {
      var free = true;
      for (var c = sc; c <= ec; c++) {
        if (used[c].contains(slot)) {
          free = false;
          break;
        }
      }
      if (free) break;
      slot++;
    }
    for (var c = sc; c <= ec; c++) {
      used[c].add(slot);
    }
    all.add(WeekItem(o, sc, ec, slot)
      ..continuesLeft = o.startDay.isBefore(ws)
      ..continuesRight = o.endDay.isAfter(we));
  }

  // Spalten mit Überlauf: dort gehört der letzte Slot dem "+N".
  final overflow = List.generate(7, (c) => used[c].any((s) => s >= maxSlots));
  final visible = <WeekItem>[];
  final hidden = List.filled(7, 0);
  for (final it in all) {
    if (it.slot >= maxSlots) {
      for (var c = it.startCol; c <= it.endCol; c++) {
        hidden[c]++;
      }
      continue;
    }
    if (it.slot < maxSlots - 1) {
      visible.add(it);
      continue;
    }
    // Letzter Slot: nur an Tagen mit Überlauf ausblenden, sonst bleibt der
    // Balken sichtbar (ein mehrtägiger Termin wird dabei unterbrochen).
    var c = it.startCol;
    while (c <= it.endCol) {
      if (overflow[c]) {
        hidden[c]++;
        c++;
        continue;
      }
      final from = c;
      while (c < it.endCol && !overflow[c + 1]) {
        c++;
      }
      visible.add(from == it.startCol && c == it.endCol
          ? it
          : (WeekItem(it.occ, from, c, it.slot)
            ..continuesLeft = from > it.startCol || it.continuesLeft
            ..continuesRight = c < it.endCol || it.continuesRight));
      c++;
    }
  }
  return WeekLayout(visible, hidden);
}

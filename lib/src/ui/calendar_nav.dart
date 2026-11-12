import 'package:flutter/foundation.dart';

import '../models/calendar_models.dart';

/// Gemeinsamer Navigationszustand der Ansichten (Monat/Woche/Liste).
class CalendarNav extends ChangeNotifier {
  DateTime focused = dateOnly(DateTime.now());
  DateTime? selected = dateOnly(DateTime.now());
  bool panelOpen = true;

  /// Zeitraum-Auswahl im Monat: gedrückt halten = Beginn, ziehen = Ende.
  DateTime? rangeAnchor;
  DateTime? rangeEnd;
  bool get rangeActive => rangeAnchor != null;

  /// Beginn und Ende des gewählten Zeitraums (sortiert, Ende inklusive).
  (DateTime, DateTime)? get range {
    final a = rangeAnchor, b = rangeEnd ?? rangeAnchor;
    if (a == null || b == null) return null;
    return a.isAfter(b) ? (b, a) : (a, b);
  }

  bool inRange(DateTime day) {
    final r = range;
    if (r == null) return false;
    return !day.isBefore(r.$1) && !day.isAfter(r.$2);
  }

  /// Zähler, damit Ansichten auf "springe zu Datum" reagieren können.
  int jumpToken = 0;

  void select(DateTime day) {
    final d = dateOnly(day);
    if (selected == d) {
      panelOpen = !panelOpen;
    } else {
      selected = d;
      panelOpen = true;
    }
    focused = d;
    notifyListeners();
  }

  void setFocused(DateTime d) {
    focused = dateOnly(d);
    notifyListeners();
  }

  void jumpTo(DateTime d) {
    focused = dateOnly(d);
    selected = dateOnly(d);
    panelOpen = true;
    jumpToken++;
    notifyListeners();
  }

  void closePanel() {
    panelOpen = false;
    notifyListeners();
  }

  void startRange(DateTime day) {
    rangeAnchor = dateOnly(day);
    rangeEnd = rangeAnchor;
    notifyListeners();
  }

  /// Liefert true, wenn sich das Ende geändert hat.
  bool updateRange(DateTime day) {
    final d = dateOnly(day);
    if (rangeAnchor == null || rangeEnd == d) return false;
    rangeEnd = d;
    notifyListeners();
    return true;
  }

  (DateTime, DateTime)? finishRange() {
    final r = range;
    rangeAnchor = null;
    rangeEnd = null;
    notifyListeners();
    return r;
  }
}

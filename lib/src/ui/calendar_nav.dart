import 'package:flutter/foundation.dart';

import '../models/calendar_models.dart';

/// Gemeinsamer Navigationszustand der Ansichten (Monat/Woche/Liste).
class CalendarNav extends ChangeNotifier {
  DateTime focused = dateOnly(DateTime.now());
  DateTime? selected = dateOnly(DateTime.now());
  bool panelOpen = true;

  /// Mehrfachauswahl von Tagen (langes Tippen im Monat).
  final Set<DateTime> multi = {};
  bool get multiSelect => multi.isNotEmpty;

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

  void toggleMulti(DateTime day) {
    final d = dateOnly(day);
    if (!multi.remove(d)) multi.add(d);
    notifyListeners();
  }

  void clearMulti() {
    multi.clear();
    notifyListeners();
  }
}

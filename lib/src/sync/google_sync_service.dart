import 'dart:io';

import 'package:system_calendar/system_calendar.dart';

import '../calendar_repository.dart';
import '../models/calendar_models.dart';
import '../settings.dart';
import 'device_calendar.dart';
import 'google_sync.dart';

/// Die Repo-Daten der App als Gegenstück für den Abgleich.
class RepoCalendarData implements AppCalendarData {
  RepoCalendarData(this.repo);
  final CalendarRepository repo;

  @override
  List<CalendarDef> get calendars => repo.calendars;
  @override
  List<CalendarEvent> get events => repo.events;
  @override
  Future<void> saveEvent(CalendarEvent e) => repo.saveEvent(e);
  @override
  Future<void> deleteEvent(CalendarEvent e) => repo.deleteEvent(e);
}

/// Bindet den Abgleich mit dem Handy-Kalender (Google) an App und
/// Hintergrund-Worker an. Läuft nur, wenn auf diesem Handy eingeschaltet.
class GoogleSyncService {
  static const api = AndroidCalendarApi();

  static bool get supported => SystemCalendar.supported;

  static File stateFile(String baseDir) => File('$baseDir/google_sync/state.json');

  static GoogleSyncConfig configFrom(LocalSettings s) => GoogleSyncConfig(
        importCalendarKey: s.googleImportCalendar,
        importFrom: s.googleImportFrom,
        defaultTarget: s.googleDefaultTarget < 0 ? null : s.googleDefaultTarget,
        targets: {for (final e in s.googleTargets.entries) e.key: e.value < 0 ? null : e.value},
      );

  /// Ein Durchlauf; null, wenn ausgeschaltet oder nicht möglich.
  /// Ergebnis und Fehler stehen danach auch in den Einstellungen.
  static Future<GoogleSyncResult?> run(CalendarRepository repo, LocalSettings settings) async {
    if (!supported || !settings.googleSync) return null;
    try {
      final r = await GoogleSync(
        data: RepoCalendarData(repo),
        api: api,
        config: configFrom(settings),
        stateFile: stateFile(repo.baseDir),
        me: settings.userName,
      ).run();
      settings.googleLastRun = DateTime.now();
      if (r.warnings.isNotEmpty) {
        settings.googleStatus = r.warnings.join('\n');
        settings.googleStatusIsError = true;
      } else {
        settings.googleStatus = r.summary;
        settings.googleStatusIsError = false;
      }
      return r;
    } catch (e) {
      settings.googleStatus = e is GoogleSyncException ? e.message : 'Abgleich fehlgeschlagen: $e';
      settings.googleStatusIsError = true;
      return null;
    }
  }

  /// Legt den App-Kalender für die übernommenen Termine an (z. B. „Sarah – Google“).
  static CalendarDef newImportCalendar(String sourceId, String owner) => CalendarDef(
        sourceId: sourceId,
        name: '${owner.isEmpty ? 'Mein' : owner} – Google',
        color: 0xFF4285F4,
        emoji: '',
        sync: {'type': 'device', 'owner': owner, 'label': 'Google'},
      );

  /// Merkt sich das Löschen eines übernommenen Termins durch die Besitzerin.
  static Future<void> noteDeleted(CalendarRepository repo, LocalSettings settings, CalendarEvent e) async {
    if (!settings.googleSync || e.google == null || e.calendarKey != settings.googleImportCalendar) return;
    await GoogleSyncState.addTombstone(stateFile(repo.baseDir), e.id);
  }

  /// Abgleich beenden; auf Wunsch die Kopien der App-Termine im Handy-Kalender entfernen.
  static Future<int> stop(CalendarRepository repo, LocalSettings settings, {required bool removeCopies}) async {
    settings.googleSync = false;
    final f = stateFile(repo.baseDir);
    var removed = 0;
    if (removeCopies && supported && await api.hasPermission()) {
      final state = await GoogleSyncState.load(f);
      for (final p in state.out.values) {
        try {
          await api.delete(p.row);
          removed++;
        } catch (_) {}
      }
    }
    if (await f.exists()) await f.delete();
    settings.googleStatus = '';
    settings.googleStatusIsError = false;
    settings.googleLastRun = null;
    return removed;
  }
}

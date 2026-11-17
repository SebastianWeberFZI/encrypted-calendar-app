import 'dart:io';

import 'package:system_calendar/system_calendar.dart';

import '../calendar_repository.dart';
import '../core/app_log.dart';
import '../models/calendar_models.dart';
import '../settings.dart';
import 'device_calendar.dart';
import 'google_sync.dart';

/// Google-Termin einer anderen Person (ihre Erinnerungen gehören ihr)?
bool isOthersGoogleEvent(CalendarEvent e, CalendarDef? cal, String me) {
  final owner = e.googleOwner;
  if (owner.isNotEmpty) return owner != me;
  return cal != null && cal.isSynced && cal.syncOwner.isNotEmpty && cal.syncOwner != me;
}

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

  /// [pastDays] statt des eingestellten Zeitraums (-1 = alles), z. B. für den Probelauf.
  static GoogleSyncConfig configFrom(LocalSettings s, {int? pastDays}) => GoogleSyncConfig(
        importCalendarKey: s.googleImportCalendar,
        importFrom: s.googleImportFrom,
        defaultTarget: s.googleDefaultTarget < 0 ? null : s.googleDefaultTarget,
        targets: {for (final e in s.googleTargets.entries) e.key: e.value < 0 ? null : e.value},
        pastDays: (pastDays ?? s.googlePastDays) < 0 ? null : (pastDays ?? s.googlePastDays),
        reminders: s.googleReminders,
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
      final now = DateTime.now();
      settings.googleLastRun = now;
      if (r.log.isNotEmpty || r.warnings.isNotEmpty) {
        AppLog.info('google', r.summary);
        for (final line in r.log) {
          AppLog.info('google', line);
        }
        for (final w in r.warnings) {
          AppLog.warn('google', w);
        }
      }
      if (r.log.isNotEmpty) {
        String two(int v) => v.toString().padLeft(2, '0');
        settings.googleLog = [
          '— ${now.day}.${now.month}. ${two(now.hour)}:${two(now.minute)} Uhr',
          ...r.log,
          ...settings.googleLog,
        ].take(150).toList();
      }
      if (r.warnings.isNotEmpty) {
        settings.googleStatus = r.warnings.join('\n');
        settings.googleStatusIsError = true;
      } else {
        settings.googleStatus = r.summary;
        settings.googleStatusIsError = false;
      }
      return r;
    } catch (e, st) {
      AppLog.error('google', 'Abgleich fehlgeschlagen', e, e is Error ? st : null);
      settings.googleStatus = e is GoogleSyncException ? e.message : 'Abgleich fehlgeschlagen: $e';
      settings.googleStatusIsError = true;
      return null;
    }
  }

  /// Probelauf: was ein Abgleich mit [config] ändern würde – ändert nichts.
  static Future<GoogleSyncResult> preview(
          CalendarRepository repo, LocalSettings settings, GoogleSyncConfig config,
          {List<CalendarDef> extra = const []}) =>
      GoogleSync(
        data: RepoCalendarData(repo),
        api: api,
        config: config,
        stateFile: stateFile(repo.baseDir),
        me: settings.userName,
        dryRun: true,
        extraCalendars: extra,
      ).run();

  /// App-Termine, deren Erinnerungen auf diesem Handy der Google-Kalender
  /// meldet (abgeglichen mit Erinnerungen) – die App meldet sie nicht doppelt.
  static Future<Set<String>> alertedByGoogle(CalendarRepository repo, LocalSettings settings) async {
    if (!supported || !settings.googleSync || !settings.googleReminders) return const {};
    final st = await GoogleSyncState.load(stateFile(repo.baseDir));
    return {...st.out.keys, for (final p in st.inn.values) p.app, for (final p in st.inst.values) p.app};
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
    if (!settings.googleSync || e.google == null) return;
    final owner = e.googleOwner;
    if (owner.isNotEmpty ? owner != settings.userName : e.calendarKey != settings.googleImportCalendar) return;
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
    settings.googleLog = [];
    return removed;
  }
}

import 'dart:convert';
import 'dart:io';

import '../models/calendar_models.dart';
import 'device_calendar.dart';
import 'event_mapping.dart';

/// Paket-Kennung, mit der Kopien der App im Handy-Kalender markiert werden.
const kAppPackage = 'de.sweber.encrypted_calendar_app';
const _uriPrefix = 'kalender://event/';

/// Was der Abgleich von der App braucht (im Test ein Speicher im RAM).
abstract class AppCalendarData {
  List<CalendarDef> get calendars;
  List<CalendarEvent> get events;

  /// Speichert (setzt „geändert von/am“).
  Future<void> saveEvent(CalendarEvent e);
  Future<void> deleteEvent(CalendarEvent e);
}

/// Einstellungen des Abgleichs (nur auf dem Handy, das abgleicht).
class GoogleSyncConfig {
  const GoogleSyncConfig({
    this.importCalendarKey = '',
    this.importFrom = const [],
    this.defaultTarget,
    this.targets = const {},
  });

  /// App-Kalender für Termine aus dem Handy-Kalender ('' = keine Übernahme).
  final String importCalendarKey;

  /// Handy-Kalender, deren Termine übernommen werden.
  final List<int> importFrom;

  /// Ziel für App-Termine (null = nicht übertragen).
  final int? defaultTarget;

  /// Abweichende Ziele je App-Kalender (Schlüssel `quelle/kalender`); null = nicht übertragen.
  final Map<String, int?> targets;

  int? targetFor(String calendarKey) =>
      targets.containsKey(calendarKey) ? targets[calendarKey] : defaultTarget;
}

/// App-Termin → Kopie im Handy-Kalender (Zeile, Kalender, Prüfsumme).
class OutPair {
  OutPair(this.row, this.cal, this.hash);
  int row;
  int cal;
  String hash;
  Map<String, Object?> toJson() => {'g': row, 'c': cal, 'h': hash};
}

/// Termin im Handy-Kalender → App-Termin (ID, Prüfsumme).
class InPair {
  InPair(this.app, this.hash);
  String app;
  String hash;
  Map<String, Object?> toJson() => {'a': app, 'h': hash};
}

/// Zuordnungen App-Termin ↔ Handy-Termin samt Prüfsumme des zuletzt
/// gemeinsamen Stands. Liegt nur auf diesem Handy.
class GoogleSyncState {
  final Map<String, OutPair> out = {};
  final Map<int, InPair> inn = {};
  final Map<String, InPair> inst = {};

  /// Übernommene Termine, die die Besitzerin in der App gelöscht hat.
  final Set<String> tombstones = {};

  static Future<GoogleSyncState> load(File f) async {
    final s = GoogleSyncState();
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      (j['out'] as Map? ?? {}).forEach((k, v) {
        if (v is Map) s.out['$k'] = OutPair((v['g'] as num).toInt(), (v['c'] as num).toInt(), '${v['h'] ?? ''}');
      });
      (j['in'] as Map? ?? {}).forEach((k, v) {
        final id = int.tryParse('$k');
        if (id != null && v is Map) s.inn[id] = InPair('${v['a']}', '${v['h'] ?? ''}');
      });
      (j['inst'] as Map? ?? {}).forEach((k, v) {
        if (v is Map) s.inst['$k'] = InPair('${v['a']}', '${v['h'] ?? ''}');
      });
      for (final t in j['tomb'] as List? ?? []) {
        s.tombstones.add('$t');
      }
    } catch (_) {
      // Fehlt oder unlesbar: Zuordnungen werden über Markierungen neu gefunden.
    }
    return s;
  }

  Future<void> save(File f) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'v': 1,
      'out': {for (final e in out.entries) e.key: e.value.toJson()},
      'in': {for (final e in inn.entries) '${e.key}': e.value.toJson()},
      'inst': {for (final e in inst.entries) e.key: e.value.toJson()},
      'tomb': tombstones.toList(),
    }), flush: true);
    await tmp.rename(f.path);
  }

  /// Merkt sich, dass die Besitzerin einen übernommenen Termin gelöscht hat
  /// (der Abgleich löscht ihn dann auch im Handy-Kalender).
  static Future<void> addTombstone(File f, String appEventId) async {
    final s = await load(f);
    if (!s.inn.values.any((p) => p.app == appEventId)) return;
    s.tombstones.add(appEventId);
    await s.save(f);
  }
}

class GoogleSyncResult {
  int exported = 0;
  int updatedOut = 0;
  int deletedOut = 0;
  int imported = 0;
  int updatedIn = 0;
  int deletedIn = 0;
  int reverted = 0;
  final List<String> warnings = [];

  /// Wurden App-Termine geändert (dann muss die App ihr Repo abgleichen)?
  bool get appChanged => imported + updatedIn + deletedIn + reverted > 0;
  bool get anything => appChanged || exported + updatedOut + deletedOut > 0;

  String get summary {
    final p = [
      if (exported + updatedOut + deletedOut > 0)
        '→ Google: ${[if (exported > 0) '$exported neu', if (updatedOut > 0) '$updatedOut geändert', if (deletedOut > 0) '$deletedOut gelöscht'].join(', ')}',
      if (imported + updatedIn + deletedIn > 0)
        '← Google: ${[if (imported > 0) '$imported neu', if (updatedIn > 0) '$updatedIn geändert', if (deletedIn > 0) '$deletedIn gelöscht'].join(', ')}',
    ];
    return p.isEmpty ? 'Alles abgeglichen' : p.join(' · ');
  }
}

class GoogleSyncException implements Exception {
  const GoogleSyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Zwei-Wege-Abgleich zwischen den App-Kalendern und den Kalendern des
/// Handys (z. B. Google):
/// - App-Termine landen im Ziel-Kalender (markiert als Kopie der App),
/// - Termine der gewählten Handy-Kalender landen im App-Kalender
///   [GoogleSyncConfig.importCalendarKey],
/// - Änderungen und Löschungen laufen in beide Richtungen; geändert haben
///   beide Seiten → die Herkunftsseite gewinnt,
/// - übernommene Termine darf nur [me] (die Besitzerin) in der App ändern;
///   Änderungen anderer werden zurückgesetzt,
/// - verschwinden plötzlich viele Termine auf einer Seite, wird nichts
///   gelöscht (Schutz vor Kontowechsel, leerem Speicher usw.).
class GoogleSync {
  GoogleSync({
    required this.data,
    required this.api,
    required this.config,
    required this.stateFile,
    required this.me,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppCalendarData data;
  final DeviceCalendarApi api;
  final GoogleSyncConfig config;
  final File stateFile;
  final String me;
  final DateTime Function() _clock;

  static const pastDays = 90;
  static const instancePastDays = 30;
  static const instanceFutureDays = 400;

  Future<GoogleSyncResult> run() async {
    await stateFile.parent.create(recursive: true);
    final lock = await File('${stateFile.path}.lock').open(mode: FileMode.write);
    await lock.lock(FileLock.blockingExclusive);
    try {
      return await _run();
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  Future<GoogleSyncResult> _run() async {
    final res = GoogleSyncResult();
    if (!await api.hasPermission()) {
      throw const GoogleSyncException('Keine Berechtigung für den Kalender des Handys.');
    }
    final now = _clock();
    final fromDay = dateOnly(now).subtract(const Duration(days: pastDays));
    final fromMs = fromDay.millisecondsSinceEpoch;
    final state = await GoogleSyncState.load(stateFile);

    final devCals = {for (final c in await api.calendars()) c.id: c};
    bool validTarget(int? id) => id != null && (devCals[id]?.writable ?? false);
    final importCal = data.calendars.where((c) => c.key == config.importCalendarKey).firstOrNull;
    final importFrom = config.importFrom.where(devCals.containsKey).toList();
    if (config.importFrom.length != importFrom.length) {
      res.warnings.add('Ein gewählter Google-Kalender ist nicht mehr auf dem Handy.');
    }
    final doImport = importFrom.isNotEmpty && importCal != null;
    if (importFrom.isNotEmpty && importCal == null) {
      res.warnings.add('Der App-Kalender für Google-Termine fehlt – Übernahme pausiert.');
    }
    final targetIds = {
      if (validTarget(config.defaultTarget)) config.defaultTarget!,
      for (final t in config.targets.values)
        if (validTarget(t)) t!,
    };
    if (config.defaultTarget != null && !validTarget(config.defaultTarget)) {
      res.warnings.add('Der Google-Kalender für App-Termine fehlt oder ist schreibgeschützt.');
    }

    // ---------------------------------------------------------- Handy lesen
    final rows = await api.events({...importFrom, ...targetIds}.toList(), fromMs);
    final byId = {for (final r in rows) r.id: r};
    final paired = {
      for (final p in state.out.values) p.row,
      ...state.inn.keys,
      for (final k in state.inst.keys) int.tryParse(k.split(':').first) ?? -1,
    }..removeAll(byId.keys);
    final all = {...byId};
    if (paired.isNotEmpty) {
      for (final r in await api.eventsByIds(paired.toList())) {
        all[r.id] = r;
      }
    }
    final exceptionsOf = <int, List<DeviceEvent>>{};
    for (final r in rows) {
      if (r.originalId != null) exceptionsOf.putIfAbsent(r.originalId!, () => []).add(r);
    }
    final copiesByApp = <String, DeviceEvent>{};
    for (final r in rows) {
      final uri = r.customAppUri ?? '';
      if (r.customAppPackage == kAppPackage && uri.startsWith(_uriPrefix)) {
        copiesByApp[uri.substring(_uriPrefix.length)] = r;
      }
    }

    final appEvents = List.of(data.events);
    final appById = {for (final e in appEvents) e.id: e};
    final importKey = importCal?.key ?? config.importCalendarKey;
    final inPairRows = state.inn.keys.toSet();

    // Löschungen, weil etwas auf der anderen Seite verschwand (mit Schutz)
    final vanishedInGoogle = <(CalendarEvent, void Function())>[];
    final vanishedInApp = <(int, void Function())>[];

    Map<String, Object?> rowValues(CalendarEvent e, {int? calendarId}) => rowValuesFromApp(e,
        calendarId: calendarId, appPackage: kAppPackage, appUri: '$_uriPrefix${e.id}');

    bool inWindow(CalendarEvent e) {
      final r = e.recurrence;
      if (r != null) return r.until == null || !r.until!.isBefore(fromDay);
      return !dateOnly(e.end).isBefore(fromDay);
    }

    // Gleicher Termin schon im Ziel (z. B. nach Neuinstallation)?
    DeviceEvent? findTwin(CalendarEvent e, int target) {
      final n = normFromApp(e);
      for (final r in rows) {
        if (r.calendarId != target || r.isException || inPairRows.contains(r.id)) continue;
        if (state.out.values.any((p) => p.row == r.id)) continue;
        if (r.customAppPackage == kAppPackage) continue;
        final m = normFromRow(r, exceptionsOf[r.id] ?? const []);
        if (m.title == n.title && m.start == n.start && m.end == n.end && m.allDay == n.allDay) return r;
      }
      return null;
    }

    // ---------------------------------------------------------- App → Handy
    final claimed = <int>{};
    for (final e in appEvents) {
      final pair = state.out[e.id];
      if (e.calendarKey == importKey) {
        // Liegt jetzt im Kalender der übernommenen Termine: keine Kopie mehr.
        if (pair != null) {
          if (validTarget(pair.cal) && all[pair.row]?.deleted == false) await api.delete(pair.row);
          state.out.remove(e.id);
        }
        continue;
      }
      final target = config.targetFor(e.calendarKey);
      if (target == null) {
        if (pair != null && validTarget(pair.cal)) {
          if (all[pair.row] != null && !all[pair.row]!.deleted) await api.delete(pair.row);
          state.out.remove(e.id);
          res.deletedOut++;
        }
        continue;
      }
      if (!validTarget(target)) {
        if (pair != null) claimed.add(pair.row);
        continue;
      }
      var p = pair;
      if (p == null) {
        if (!inWindow(e)) continue;
        final twin = copiesByApp[e.id] ?? findTwin(e, target);
        if (twin != null) {
          p = state.out[e.id] = OutPair(twin.id, twin.calendarId, '');
        } else {
          final id = await api.insert(rowValues(e, calendarId: target));
          if (id >= 0) {
            state.out[e.id] = OutPair(id, target, normFromApp(e).hash);
            claimed.add(id);
            res.exported++;
          }
          continue;
        }
      }
      claimed.add(p.row);
      final row = all[p.row];
      if (row == null || row.deleted) {
        if (!validTarget(p.cal)) continue;
        final id = e.id;
        vanishedInGoogle.add((e, () => state.out.remove(id)));
        continue;
      }
      if (row.calendarId != target) {
        await api.delete(row.id);
        final id = await api.insert(rowValues(e, calendarId: target));
        state.out[e.id] = OutPair(id, target, normFromApp(e).hash);
        claimed.add(id);
        res.updatedOut++;
        continue;
      }
      final desired = normFromApp(e);
      final actual = normFromRow(row, exceptionsOf[row.id] ?? const []);
      if (desired.hash == actual.hash) {
        p.hash = desired.hash;
        continue;
      }
      final appChanged = desired.hash != p.hash;
      if (appChanged || actual.rule.startsWith('RAW:')) {
        await api.update(row.id, rowValues(e));
        p.hash = desired.hash;
        res.updatedOut++;
      } else {
        applyRowToApp(e, row, exceptionsOf[row.id] ?? const []);
        await data.saveEvent(e);
        p.hash = normFromApp(e).hash;
        res.updatedIn++;
      }
    }
    // App-Termine gelöscht → Kopie löschen
    for (final entry in state.out.entries.toList()) {
      if (appById.containsKey(entry.key)) continue;
      final p = entry.value;
      if (!validTarget(p.cal)) continue;
      final row = all[p.row];
      if (row == null || row.deleted) {
        state.out.remove(entry.key);
        continue;
      }
      vanishedInApp.add((row.id, () => state.out.remove(entry.key)));
    }
    // Verwaiste Kopien (App-Termin gibt es nicht mehr, Zuordnung verloren)
    final queued = {for (final (id, _) in vanishedInApp) id};
    for (final entry in copiesByApp.entries) {
      if (appById.containsKey(entry.key) || claimed.contains(entry.value.id) || queued.contains(entry.value.id)) {
        continue;
      }
      vanishedInApp.add((entry.value.id, () {}));
    }

    // ---------------------------------------------------------- Handy → App
    final seenIn = <int>{};
    final seenSeries = <int>{};
    if (doImport) {
      final ours = {...claimed, for (final p in state.out.values) p.row};
      final candidates = [
        for (final r in rows)
          if (importFrom.contains(r.calendarId) && !ours.contains(r.id) && r.customAppPackage != kAppPackage) r,
      ];
      final unsupportedSeries = {
        for (final r in candidates)
          if (!r.isException && r.recurring && !rowSupported(r)) r.id,
      };
      final importApp = {for (final e in appEvents) if (e.calendarKey == importKey) e.id: e};

      CalendarEvent newImported(String? id) => CalendarEvent(
            id: id,
            sourceId: importCal.sourceId,
            calendarId: importCal.id,
            start: now,
            end: now,
          );

      for (final r in candidates) {
        if (unsupportedSeries.contains(r.id)) continue;
        if (r.isException) {
          if (r.canceled) continue; // als ausgelassener Tag in der Serie
          final orig = all[r.originalId];
          if (orig != null && unsupportedSeries.contains(orig.id)) continue; // steckt in den Vorkommen
          if (orig != null && !rowSupported(orig)) continue;
        }
        seenIn.add(r.id);
        final ex = r.isException ? const <DeviceEvent>[] : exceptionsOf[r.id] ?? const <DeviceEvent>[];
        final g = normFromRow(r, ex);
        var p = state.inn[r.id];
        if (p == null) {
          final found = importApp.values.where((e) {
            final gf = e.extra['google'];
            return gf is Map && gf['event'] == r.id && gf['instance'] == null;
          }).firstOrNull;
          if (found != null) {
            p = state.inn[r.id] = InPair(found.id, '');
          } else {
            final ne = newImported(null);
            applyRowToApp(ne, r, ex);
            ne.extra['google'] = {'event': r.id, 'calendar': r.calendarId};
            await data.saveEvent(ne);
            state.inn[r.id] = InPair(ne.id, g.hash);
            res.imported++;
            continue;
          }
        }
        final ae = appById[p.app];
        if (ae == null) {
          if (state.tombstones.contains(p.app)) {
            await api.delete(r.id);
            state.inn.remove(r.id);
            res.deletedOut++;
          } else {
            // Gelöscht, aber nicht von der Besitzerin: wiederherstellen.
            final ne = newImported(p.app);
            applyRowToApp(ne, r, ex);
            ne.extra['google'] = {'event': r.id, 'calendar': r.calendarId};
            await data.saveEvent(ne);
            p.hash = g.hash;
            res.reverted++;
          }
          continue;
        }
        if (ae.calendarKey != importKey) {
          // In einen App-Kalender verschoben: ist jetzt ein App-Termin und
          // kommt als Kopie zurück; das Original im Handy-Kalender entfällt.
          await api.delete(r.id);
          state.inn.remove(r.id);
          ae.extra.remove('google');
          await data.saveEvent(ae);
          res.deletedOut++;
          continue;
        }
        final a = normFromApp(ae);
        if (a.hash == g.hash) {
          p.hash = g.hash;
          continue;
        }
        final googleChanged = g.hash != p.hash;
        if (googleChanged || ae.updatedBy != me) {
          applyRowToApp(ae, r, ex);
          await data.saveEvent(ae);
          p.hash = g.hash;
          googleChanged ? res.updatedIn++ : res.reverted++;
        } else {
          await api.update(r.id, rowValuesFromApp(ae));
          p.hash = a.hash;
          res.updatedOut++;
        }
      }

      // Serien, die die App nicht abbilden kann: einzelne Vorkommen (nur lesen)
      final iFrom = now.subtract(const Duration(days: instancePastDays)).millisecondsSinceEpoch;
      final iTo = now.add(const Duration(days: instanceFutureDays)).millisecondsSinceEpoch;
      for (final id in unsupportedSeries) {
        final r = byId[id]!;
        seenSeries.add(id);
        final current = <String>{};
        for (final (b, en) in await api.instances(id, iFrom, iTo)) {
          final key = '$id:$b';
          current.add(key);
          final single = DeviceEvent(
              id: r.id, calendarId: r.calendarId, title: r.title, description: r.description,
              location: r.location, dtstart: b, dtend: en, allDay: r.allDay);
          final g = normFromRow(single);
          var p = state.inst[key];
          if (p == null) {
            final found = importApp.values.where((e) {
              final gf = e.extra['google'];
              return gf is Map && gf['event'] == id && gf['instance'] == b;
            }).firstOrNull;
            if (found != null) p = state.inst[key] = InPair(found.id, '');
          }
          final ae = p == null ? null : appById[p.app];
          if (ae != null && normFromApp(ae).hash == g.hash) {
            p!.hash = g.hash;
            continue;
          }
          final target = ae ?? newImported(p?.app);
          applyRowToApp(target, single);
          target.extra['google'] = {'event': id, 'calendar': r.calendarId, 'instance': b};
          await data.saveEvent(target);
          state.inst[key] = InPair(target.id, g.hash);
          ae == null && p == null ? res.imported++ : res.updatedIn++;
        }
        for (final key in state.inst.keys.where((k) => k.startsWith('$id:')).toList()) {
          if (current.contains(key)) continue;
          final b = int.tryParse(key.split(':').last) ?? 0;
          if (b < iFrom || b > iTo) continue; // nur außerhalb des Fensters
          final ae = appById[state.inst[key]!.app];
          if (ae != null) {
            await data.deleteEvent(ae);
            res.deletedIn++;
          }
          state.inst.remove(key);
        }
      }

      // Übernommene Termine, die im Handy-Kalender verschwunden sind
      for (final entry in state.inn.entries.toList()) {
        if (seenIn.contains(entry.key)) continue;
        final row = all[entry.key];
        final ae = appById[entry.value.app];
        final gone = row == null || row.deleted || !importFrom.contains(row.calendarId);
        final nowSeries = row != null && unsupportedSeries.contains(row.id);
        if (!gone && !nowSeries) {
          // Nur außerhalb des Zeitfensters oder abgesagte Ausnahme
          if (row.canceled && ae != null) {
            vanishedInGoogle.add((ae, () => state.inn.remove(entry.key)));
          }
          continue;
        }
        if (ae == null) {
          state.inn.remove(entry.key);
        } else if (nowSeries) {
          await data.deleteEvent(ae);
          state.inn.remove(entry.key);
          res.deletedIn++;
        } else {
          vanishedInGoogle.add((ae, () => state.inn.remove(entry.key)));
        }
      }
      for (final key in state.inst.keys.toList()) {
        final id = int.tryParse(key.split(':').first) ?? -1;
        if (seenSeries.contains(id)) continue;
        final ae = appById[state.inst[key]!.app];
        if (ae != null) {
          vanishedInGoogle.add((ae, () => state.inst.remove(key)));
        } else {
          state.inst.remove(key);
        }
      }
      state.tombstones.clear();
    }

    // ---------------------------------------------------------- Löschungen mit Schutz
    bool tooMany(int n, int total) => n > 5 && n > total * 0.3;
    if (tooMany(vanishedInGoogle.length, state.inn.length + state.out.length + state.inst.length)) {
      res.warnings.add('${vanishedInGoogle.length} Termine fehlen plötzlich im Google-Kalender – '
          'zur Sicherheit wurde in der App nichts gelöscht.');
    } else {
      for (final (ae, done) in vanishedInGoogle) {
        await data.deleteEvent(ae);
        done();
        res.deletedIn++;
      }
    }
    if (tooMany(vanishedInApp.length, state.out.length)) {
      res.warnings.add('${vanishedInApp.length} App-Termine fehlen plötzlich – '
          'zur Sicherheit wurde im Google-Kalender nichts gelöscht.');
    } else {
      for (final (rowId, done) in vanishedInApp) {
        await api.delete(rowId);
        done();
        res.deletedOut++;
      }
    }
    await state.save(stateFile);
    return res;
  }
}

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import 'core/crypto_service.dart';
import 'core/doc_store.dart';
import 'core/github_api.dart';
import 'core/source_config.dart';
import 'core/sync_engine.dart';
import 'models/calendar_models.dart';
import 'models/holidays.dart';
import 'models/occurrences.dart';

const String kAppId = 'encrypted-calendar';

/// Eine geöffnete Datenquelle (Repo + Schlüssel + lokale Kopie).
class SourceRuntime {
  SourceRuntime(this.config, this.key, this.store, this.api, this.engine);

  final SourceConfig config;
  final SecretKey key;
  final DocStore store;
  final GithubApi api;
  final SyncEngine engine;
  bool syncing = false;
  String? error;

  /// Hinweis ohne Fehlercharakter (z. B. Daten einer neueren App-Version).
  String? notice;
  SyncResult? lastResult;

  String get id => config.id;
}

/// Hinweis, wenn Einträge im Format einer neueren App-Version vorliegen.
const String kNewerDataHint = 'Einige Einträge stammen von einer neueren '
    'App-Version und erscheinen erst nach einem Update.';

class SetupException implements Exception {
  const SetupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Datenzugriff über alle Datenquellen – ohne UI-Abhängigkeiten, damit auch
/// der Hintergrund-Worker ihn benutzen kann.
class CalendarRepository {
  CalendarRepository({
    required this.baseDir,
    required this.configStore,
    required this.userName,
  });

  final String baseDir;
  final SourceConfigStore configStore;
  String Function() userName;
  final CryptoService crypto = CryptoService();
  final List<SourceRuntime> sources = [];

  int _version = 0;
  int _cacheVersion = -1;
  List<CalendarDef> _calendars = [];
  List<CalendarEvent> _events = [];

  /// Zählt bei jeder Datenänderung hoch (für Caches in der UI).
  int get version => _version;
  void touch() => _version++;

  SourceRuntime? source(String id) =>
      sources.where((s) => s.id == id).firstOrNull;

  // ------------------------------------------------------------ Öffnen

  Future<void> open() async {
    sources.clear();
    for (final cfg in await configStore.load()) {
      if (cfg.masterKeyB64.isEmpty) continue;
      sources.add(await _openSource(cfg));
    }
    touch();
  }

  Future<SourceRuntime> _openSource(SourceConfig cfg) async {
    final key = SecretKey(base64Decode(cfg.masterKeyB64));
    final store = DocStore(
        baseDir: '$baseDir/sources/${cfg.id}', crypto: crypto, key: key);
    await store.init();
    final api = GithubApi(cfg.github);
    final engine = SyncEngine(
      store: store,
      api: api,
      crypto: crypto,
      key: key,
      managedDirs: const ['calendars', 'events'],
      onConflict: (path, loser, winner) =>
          _conflictCopy(store, path, loser, winner),
    );
    return SourceRuntime(cfg, key, store, api, engine);
  }

  /// Bei Termin-Konflikten bleibt die unterlegene Fassung als Kopie erhalten.
  Future<void> _conflictCopy(DocStore store, String path,
      Map<String, dynamic> loser, Map<String, dynamic> winner) async {
    if (!path.startsWith('events/')) return;
    final id = const Uuid().v4();
    await store.put('events/$id.enc', {
      ...loser,
      'id': id,
      'title': '${loser['title'] ?? ''} (Konflikt)',
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  /// Lädt eine Datenquelle neu von der Platte (nach Hintergrund-Sync).
  Future<bool> reloadIfChangedOnDisk() async {
    var changed = false;
    for (final s in sources) {
      if (await s.store.changedOnDisk()) {
        await s.store.init();
        changed = true;
      }
    }
    if (changed) touch();
    return changed;
  }

  // ------------------------------------------------------------ Lesen

  void _rebuildCache() {
    if (_cacheVersion == _version) return;
    _calendars = [
      for (final s in sources)
        for (final e in s.store.inDir('calendars'))
          _tryCalendar(e.key, e.value, s.id),
    ].whereType<CalendarDef>().toList()
      ..sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final known = {for (final c in _calendars) c.key};
    _events = [
      for (final s in sources)
        for (final e in s.store.inDir('events'))
          _tryEvent(e.key, e.value, s.id),
    ].whereType<CalendarEvent>().where((e) => known.contains(e.calendarKey)).toList();
    _cacheVersion = _version;
  }

  // Unlesbare Dokumente (beschädigt oder von einer ganz anderen App-Version)
  // werden ausgeblendet, bleiben aber unverändert im Store und im Repo.
  CalendarEvent? _tryEvent(String path, Map<String, dynamic> j, String sourceId) {
    try {
      return CalendarEvent.fromJson(j, sourceId, path: path);
    } catch (_) {
      return null;
    }
  }

  CalendarDef? _tryCalendar(String path, Map<String, dynamic> j, String sourceId) {
    try {
      return CalendarDef.fromJson(j, sourceId, path: path);
    } catch (_) {
      return null;
    }
  }

  List<CalendarDef> get calendars {
    _rebuildCache();
    return _calendars;
  }

  List<CalendarEvent> get events {
    _rebuildCache();
    return _events;
  }

  Map<String, CalendarDef> get calendarsByKey =>
      {for (final c in calendars) c.key: c};

  CalendarDef? calendar(String key) => calendarsByKey[key];

  List<CalendarDef> calendarsOf(String sourceId) =>
      calendars.where((c) => c.sourceId == sourceId).toList();

  /// Alle Vorkommen im Zeitraum [from, to), optional gefiltert, inkl. Feiertage.
  List<Occurrence> occurrences(DateTime from, DateTime to,
      {Set<String>? calendarKeys, String? holidayState}) {
    final byKey = calendarsByKey;
    final evs = calendarKeys == null
        ? events
        : events.where((e) => calendarKeys.contains(e.calendarKey));
    final out = expandOccurrences(evs, byKey, from, to);
    if (holidayState != null) {
      for (var y = from.year; y <= to.year; y++) {
        holidaysFor(y, holidayState).forEach((day, name) {
          if (!day.isBefore(dateOnly(from)) && day.isBefore(dateOnly(to))) {
            out.add(Occurrence(null, null, day, day, holiday: true)
              ..holidayName = name);
          }
        });
      }
      out.sort(compareOccurrences);
    }
    return out;
  }

  // ------------------------------------------------------------ Schreiben

  Future<void> saveEvent(CalendarEvent e, {String? previousSourceId}) async {
    e.updatedAt = DateTime.now();
    e.updatedBy = userName();
    if (previousSourceId != null && previousSourceId != e.sourceId) {
      await source(previousSourceId)?.store.delete(e.path);
    }
    await source(e.sourceId)!.store.put(e.path, e.toJson());
    touch();
  }

  Future<void> deleteEvent(CalendarEvent e) async {
    await source(e.sourceId)?.store.delete(e.path);
    touch();
  }

  /// Löscht nur ein Vorkommen einer Serie (EXDATE).
  Future<void> deleteOccurrence(CalendarEvent e, DateTime day) async {
    e.exdates = [...e.exdates, dateOnly(day)];
    await saveEvent(e);
  }

  /// Beendet eine Serie vor [day] (dieses und alle folgenden löschen).
  Future<void> endSeriesBefore(CalendarEvent e, DateTime day) async {
    final r = e.recurrence;
    if (r == null) return;
    final until = dateOnly(day).subtract(const Duration(days: 1));
    if (until.isBefore(dateOnly(e.start))) {
      await deleteEvent(e);
      return;
    }
    e.recurrence = r.copyWith(until: until, clearCount: true);
    await saveEvent(e);
  }

  Future<void> saveCalendar(CalendarDef c) async {
    c.updatedAt = DateTime.now();
    c.updatedBy = userName();
    await source(c.sourceId)!.store.put(c.path, c.toJson());
    touch();
  }

  /// Löscht einen Kalender samt aller seiner Termine.
  Future<void> deleteCalendar(CalendarDef c) async {
    final s = source(c.sourceId);
    if (s == null) return;
    for (final e in events.where((e) => e.calendarKey == c.key).toList()) {
      await s.store.delete(e.path, persistState: false);
    }
    await s.store.delete(c.path);
    touch();
  }

  // ------------------------------------------------------------ Sync

  Future<List<SyncResult>> syncAll() async {
    final results = <SyncResult>[];
    for (final s in sources) {
      final r = await syncSource(s);
      if (r != null) results.add(r);
    }
    return results;
  }

  Future<SyncResult?> syncSource(SourceRuntime s) async {
    if (s.syncing) return null;
    s.syncing = true;
    try {
      final r = await s.engine.sync();
      s.lastResult = r;
      s.error = null;
      s.notice = r.newer > 0 ? kNewerDataHint : null;
      if (r.pulled > 0 || r.conflicts > 0 || r.newer > 0) touch();
      return r;
    } on RepoTooNewException catch (e) {
      s.error = e.message;
    } on GithubApiException catch (e) {
      s.error = e.isUnauthorized
          ? 'Token ungültig oder abgelaufen.'
          : 'Sync fehlgeschlagen: ${e.message}';
    } catch (e) {
      s.error = 'Keine Verbindung (${e.runtimeType}) – Änderungen bleiben lokal '
          'gespeichert und werden später übertragen.';
    } finally {
      s.syncing = false;
    }
    return null;
  }

  int get pendingCount =>
      sources.fold(0, (sum, s) => sum + s.store.pendingCount);

  DateTime? get lastSync {
    final all = sources.map((s) => s.store.lastSync).whereType<DateTime>();
    return all.isEmpty ? null : all.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  // ------------------------------------------------------------ Einrichtung

  static Future<String?> testConnection(GithubConfig cfg) async {
    try {
      await GithubApi(cfg).testConnection();
      return null;
    } on GithubApiException catch (e) {
      if (e.isNotFound) {
        return 'Repository nicht gefunden – Name prüfen und sicherstellen, '
            'dass das Token Zugriff auf dieses Repo hat.';
      }
      if (e.isUnauthorized) return 'Token ungültig oder ohne Berechtigung.';
      return e.toString();
    } catch (e) {
      return 'Verbindung fehlgeschlagen: $e';
    }
  }

  /// Fügt eine Datenquelle hinzu. Bei leerem Repo wird es initialisiert
  /// (meta.json + Schlüsselprobe), sonst wird die Passphrase geprüft.
  /// Liefert die Quelle und ob sie neu angelegt wurde.
  Future<(SourceRuntime, bool)> addSource({
    required String label,
    required GithubConfig github,
    required String passphrase,
  }) async {
    final api = GithubApi(github);
    try {
      await api.testConnection();
    } on GithubApiException catch (e) {
      throw SetupException(e.isNotFound
          ? 'Repository nicht gefunden.'
          : e.isUnauthorized
              ? 'Token ungültig oder ohne Berechtigung.'
              : 'GitHub-Zugriff fehlgeschlagen: ${e.message}');
    } catch (e) {
      throw SetupException('Keine Verbindung zu ${github.apiBase}: $e');
    }
    final CryptoParams? existing;
    try {
      existing = await SyncEngine.fetchMeta(api);
    } on RepoTooNewException catch (e) {
      throw SetupException(e.message);
    } on FormatException {
      throw const SetupException('meta.json im Repository ist beschädigt.');
    }
    final isFresh = existing == null;
    final params = existing ?? CryptoParams.generate();
    final key = await crypto.deriveKey(passphrase, params);
    if (isFresh) {
      await SyncEngine.initializeRemote(api, crypto, key, params, app: kAppId);
    } else {
      bool ok;
      try {
        ok = await SyncEngine.verifyKey(api, crypto, key);
      } on RepoTooNewException catch (e) {
        throw SetupException(e.message);
      }
      if (!ok) {
        throw const SetupException(
            'Passphrase falsch – sie passt nicht zu den Daten im Repository.');
      }
    }
    final cfg = SourceConfig(
      id: const Uuid().v4().substring(0, 8),
      label: label,
      owner: github.owner,
      repo: github.repo,
      branch: github.branch,
      token: github.token,
      apiBase: github.apiBase,
      masterKeyB64: base64Encode(await key.extractBytes()),
      cryptoParams: params,
    );
    final all = await configStore.load()..add(cfg);
    await configStore.save(all);
    final rt = await _openSource(cfg);
    sources.add(rt);
    await syncSource(rt);
    touch();
    return (rt, isFresh);
  }

  Future<void> updateSourceConnection(SourceRuntime s,
      {required String label, required GithubConfig github}) async {
    final all = await configStore.load();
    final cfg = all.firstWhere((c) => c.id == s.id);
    cfg
      ..label = label
      ..owner = github.owner
      ..repo = github.repo
      ..branch = github.branch
      ..token = github.token
      ..apiBase = github.apiBase;
    await configStore.save(all);
    final idx = sources.indexOf(s);
    sources[idx] = await _openSource(cfg);
    touch();
  }

  /// Entfernt eine Datenquelle vom Gerät (Daten im Repo bleiben erhalten).
  Future<void> removeSource(SourceRuntime s) async {
    await s.store.wipe();
    sources.remove(s);
    final all = await configStore.load()..removeWhere((c) => c.id == s.id);
    await configStore.save(all);
    touch();
  }
}

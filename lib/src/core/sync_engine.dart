import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'app_log.dart';
import 'crypto_service.dart';
import 'doc_store.dart';
import 'github_api.dart';

const String kMetaPath = 'meta.json';
const String kKeyCheckPath = 'keycheck.enc';

/// Datenformat-Generation des Repos (`schema` in meta.json), die diese App
/// sicher lesen und schreiben kann.
///
/// Kompatibilitätsregeln:
/// * Neue Felder in Dokumenten sind additiv – ältere Apps lassen sie beim
///   Speichern unangetastet (siehe `extra` in den Modellen). Dafür wird die
///   Generation NICHT erhöht.
/// * Nur ein echter Bruch (den ältere Apps beim Schreiben beschädigen würden)
///   erhöht die Generation. Ältere Apps synchronisieren dann nicht mehr,
///   behalten ihre lokalen Änderungen und bitten um ein Update.
const int kSupportedRepoSchema = 1;

/// Das Daten-Repo wurde von einer neueren App-Version umgestellt.
class RepoTooNewException implements Exception {
  const RepoTooNewException();
  String get message => 'Die Daten wurden mit einer neueren App-Version '
      'gespeichert. Bitte die App aktualisieren – lokale Änderungen bleiben '
      'bis dahin erhalten.';
  @override
  String toString() => message;
}

/// Eine beim Sync übernommene fremde Änderung (für Benachrichtigungen).
class RemoteChange {
  const RemoteChange(this.path, this.before, this.after);
  final String path;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after; // null = gelöscht
}

class SyncResult {
  int pushed = 0;
  int pulled = 0;
  int conflicts = 0;

  /// Gleichzeitige Änderungen an verschiedenen Feldern, zusammengeführt.
  int merged = 0;

  /// Lokaler Stand wurde vor dem Abgleich von der Platte neu geladen, weil
  /// ein anderer Prozess (App bzw. Hintergrund-Abgleich) ihn geändert hat.
  bool reloaded = false;

  /// Beim Pull übersprungene, nicht entschlüsselbare Dateien.
  int skipped = 0;

  /// Dateien im Format einer neueren App-Version, die diese App noch nicht
  /// lesen kann (Stand nach dem Abgleich, nicht nur neu hinzugekommene).
  int newer = 0;
  final List<RemoteChange> changes = [];

  @override
  String toString() =>
      'gesendet: $pushed, empfangen: $pulled, Konflikte: $conflicts'
      '${merged > 0 ? ', zusammengeführt: $merged' : ''}'
      '${skipped > 0 ? ', übersprungen: $skipped' : ''}';
}

/// Wird bei einem SHA-Konflikt mit der unterlegenen und der gewinnenden
/// Fassung aufgerufen (z. B. um eine Konfliktkopie anzulegen).
typedef ConflictHandler = Future<void> Function(
    String path, Map<String, dynamic> loser, Map<String, dynamic> winner);

/// Führt zwei Fassungen zusammen, die beide auf [base] beruhen: Felder, die
/// nur eine Seite geändert hat, kommen von dieser Seite. Haben beide dasselbe
/// Feld (bzw. dieselbe Feldgruppe aus [groups]) verschieden geändert, ist es
/// ein echter Konflikt: null. Zeitstempel und Bearbeiter kommen von der
/// jüngeren Fassung.
Map<String, dynamic>? mergeDocs(
    Map<String, dynamic> base, Map<String, dynamic> local, Map<String, dynamic> remote,
    {List<Set<String>> groups = const []}) {
  const meta = {'updated_at', 'updated_by'};
  final keys = {...base.keys, ...local.keys, ...remote.keys}..removeAll(meta);
  final units = <Set<String>>[];
  final grouped = <String>{};
  for (final g in groups) {
    final u = g.intersection(keys);
    if (u.isEmpty) continue;
    units.add(u);
    grouped.addAll(u);
  }
  for (final k in keys) {
    if (!grouped.contains(k)) units.add({k});
  }
  String unit(Map<String, dynamic> m, Set<String> u) => canonicalJson({
        for (final k in u) k: m.containsKey(k) ? m[k] : const {'\u0000': 'fehlt'},
      });
  final merged = <String, dynamic>{};
  for (final u in units) {
    final b = unit(base, u), l = unit(local, u), r = unit(remote, u);
    final Map<String, dynamic> src;
    if (l == r || r == b) {
      src = local;
    } else if (l == b) {
      src = remote;
    } else {
      return null;
    }
    for (final k in u) {
      if (src.containsKey(k)) merged[k] = src[k];
    }
  }
  final later = docUpdatedAt(remote).isAfter(docUpdatedAt(local)) ? remote : local;
  for (final k in meta) {
    if (later.containsKey(k)) merged[k] = later[k];
  }
  return merged;
}

DateTime docUpdatedAt(Map<String, dynamic> doc) {
  final v = doc['updated_at'];
  return (v is String ? DateTime.tryParse(v) : null) ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

/// Synchronisiert einen [DocStore] mit dem GitHub-Repo.
///
/// Push: Sync-Queue abspielen (Contents-API, SHA als optimistische Sperre).
/// Pull: ein Request auf die Trees-API liefert alle Datei-SHAs; nur
/// geänderte Blobs werden geladen. Konflikte: "Last write wins" über
/// `updated_at`; die unterlegene Fassung geht an [onConflict].
class SyncEngine {
  SyncEngine({
    required this.store,
    required this.api,
    required this.crypto,
    required this.key,
    required this.managedDirs,
    this.onConflict,
    this.commitMessage = 'sync',
    this.logTag = 'sync',
    this.mergeGroups = const [],
  });

  /// Felder, die beim Zusammenführen nur gemeinsam von einer Seite kommen
  /// (z. B. Beginn, Ende und Wiederholung eines Termins).
  final List<Set<String>> mergeGroups;

  /// Kennung im Protokoll, z. B. „sync/Gemeinsam“.
  final String logTag;

  final DocStore store;
  final GithubApi api;
  final CryptoService crypto;
  final SecretKey key;

  /// Verzeichnisse, die dieser Sync verwaltet (z. B. `['calendars', 'events']`).
  final List<String> managedDirs;
  final ConflictHandler? onConflict;
  final String commitMessage;

  bool _managed(String path) =>
      path.endsWith('.enc') &&
      managedDirs.any((d) => path.startsWith('$d/'));

  /// Vollständiger Sync. Ein Datei-Lock verhindert, dass App und
  /// Hintergrund-Worker gleichzeitig synchronisieren.
  Future<SyncResult> sync() async {
    final lockFile = File('${store.baseDir}/sync.lock');
    await lockFile.parent.create(recursive: true);
    final raf = await lockFile.open(mode: FileMode.write);
    await raf.lock(FileLock.blockingExclusive);
    final started = DateTime.now();
    try {
      final result = SyncResult();
      // Erst jetzt, mit der Sperre: Hat der andere Prozess inzwischen gesendet
      // oder empfangen, mit dessen Stand weitermachen. Sonst gingen schon
      // gesendete Änderungen mit veralteter Version noch einmal raus.
      if (await store.changedOnDisk()) {
        await store.init();
        result.reloaded = true;
        AppLog.info(logTag, 'Stand von der Platte neu geladen (anderer Prozess)');
      }
      // Repo von einer neueren App umgestellt: nichts schreiben, nichts laden.
      // Nur meta.json wird (bei Änderung) erneut geprüft – ein Request.
      if (store.repoSchema > kSupportedRepoSchema) {
        await _checkMeta((await api.getTree()).files[kMetaPath]);
        if (store.repoSchema > kSupportedRepoSchema) {
          throw const RepoTooNewException();
        }
      }
      var budget = _pushBudget();
      for (var round = 0; round < 3 && store.pending.isNotEmpty && budget > 0; round++) {
        budget -= await _push(result, budget);
      }
      await _pull(result);
      store.lastSync = DateTime.now();
      await store.saveState();
      if (result.pushed + result.pulled + result.conflicts + result.skipped > 0 || store.pendingCount > 0) {
        AppLog.info(logTag,
            'Abgleich: $result, ausstehend: ${store.pendingCount}, ${DateTime.now().difference(started).inMilliseconds} ms');
      }
      return result;
    } catch (e, st) {
      // Programmfehler mit Aufrufstapel, Netz- und API-Fehler kurz.
      if (e is Error) {
        AppLog.error(logTag, 'Abgleich fehlgeschlagen', e, st);
      } else {
        AppLog.warn(logTag, 'Abgleich fehlgeschlagen: $e');
      }
      rethrow;
    } finally {
      await raf.unlock();
      await raf.close();
    }
  }

  // ---------------------------------------------------------------- Push

  /// Höchstens so viele Schreibzugriffe je Sync und je Stunde: GitHub nimmt
  /// nur etwa 80 pro Minute und 500 pro Stunde an. Große Mengen (z. B. eine
  /// Übernahme vieler alter Termine) gehen so über mehrere Syncs hinaus.
  static const maxPushPerSync = 60;
  static const maxPushPerHour = 400;

  int _pushBudget() {
    final now = DateTime.now();
    final paused = store.pushPausedUntil;
    if (paused != null && now.isBefore(paused)) return 0;
    store.pushLog.removeWhere((t) => now.millisecondsSinceEpoch - t > const Duration(hours: 1).inMilliseconds);
    final left = maxPushPerHour - store.pushLog.length;
    return left < maxPushPerSync ? left : maxPushPerSync;
  }

  /// Spielt bis zu [budget] Einträge der Queue ab, neueste zuerst (eigene
  /// Änderungen überholen eine laufende Massenübernahme). Liefert die Anzahl.
  Future<int> _push(SyncResult result, int budget) async {
    final ops = List.of(store.pending)..sort((a, b) => b.at.compareTo(a.at));
    var used = 0;
    for (final op in ops) {
      if (used >= budget) break;
      try {
        if (op.isDelete) {
          await _pushDelete(op, result);
        } else {
          await _pushUpsert(op, result);
        }
      } on GithubApiException catch (e) {
        if (!e.isRateLimited) rethrow;
        // Gedrosselt: eine Weile nichts senden, Empfangen geht weiter.
        AppLog.warn(logTag, 'von GitHub gedrosselt, Senden pausiert 15 Min.');
        store.pushPausedUntil = DateTime.now().add(const Duration(minutes: 15));
        await store.saveState();
        return budget;
      }
      used++;
      store.pushLog.add(DateTime.now().millisecondsSinceEpoch);
    }
    return used;
  }

  Future<void> _pushUpsert(PendingOp op, SyncResult result) async {
    final doc = store.get(op.path);
    if (doc == null) {
      store.markSynced(op); // inzwischen gelöscht; Delete-Op folgt ggf.
      return;
    }
    final bytes = await crypto.encryptJson(doc, key);
    final baseSha = store.remoteShas[op.path];
    try {
      final newSha = await api.putFile(op.path, bytes, commitMessage, sha: baseSha);
      store.markSynced(op, newSha: newSha);
      result.pushed++;
      AppLog.info(logTag, 'gesendet ${op.path} (${_short(baseSha)} → ${_short(newSha)})');
    } on GithubApiException catch (e) {
      if (!e.isConflict) rethrow;
      await _resolveUpsertConflict(op, doc, bytes, result, baseSha);
    }
    await store.saveState();
  }

  static String _short(String? sha) => sha == null ? 'neu' : sha.substring(0, sha.length < 7 ? sha.length : 7);

  static String _clip(String s) => s.length > 90 ? '${s.substring(0, 87)}…' : s;

  /// Was sich zwischen zwei Fassungen unterscheidet (für das Protokoll).
  static String describeDiff(Map<String, dynamic> a, Map<String, dynamic> b) {
    final keys = {...a.keys, ...b.keys}..removeAll(const ['updated_at', 'updated_by']);
    final parts = [
      for (final k in keys.toList()..sort())
        if (canonicalJson(a[k]) != canonicalJson(b[k]))
          '$k: ${_clip(canonicalJson(a[k]))} ≠ ${_clip(canonicalJson(b[k]))}',
    ];
    return parts.isEmpty ? 'kein inhaltlicher Unterschied' : parts.join('; ');
  }

  Future<void> _resolveUpsertConflict(PendingOp op, Map<String, dynamic> local,
      List<int> bytes, SyncResult result, String? baseSha) async {
    final remoteFile = await api.getFile(op.path);
    if (remoteFile == null) {
      // Remote gelöscht, lokal geändert: lokale Fassung neu anlegen.
      final newSha = await api.putFile(op.path, bytes, commitMessage);
      store.markSynced(op, newSha: newSha);
      result.pushed++;
      return;
    }
    Map<String, dynamic> remote;
    try {
      remote = await crypto.decryptDoc(remoteFile.content!, key);
    } on UnsupportedFormatException {
      // Neuere App hat die Datei in einem neuen Format gespeichert: nicht
      // überschreiben. Die veraltete lokale Fassung tritt zurück.
      store.markSynced(op);
      await store.delete(op.path, fromRemote: true, persistState: false);
      store.unreadable[op.path] = remoteFile.sha;
      store.newer[op.path] = remoteFile.sha;
      result.skipped++;
      AppLog.warn(logTag, '${op.path}: remote im Format einer neueren App-Version, lokale Änderung verworfen');
      return;
    } on DecryptionFailedException {
      // Unlesbare Remote-Fassung: mit der lokalen überschreiben.
      final newSha = await api.putFile(op.path, bytes, commitMessage,
          sha: remoteFile.sha);
      store.markSynced(op, newSha: newSha);
      result.pushed++;
      AppLog.warn(logTag, '${op.path}: remote unlesbar, mit lokaler Fassung überschrieben');
      return;
    }
    final stale = 'gespeicherte Version ${_short(baseSha)}, remote ${_short(remoteFile.sha)}';
    if (sameDocContent(local, remote)) {
      // Beide Seiten haben dasselbe gespeichert (z. B. App und Hintergrund-
      // Abgleich dieselbe Änderung): kein Konflikt, Stand übernehmen.
      store.remoteShas[op.path] = remoteFile.sha;
      await store.put(op.path, remote, fromRemote: true, persistState: false);
      store.markSynced(op);
      AppLog.info(logTag, '${op.path}: gleicher Inhalt auf beiden Seiten, kein Konflikt ($stale)');
      return;
    }
    if (op.known.contains(docHash(remote))) {
      // Remote liegt ein Stand, auf dem die lokale Änderung beruht – nur die
      // gespeicherte Version war veraltet: lokale Fassung senden, kein Konflikt.
      final newSha = await api.putFile(op.path, bytes, commitMessage, sha: remoteFile.sha);
      store.markSynced(op, newSha: newSha);
      result.pushed++;
      AppLog.info(logTag, '${op.path}: veralteter Stand, lokale Änderung übernommen ($stale)');
      return;
    }
    final base = await store.baseOf(op.path);
    final merged = base == null ? null : mergeDocs(base, local, remote, groups: mergeGroups);
    if (merged != null) {
      // Beide haben verschiedene Felder geändert: beides übernehmen.
      final changed = describeDiff(local, remote);
      if (sameDocContent(merged, remote)) {
        store.remoteShas[op.path] = remoteFile.sha;
        await store.put(op.path, remote, fromRemote: true, persistState: false);
        store.markSynced(op);
      } else {
        final newSha = await api.putFile(op.path, await crypto.encryptJson(merged, key), commitMessage,
            sha: remoteFile.sha);
        store.remoteShas[op.path] = newSha;
        await store.put(op.path, merged, fromRemote: true, persistState: false);
        store.markSynced(op, newSha: newSha);
        result.pushed++;
      }
      result.merged++;
      result.changes.add(RemoteChange(op.path, local, merged));
      AppLog.info(logTag,
          '${op.path}: verschiedene Felder geändert, zusammengeführt ($stale; lokal ${local['updated_by']}, '
          'remote ${remote['updated_by']}; $changed)');
      return;
    }
    result.conflicts++;
    final remoteWins = docUpdatedAt(remote).isAfter(docUpdatedAt(local));
    AppLog.warn(
        logTag,
        'KONFLIKT ${op.path}: lokal ${local['updated_at']} (${local['updated_by']}, geändert ${op.at.toIso8601String()}), '
        'remote ${remote['updated_at']} (${remote['updated_by']}); $stale; '
        'bekannte Stände ${op.known.length}, Ausgangsfassung ${base == null ? 'unbekannt' : 'bekannt'}; '
        '${remoteWins ? 'remote' : 'lokal'} gewinnt; '
        'Unterschiede: ${describeDiff(local, remote)}');
    if (remoteWins) {
      // Remote gewinnt.
      store.remoteShas[op.path] = remoteFile.sha;
      await store.put(op.path, remote, fromRemote: true);
      store.markSynced(op);
      result.changes.add(RemoteChange(op.path, local, remote));
      await onConflict?.call(op.path, local, remote);
    } else {
      // Lokal gewinnt.
      final newSha = await api.putFile(op.path, bytes, commitMessage,
          sha: remoteFile.sha);
      store.markSynced(op, newSha: newSha);
      result.pushed++;
      await onConflict?.call(op.path, remote, local);
    }
  }

  Future<void> _pushDelete(PendingOp op, SyncResult result) async {
    final sha = store.remoteShas[op.path];
    if (sha == null) {
      store.markSynced(op);
      return;
    }
    try {
      await api.deleteFile(op.path, sha, commitMessage);
      store.markSynced(op);
      result.pushed++;
      AppLog.info(logTag, 'gelöscht ${op.path} (${_short(sha)})');
    } on GithubApiException catch (e) {
      if (!e.isConflict) rethrow;
      // Remote zwischenzeitlich geändert: Änderung schlägt Löschung.
      final remoteFile = await api.getFile(op.path);
      store.markSynced(op);
      if (remoteFile == null) return;
      AppLog.warn(logTag, '${op.path}: lokal gelöscht, remote inzwischen geändert – Änderung bleibt');
      try {
        final remote = await crypto.decryptDoc(remoteFile.content!, key);
        store.remoteShas[op.path] = remoteFile.sha;
        await store.put(op.path, remote, fromRemote: true);
        result.conflicts++;
        result.changes.add(RemoteChange(op.path, null, remote));
      } on DecryptionFailedException catch (e) {
        store.unreadable[op.path] = remoteFile.sha;
        if (e is UnsupportedFormatException) store.newer[op.path] = remoteFile.sha;
        result.skipped++;
      }
    }
    await store.saveState();
  }

  // ---------------------------------------------------------------- Pull

  Future<void> _pull(SyncResult result) async {
    final tree = await api.getTree();
    await _checkMeta(tree.files[kMetaPath]);
    final remote = {
      for (final e in tree.files.entries)
        if (_managed(e.key)) e.key: e.value,
    };
    store.unreadable.removeWhere((p, sha) => remote[p] != sha);
    store.newer.removeWhere((p, sha) => remote[p] != sha);

    final toFetch = [
      for (final e in remote.entries)
        if (!store.hasPendingFor(e.key) &&
            store.remoteShas[e.key] != e.value &&
            store.unreadable[e.key] != e.value)
          e,
    ];
    const batch = 6;
    for (var i = 0; i < toFetch.length; i += batch) {
      final chunk = toFetch.skip(i).take(batch);
      await Future.wait(chunk.map((e) async {
        final bytes = await api.getBlob(e.value);
        try {
          final doc = await crypto.decryptDoc(bytes, key);
          final before = store.get(e.key);
          final was = store.remoteShas[e.key];
          store.remoteShas[e.key] = e.value;
          await store.put(e.key, doc, fromRemote: true, persistState: false);
          result.pulled++;
          AppLog.info(logTag,
              'empfangen ${e.key} (${_short(was)} → ${_short(e.value)}, ${doc['updated_at']}, ${doc['updated_by']})');
          result.changes.add(RemoteChange(e.key, before, doc));
        } on UnsupportedFormatException {
          // Von einer neueren App-Version: die veraltete lokale Kopie
          // ausblenden, damit sie nicht versehentlich zurückgeschrieben wird.
          if (store.get(e.key) != null) {
            await store.delete(e.key, fromRemote: true, persistState: false);
          }
          store.unreadable[e.key] = e.value;
          store.newer[e.key] = e.value;
          result.skipped++;
        } catch (_) {
          // Beschädigt: überspringen, die letzte lesbare Fassung bleibt.
          store.unreadable[e.key] = e.value;
          result.skipped++;
        }
      }));
    }

    // Remote gelöschte Dokumente lokal entfernen.
    for (final path in List.of(store.remoteShas.keys)) {
      if (!_managed(path) ||
          remote.containsKey(path) ||
          store.hasPendingFor(path)) {
        continue;
      }
      final before = store.get(path);
      await store.delete(path, fromRemote: true, persistState: false);
      result.pulled++;
      result.changes.add(RemoteChange(path, before, null));
      AppLog.info(logTag, 'remote gelöscht $path');
    }
    store.lastTreeSha = tree.sha;
    result.newer = store.newer.length;
  }

  /// Prüft meta.json, wenn sie sich geändert hat (ein Request pro Änderung,
  /// sonst keiner).
  Future<void> _checkMeta(String? sha) async {
    if (sha == null || sha == store.metaSha) return;
    final file = await api.getFile(kMetaPath);
    if (file == null) return;
    store.repoSchema = readRepoSchema(file.content!);
    store.metaSha = sha;
    if (store.repoSchema > kSupportedRepoSchema) {
      await store.saveState();
      throw const RepoTooNewException();
    }
  }

  /// `schema` aus meta.json (1, wenn nicht vorhanden oder unlesbar).
  static int readRepoSchema(List<int> metaBytes) {
    try {
      final json = jsonDecode(utf8.decode(metaBytes));
      final v = json is Map ? json['schema'] : null;
      return v is num ? v.toInt() : 1;
    } catch (_) {
      return 1;
    }
  }

  // ------------------------------------------------------------ Einrichtung

  /// Liest die KDF-Parameter aus meta.json; null, wenn das Repo nicht
  /// initialisiert ist.
  ///
  /// Wirft [RepoTooNewException], wenn eine neuere App-Version das Repo
  /// eingerichtet oder umgestellt hat.
  static Future<CryptoParams?> fetchMeta(GithubApi api) async {
    final file = await api.getFile(kMetaPath);
    if (file == null) return null;
    if (readRepoSchema(file.content!) > kSupportedRepoSchema) {
      throw const RepoTooNewException();
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(file.content!));
    } catch (_) {
      json = null;
    }
    if (json is! Map) throw const FormatException('meta.json ist beschädigt');
    final params = CryptoParams.fromJson(json.cast<String, dynamic>());
    if (!params.isSupported) throw const RepoTooNewException();
    return params;
  }

  /// Initialisiert ein leeres Daten-Repo (meta.json + Schlüsselprobe).
  static Future<void> initializeRemote(GithubApi api, CryptoService crypto,
      SecretKey key, CryptoParams params, {required String app}) async {
    await api.putFile(
        kMetaPath,
        utf8.encode(const JsonEncoder.withIndent('  ')
            .convert({...params.toJson(), 'app': app, 'schema': 1})),
        'init: meta');
    await api.putFile(kKeyCheckPath,
        await crypto.encryptJson({'check': 'ok', 'app': app}, key),
        'init: keycheck');
  }

  /// Verifiziert die Passphrase gegen die Schlüsselprobe im Repo.
  static Future<bool> verifyKey(
      GithubApi api, CryptoService crypto, SecretKey key) async {
    var probe = await api.getFile(kKeyCheckPath);
    if (probe == null) {
      final tree = await api.getTree();
      final any = tree.files.keys.where((p) => p.endsWith('.enc')).firstOrNull;
      if (any == null) return true; // nichts zum Prüfen — frisches Repo
      probe = await api.getFile(any);
      if (probe == null) return true;
    }
    try {
      await crypto.decryptJson(probe.content!, key);
      return true;
    } on UnsupportedFormatException {
      throw const RepoTooNewException();
    } on DecryptionFailedException {
      return false;
    }
  }
}

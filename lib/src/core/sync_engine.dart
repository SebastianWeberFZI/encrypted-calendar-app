import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

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

  /// Beim Pull übersprungene, nicht entschlüsselbare Dateien.
  int skipped = 0;

  /// Dateien im Format einer neueren App-Version, die diese App noch nicht
  /// lesen kann (Stand nach dem Abgleich, nicht nur neu hinzugekommene).
  int newer = 0;
  final List<RemoteChange> changes = [];

  @override
  String toString() =>
      'gesendet: $pushed, empfangen: $pulled, Konflikte: $conflicts'
      '${skipped > 0 ? ', übersprungen: $skipped' : ''}';
}

/// Wird bei einem SHA-Konflikt mit der unterlegenen und der gewinnenden
/// Fassung aufgerufen (z. B. um eine Konfliktkopie anzulegen).
typedef ConflictHandler = Future<void> Function(
    String path, Map<String, dynamic> loser, Map<String, dynamic> winner);

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
  });

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
    try {
      final result = SyncResult();
      // Repo von einer neueren App umgestellt: nichts schreiben, nichts laden.
      // Nur meta.json wird (bei Änderung) erneut geprüft – ein Request.
      if (store.repoSchema > kSupportedRepoSchema) {
        await _checkMeta((await api.getTree()).files[kMetaPath]);
        if (store.repoSchema > kSupportedRepoSchema) {
          throw const RepoTooNewException();
        }
      }
      for (var round = 0; round < 3 && store.pending.isNotEmpty; round++) {
        await _push(result);
      }
      await _pull(result);
      store.lastSync = DateTime.now();
      await store.saveState();
      return result;
    } finally {
      await raf.unlock();
      await raf.close();
    }
  }

  // ---------------------------------------------------------------- Push

  Future<void> _push(SyncResult result) async {
    for (final op in List.of(store.pending)) {
      if (op.isDelete) {
        await _pushDelete(op, result);
      } else {
        await _pushUpsert(op, result);
      }
    }
  }

  Future<void> _pushUpsert(PendingOp op, SyncResult result) async {
    final doc = store.get(op.path);
    if (doc == null) {
      store.markSynced(op); // inzwischen gelöscht; Delete-Op folgt ggf.
      return;
    }
    final bytes = await crypto.encryptJson(doc, key);
    try {
      final newSha = await api.putFile(op.path, bytes, commitMessage,
          sha: store.remoteShas[op.path]);
      store.markSynced(op, newSha: newSha);
      result.pushed++;
    } on GithubApiException catch (e) {
      if (!e.isConflict) rethrow;
      await _resolveUpsertConflict(op, doc, bytes, result);
    }
    await store.saveState();
  }

  Future<void> _resolveUpsertConflict(PendingOp op, Map<String, dynamic> local,
      List<int> bytes, SyncResult result) async {
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
      return;
    } on DecryptionFailedException {
      // Unlesbare Remote-Fassung: mit der lokalen überschreiben.
      final newSha = await api.putFile(op.path, bytes, commitMessage,
          sha: remoteFile.sha);
      store.markSynced(op, newSha: newSha);
      result.pushed++;
      return;
    }
    result.conflicts++;
    if (docUpdatedAt(remote).isAfter(docUpdatedAt(local))) {
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
    } on GithubApiException catch (e) {
      if (!e.isConflict) rethrow;
      // Remote zwischenzeitlich geändert: Änderung schlägt Löschung.
      final remoteFile = await api.getFile(op.path);
      store.markSynced(op);
      if (remoteFile == null) return;
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
          store.remoteShas[e.key] = e.value;
          await store.put(e.key, doc, fromRemote: true, persistState: false);
          result.pulled++;
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

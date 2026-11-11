import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'crypto_service.dart';

/// Ausstehende, noch nicht synchronisierte Änderung an einem Dokument.
class PendingOp {
  PendingOp({required this.path, required this.isDelete, DateTime? at})
      : at = at ?? DateTime.now();

  /// Pfad im Daten-Repo, z. B. `events/<uuid>.enc`.
  final String path;
  final bool isDelete;
  final DateTime at;

  Map<String, dynamic> toJson() =>
      {'path': path, 'delete': isDelete, 'at': at.toIso8601String()};

  factory PendingOp.fromJson(Map<String, dynamic> json) => PendingOp(
        path: json['path'] as String,
        isDelete: json['delete'] as bool? ?? false,
        at: DateTime.parse(json['at'] as String),
      );
}

/// Lokaler, verschlüsselter Dokument-Store – Quelle der Wahrheit (Offline-First).
///
/// Jedes Dokument ist ein JSON-Objekt, adressiert über seinen Pfad im
/// Daten-Repo. Ablage auf dem Gerät ausschließlich verschlüsselt, im selben
/// Format wie im Repo:
///   `<base>/docs/<pfad mit __ statt />` – ein Dokument pro Datei
///   `<base>/state.enc`                 – Sync-Zustand (SHAs, Queue, letzter Sync)
class DocStore {
  DocStore({
    required this.baseDir,
    required this.crypto,
    required this.key,
  });

  final String baseDir;
  final CryptoService crypto;
  final SecretKey key;

  final Map<String, Map<String, dynamic>> _docs = {};
  final Map<String, String> remoteShas = {};
  final List<PendingOp> _pending = [];
  String? lastTreeSha;
  DateTime? lastSync;
  DateTime? _stateLoadedAt;
  Future<void> _stateWrite = Future.value();

  Map<String, Map<String, dynamic>> get docs => Map.unmodifiable(_docs);
  Map<String, dynamic>? get(String path) => _docs[path];

  /// Alle Dokumente unterhalb eines Verzeichnisses (z. B. `events`).
  Iterable<MapEntry<String, Map<String, dynamic>>> inDir(String dir) =>
      _docs.entries.where((e) => e.key.startsWith('$dir/'));

  List<PendingOp> get pending => List.unmodifiable(_pending);
  int get pendingCount => _pending.length;
  bool hasPendingFor(String path) => _pending.any((op) => op.path == path);

  Directory get _docDir => Directory('$baseDir/docs');
  File get _stateFile => File('$baseDir/state.enc');
  File _docFile(String path) =>
      File('$baseDir/docs/${path.replaceAll('/', '__')}');
  String _pathOf(File f) =>
      f.uri.pathSegments.last.replaceAll('__', '/');

  Future<void> init() async {
    await _docDir.create(recursive: true);
    _docs.clear();
    remoteShas.clear();
    _pending.clear();
    if (await _stateFile.exists()) {
      final state = await crypto.decryptJson(
          await _stateFile.readAsBytes(), key) as Map<String, dynamic>;
      remoteShas.addAll((state['remote_shas'] as Map<String, dynamic>? ?? {})
          .cast<String, String>());
      _pending.addAll((state['pending'] as List? ?? [])
          .map((p) => PendingOp.fromJson(p as Map<String, dynamic>)));
      lastTreeSha = state['last_tree_sha'] as String?;
      final ls = state['last_sync'] as String?;
      lastSync = ls == null ? null : DateTime.parse(ls);
      _stateLoadedAt = (await _stateFile.stat()).modified;
    }
    await for (final entity in _docDir.list()) {
      if (entity is! File || !entity.path.endsWith('.enc')) continue;
      try {
        final json = await crypto.decryptJson(await entity.readAsBytes(), key);
        _docs[_pathOf(entity)] = (json as Map).cast<String, dynamic>();
      } on DecryptionFailedException {
        continue; // Beschädigte Datei überspringen statt die App zu blockieren.
      } on FormatException {
        continue;
      }
    }
  }

  /// true, wenn ein anderer Prozess (Hintergrund-Sync) den Zustand seit dem
  /// Laden geändert hat – dann sollte neu geladen werden.
  Future<bool> changedOnDisk() async {
    if (!await _stateFile.exists()) return false;
    final m = (await _stateFile.stat()).modified;
    return _stateLoadedAt == null || m.isAfter(_stateLoadedAt!);
  }

  /// Speichert ein Dokument lokal. [fromRemote]=true beim Übernehmen von
  /// Remote-Ständen (erzeugt keinen Queue-Eintrag).
  Future<void> put(String path, Map<String, dynamic> data,
      {bool fromRemote = false, bool persistState = true}) async {
    _docs[path] = data;
    await _docFile(path).writeAsBytes(await crypto.encryptJson(data, key));
    if (!fromRemote) _enqueue(PendingOp(path: path, isDelete: false));
    if (persistState) await saveState();
  }

  Future<void> delete(String path,
      {bool fromRemote = false, bool persistState = true}) async {
    _docs.remove(path);
    final f = _docFile(path);
    if (await f.exists()) await f.delete();
    if (fromRemote) {
      remoteShas.remove(path);
      _pending.removeWhere((op) => op.path == path);
    } else {
      _enqueue(PendingOp(path: path, isDelete: true));
    }
    if (persistState) await saveState();
  }

  /// Pro Dokument maximal ein Queue-Eintrag; der jüngste gewinnt.
  void _enqueue(PendingOp op) {
    _pending.removeWhere((p) => p.path == op.path);
    // Löschung eines noch nie synchronisierten Dokuments: nichts zu tun.
    if (op.isDelete && !remoteShas.containsKey(op.path)) return;
    _pending.add(op);
  }

  void markSynced(PendingOp op, {String? newSha}) {
    _pending.remove(op);
    if (op.isDelete) {
      remoteShas.remove(op.path);
    } else if (newSha != null) {
      remoteShas[op.path] = newSha;
    }
  }

  /// Serialisierte Schreibvorgänge – parallele Aufrufe überholen sich nicht.
  Future<void> saveState() {
    _stateWrite = _stateWrite.then((_) async {
      final bytes = await crypto.encryptJson({
        'remote_shas': remoteShas,
        'pending': _pending.map((p) => p.toJson()).toList(),
        'last_tree_sha': lastTreeSha,
        'last_sync': lastSync?.toIso8601String(),
      }, key);
      final tmp = File('${_stateFile.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(_stateFile.path);
      _stateLoadedAt = (await _stateFile.stat()).modified;
    });
    return _stateWrite;
  }

  /// Löscht alle lokalen Daten dieser Datenquelle.
  Future<void> wipe() async {
    final dir = Directory(baseDir);
    if (await dir.exists()) await dir.delete(recursive: true);
    _docs.clear();
    remoteShas.clear();
    _pending.clear();
    lastTreeSha = null;
    lastSync = null;
  }
}

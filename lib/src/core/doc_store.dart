import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'crypto_service.dart';

/// Erhöhen, wenn eine neue App-Version Dokumente lesen kann, die frühere
/// Versionen nicht lesen konnten (z. B. neues Verschlüsselungsformat).
const int kReaderGeneration = 1;

/// Ausstehende, noch nicht synchronisierte Änderung an einem Dokument.
class PendingOp {
  PendingOp({required this.path, required this.isDelete, DateTime? at, List<String>? known})
      : at = at ?? DateTime.now(),
        known = known ?? const [];

  /// Pfad im Daten-Repo, z. B. `events/<uuid>.enc`.
  final String path;
  final bool isDelete;
  final DateTime at;

  /// Prüfsummen ([docHash]) der Fassungen, auf denen diese Änderung beruht:
  /// der zuletzt abgeglichene Stand und alle lokalen Zwischenstände seitdem.
  /// Findet der Abgleich remote eine davon vor, ist das kein Konflikt –
  /// nur die gespeicherte Version war veraltet (z. B. nach einem Abgleich
  /// im Hintergrund).
  final List<String> known;

  static const maxKnown = 20;

  Map<String, dynamic> toJson() => {
        'path': path,
        'delete': isDelete,
        'at': at.toIso8601String(),
        if (known.isNotEmpty) 'known': known,
      };

  /// null bei unbrauchbarem Eintrag (z. B. von einer anderen App-Version).
  static PendingOp? tryParse(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    if (path is! String || path.isEmpty) return null;
    final at = json['at'];
    final known = json['known'];
    return PendingOp(
      path: path,
      isDelete: json['delete'] == true,
      at: at is String ? DateTime.tryParse(at) : null,
      known: known is List ? known.whereType<String>().toList() : null,
    );
  }
}

/// JSON mit sortierten Schlüsseln – gleicher Inhalt ergibt denselben Text.
String canonicalJson(Object? v) {
  Object? norm(Object? x) => switch (x) {
        Map() => {
            for (final k in (x.keys.map((k) => '$k').toList()..sort())) k: norm(x[k]),
          },
        List() => [for (final e in x) norm(e)],
        _ => x,
      };
  return jsonEncode(norm(v));
}

/// Prüfsumme eines Dokuments (FNV-1a, 64 Bit, über [canonicalJson]).
String docHash(Map<String, dynamic> doc) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(canonicalJson(doc))) {
    h ^= b;
    h *= 0x100000001b3; // 64-Bit-Arithmetik läuft über, wie gewollt
  }
  return h.toUnsigned(64).toRadixString(16);
}

/// Gleicher Inhalt, wenn man vom Zeitstempel und vom Bearbeiter absieht?
bool sameDocContent(Map<String, dynamic> a, Map<String, dynamic> b) {
  Map<String, dynamic> strip(Map<String, dynamic> m) =>
      {for (final e in m.entries) if (e.key != 'updated_at' && e.key != 'updated_by') e.key: e.value};
  return canonicalJson(strip(a)) == canonicalJson(strip(b));
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

  /// Zeitpunkte (ms) der Schreibzugriffe der letzten Stunde – GitHub nimmt
  /// nur begrenzt viele neue Dateien pro Stunde an.
  final List<int> pushLog = [];

  /// Nach einer Drosselung durch GitHub erst ab hier wieder senden.
  DateTime? pushPausedUntil;

  /// SHA von meta.json beim letzten Prüfen und die dort angegebene
  /// Datenformat-Generation des Repos.
  String? metaSha;
  int repoSchema = 1;

  /// Remote-Dateien, die diese App-Version nicht lesen konnte (Pfad → SHA).
  /// Sie werden erst wieder geladen, wenn sich die Datei oder die App ändert –
  /// spart Datenvolumen und Akku.
  final Map<String, String> unreadable = {};

  /// Davon: Dateien im Format einer neueren App-Version (für den Hinweis
  /// "bitte aktualisieren").
  final Map<String, String> newer = {};

  /// Unbekannte Felder des Sync-Zustands (von einer anderen App-Version)
  /// bleiben beim Speichern erhalten.
  Map<String, dynamic> _stateExtra = {};
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

  /// Abgeglichene Fassung, auf der eine ausstehende lokale Änderung beruht
  /// (verschlüsselt, wie die Dokumente) – Grundlage, um beim Konflikt
  /// Änderungen an verschiedenen Feldern zusammenzuführen.
  Directory get _baseDir => Directory('$baseDir/base');
  File _baseFile(String path) =>
      File('$baseDir/base/${path.replaceAll('/', '__')}');

  void _dropBase(String path) {
    try {
      final f = _baseFile(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Die abgeglichene Fassung, auf der die ausstehende Änderung beruht;
  /// null, wenn unbekannt (z. B. neues Dokument).
  Future<Map<String, dynamic>?> baseOf(String path) async {
    try {
      final f = _baseFile(path);
      if (!await f.exists()) return null;
      return await crypto.decryptDoc(await f.readAsBytes(), key);
    } catch (_) {
      return null;
    }
  }

  Future<void> init() async {
    await _docDir.create(recursive: true);
    _docs.clear();
    remoteShas.clear();
    _pending.clear();
    unreadable.clear();
    newer.clear();
    _stateExtra = {};
    lastTreeSha = null;
    lastSync = null;
    metaSha = null;
    repoSchema = 1;
    pushLog.clear();
    pushPausedUntil = null;
    if (await _stateFile.exists()) {
      _stateLoadedAt = (await _stateFile.stat()).modified;
      try {
        _readState(await crypto.decryptDoc(await _stateFile.readAsBytes(), key));
      } catch (_) {
        // Unlesbarer Zustand: neu aufbauen. Der nächste Sync gleicht alles
        // über die SHAs wieder ab – lieber einmal mehr laden als abstürzen.
        remoteShas.clear();
        _pending.clear();
      }
    }
    if (await _baseDir.exists()) {
      final open = {for (final op in _pending) if (!op.isDelete) op.path};
      await for (final f in _baseDir.list()) {
        if (f is File && !open.contains(_pathOf(f))) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    }
    await for (final entity in _docDir.list()) {
      if (entity is! File || !entity.path.endsWith('.enc')) continue;
      try {
        _docs[_pathOf(entity)] =
            await crypto.decryptDoc(await entity.readAsBytes(), key);
      } catch (_) {
        continue; // Beschädigte Datei überspringen statt die App zu blockieren.
      }
    }
  }

  void _readState(Map<String, dynamic> state) {
    Map<String, String> strings(Object? v) => v is Map
        ? {
            for (final e in v.entries)
              if (e.key is String && e.value is String)
                e.key as String: e.value as String,
          }
        : {};
    remoteShas.addAll(strings(state['remote_shas']));
    final pending = state['pending'];
    if (pending is List) {
      _pending.addAll(pending.map(PendingOp.tryParse).whereType<PendingOp>());
    }
    final tree = state['last_tree_sha'];
    lastTreeSha = tree is String ? tree : null;
    final ls = state['last_sync'];
    lastSync = ls is String ? DateTime.tryParse(ls) : null;
    final pl = state['push_log'];
    if (pl is List) pushLog.addAll(pl.whereType<num>().map((n) => n.toInt()));
    final pu = state['push_paused_until'];
    pushPausedUntil = pu is String ? DateTime.tryParse(pu) : null;
    final ms = state['meta_sha'];
    metaSha = ms is String ? ms : null;
    final rs = state['repo_schema'];
    repoSchema = rs is num ? rs.toInt() : 1;
    // Nicht lesbare Dateien nur merken, solange dieselbe Leser-Generation
    // läuft – eine aktualisierte App versucht es erneut.
    if (state['reader'] == kReaderGeneration) {
      unreadable.addAll(strings(state['unreadable']));
      newer.addAll(strings(state['newer']));
    }
    _stateExtra = {
      for (final e in state.entries)
        if (!_stateKeys.contains(e.key)) e.key: e.value,
    };
  }

  static const _stateKeys = {
    'remote_shas', 'pending', 'last_tree_sha', 'last_sync', 'meta_sha',
    'repo_schema', 'unreadable', 'newer', 'reader', 'push_log', 'push_paused_until',
  };

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
    final before = _docs[path];
    final earlier = _pending.where((p) => p.path == path && !p.isDelete).firstOrNull;
    if (fromRemote) {
      _dropBase(path);
    } else if (earlier == null && before != null && !identical(before, data) && remoteShas.containsKey(path)) {
      // Erste lokale Änderung seit dem Abgleich: die Fassung sichern, die
      // dieser Prozess zuletzt abgeglichen hat und auf der die Änderung beruht.
      try {
        await _baseDir.create(recursive: true);
        await _baseFile(path).writeAsBytes(await crypto.encryptJson(before, key));
      } catch (_) {}
    }
    _docs[path] = data;
    await _docFile(path).writeAsBytes(await crypto.encryptJson(data, key));
    if (!fromRemote) {
      final known = [...?earlier?.known, if (before != null && !identical(before, data)) docHash(before)];
      _enqueue(PendingOp(
          path: path,
          isDelete: false,
          known: known.length > PendingOp.maxKnown ? known.sublist(known.length - PendingOp.maxKnown) : known));
    }
    if (persistState) await saveState();
  }

  Future<void> delete(String path,
      {bool fromRemote = false, bool persistState = true}) async {
    _docs.remove(path);
    _dropBase(path);
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
    if (!hasPendingFor(op.path)) _dropBase(op.path);
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
        ..._stateExtra,
        'remote_shas': remoteShas,
        'pending': _pending.map((p) => p.toJson()).toList(),
        'last_tree_sha': lastTreeSha,
        'last_sync': lastSync?.toIso8601String(),
        'meta_sha': metaSha,
        'repo_schema': repoSchema,
        'unreadable': unreadable,
        'newer': newer,
        'reader': kReaderGeneration,
        'push_log': pushLog,
        'push_paused_until': pushPausedUntil?.toIso8601String(),
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
    unreadable.clear();
    newer.clear();
    lastTreeSha = null;
    lastSync = null;
    metaSha = null;
    repoSchema = 1;
    pushLog.clear();
    pushPausedUntil = null;
  }
}

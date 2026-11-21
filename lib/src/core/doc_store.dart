import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'app_log.dart';
import 'crypto_service.dart';

/// Erhöhen, wenn eine neue App-Version Dokumente lesen kann, die frühere
/// Versionen nicht lesen konnten (z. B. neues Verschlüsselungsformat).
const int kReaderGeneration = 1;

/// Ausstehende, noch nicht synchronisierte Änderung an einem Dokument.
class PendingOp {
  PendingOp({
    required this.path,
    required this.isDelete,
    DateTime? at,
    List<String>? known,
    List<String>? files,
    this.baseSha,
  })  : at = at ?? DateTime.now(),
        known = known ?? const [],
        files = files ?? [];

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

  /// Einträge im Änderungs-Journal (`pending/`), die diese Änderung
  /// festhalten. Nach dem Senden werden genau diese gelöscht; legt ein
  /// anderer Prozess inzwischen einen neuen an, bleibt der stehen und wird
  /// beim nächsten Abgleich gesendet.
  final List<String> files;

  /// Remote-Version (SHA), auf der die Änderung beruht – damit prüft der
  /// Abgleich, ob remote inzwischen jemand anderes geändert hat. Leer: neues
  /// Dokument. null: unbekannt (Vormerkung einer älteren App-Version).
  final String? baseSha;

  static const maxKnown = 20;

  Map<String, dynamic> toJson() => {
        'path': path,
        'delete': isDelete,
        'at': at.toIso8601String(),
        if (known.isNotEmpty) 'known': known,
        if (baseSha != null) 'base': baseSha,
      };

  /// null bei unbrauchbarem Eintrag (z. B. von einer anderen App-Version).
  static PendingOp? tryParse(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    if (path is! String || path.isEmpty) return null;
    final at = json['at'];
    final known = json['known'];
    final base = json['base'];
    return PendingOp(
      path: path,
      isDelete: json['delete'] == true,
      at: at is String ? DateTime.tryParse(at) : null,
      known: known is List ? known.whereType<String>().toList() : null,
      baseSha: base is String ? base : null,
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
///   `<base>/pending/<pfad>~<id>.op`     – Journal: eine Datei je lokaler Änderung
///   `<base>/state.enc`                  – Sync-Zustand (SHAs, letzter Sync)
///
/// Mehrere Stores können gleichzeitig auf denselben Daten arbeiten (App,
/// Hintergrund-Abgleich, Widget – jeweils eigene Isolate mit eigenem
/// Speicher). Darum gilt:
/// - Jede lokale Änderung bekommt einen eigenen Journal-Eintrag; niemand
///   überschreibt die Vormerkungen eines anderen.
/// - Den Sync-Zustand schreibt nur der Abgleich, und zwar unter der
///   Sync-Sperre, nachdem er mit [refresh] den aktuellen Stand geladen hat.
/// - Dateien werden über eine Zwischendatei mit eigenem Namen geschrieben und
///   dann umbenannt – Leser sehen nie eine halb geschriebene Datei.
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

  /// Stand der Dokumentdateien beim letzten Lesen/Schreiben durch diesen
  /// Store (Änderungszeit und Größe) – so erkennt [refresh], was andere
  /// Prozesse geändert haben.
  final Map<String, String> _stamps = {};
  String? _stateStamp;

  final Map<String, String> remoteShas = {};
  final List<PendingOp> _pending = [];

  /// Bereits gelesene Journal-Einträge (Dateiname → Inhalt); sie ändern
  /// sich nach dem Anlegen nie mehr.
  final Map<String, PendingOp> _journalCache = {};

  String? lastTreeSha;
  DateTime? lastSync;

  /// SHA von meta.json beim letzten Prüfen und die dort angegebene
  /// Datenformat-Generation des Repos.
  String? metaSha;
  int repoSchema = 1;

  /// Zeitpunkte (ms) der Schreibzugriffe der letzten Stunde – GitHub nimmt
  /// nur begrenzt viele neue Dateien pro Stunde an.
  final List<int> pushLog = [];

  /// Nach einer Drosselung durch GitHub erst ab hier wieder senden.
  DateTime? pushPausedUntil;

  /// Welche Generation des Prüfabgleichs (alle Dokumente mit dem Repo
  /// vergleichen) schon gelaufen ist.
  int verified = 0;

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
  Future<void> _stateWrite = Future.value();

  Map<String, Map<String, dynamic>> get docs => Map.unmodifiable(_docs);
  Map<String, dynamic>? get(String path) => _docs[path];

  /// Alle Dokumente unterhalb eines Verzeichnisses (z. B. `events`).
  Iterable<MapEntry<String, Map<String, dynamic>>> inDir(String dir) =>
      _docs.entries.where((e) => e.key.startsWith('$dir/'));

  List<PendingOp> get pending => List.unmodifiable(_pending);
  int get pendingCount => _pending.length;
  bool hasPendingFor(String path) => _pending.any((op) => op.path == path);
  PendingOp? _opFor(String path) => _pending.where((op) => op.path == path).firstOrNull;

  /// Sperrdatei für den Abgleich (gegenseitiger Ausschluss, auch zwischen Isolaten).
  String get mutexPath => '$baseDir/sync.mutex';

  Directory get _docDir => Directory('$baseDir/docs');
  Directory get _journalDir => Directory('$baseDir/pending');
  File get _stateFile => File('$baseDir/state.enc');
  static String _escape(String path) => path.replaceAll('/', '__');
  File _docFile(String path) => File('$baseDir/docs/${_escape(path)}');
  File _journalFile(String name) => File('$baseDir/pending/$name');
  String _pathOf(File f) => f.uri.pathSegments.last.replaceAll('__', '/');

  /// Abgeglichene Fassung, auf der eine ausstehende lokale Änderung beruht
  /// (verschlüsselt, wie die Dokumente) – Grundlage, um beim Konflikt
  /// Änderungen an verschiedenen Feldern zusammenzuführen.
  Directory get _baseDir => Directory('$baseDir/base');
  File _baseFile(String path) => File('$baseDir/base/${_escape(path)}');

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

  // ------------------------------------------------------- Reihenfolge

  /// Lese- und Schreibvorgänge dieses Stores laufen nacheinander – sonst
  /// könnte ein [refresh] mitten in ein [put] fallen.
  Future<void> _serialTail = Future.value();
  Future<T> _serial<T>(Future<T> Function() body) {
    final run = _serialTail.then((_) => body());
    _serialTail = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Eigener Name für Zwischendateien: mehrere Stores (Isolate) dürfen sich
  /// die Datei nicht gegenseitig wegbenennen (sonst PathNotFoundException).
  final String _tmpTag = '${pid}_${Random().nextInt(1 << 32).toRadixString(36)}';
  int _seq = 0;

  Future<void> _writeAtomic(File f, List<int> bytes, {bool flush = false}) async {
    final tmp = File('${f.path}.$_tmpTag.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: flush);
      await tmp.rename(f.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  static Future<String?> _stampOf(File f) async {
    try {
      final st = await f.stat();
      if (st.type == FileSystemEntityType.notFound) return null;
      return '${st.modified.microsecondsSinceEpoch}/${st.size}';
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ Laden

  Future<void> init() => _serial(() async {
        await _docDir.create(recursive: true);
        await _journalDir.create(recursive: true);
        await _removeStaleTemps();
        _docs.clear();
        _stamps.clear();
        _pending.clear();
        _journalCache.clear();
        final legacy = await _loadState();
        await for (final entity in _docDir.list()) {
          if (entity is! File || !entity.path.endsWith('.enc')) continue;
          try {
            final stamp = await _stampOf(entity);
            _docs[_pathOf(entity)] = await crypto.decryptDoc(await entity.readAsBytes(), key);
            if (stamp != null) _stamps[_pathOf(entity)] = stamp;
          } catch (_) {
            continue; // Beschädigte Datei überspringen statt die App zu blockieren.
          }
        }
        await _loadJournal();
        if (legacy.isNotEmpty) await _migrateLegacy(legacy);
        if (await _baseDir.exists()) {
          final open = {for (final op in _pending) if (!op.isDelete) op.path};
          await for (final f in _baseDir.list()) {
            if (f is File && !f.path.endsWith('.tmp') && !open.contains(_pathOf(f))) {
              try {
                await f.delete();
              } catch (_) {}
            }
          }
        }
      });

  /// Liegengebliebene Zwischendateien abgebrochener Schreibvorgänge.
  Future<void> _removeStaleTemps() async {
    for (final dir in [Directory(baseDir), _docDir, _journalDir, _baseDir]) {
      try {
        if (!await dir.exists()) continue;
        await for (final f in dir.list()) {
          if (f is File &&
              f.path.endsWith('.tmp') &&
              DateTime.now().difference((await f.stat()).modified) > const Duration(minutes: 10)) {
            await f.delete();
          }
        }
      } catch (_) {}
    }
  }

  /// Ältere App-Versionen hielten die Vormerkungen im Sync-Zustand: ins
  /// Journal übernehmen (doppelte Einträge schaden nicht, sie werden je
  /// Dokument zusammengefasst).
  Future<void> _migrateLegacy(List<PendingOp> legacy) async {
    for (final op in legacy) {
      if (hasPendingFor(op.path)) continue;
      await _journal(op);
    }
    AppLog.info('speicher', '${legacy.length} vorgemerkte Änderungen ins Journal übernommen');
  }

  /// Liest den Sync-Zustand von der Platte. Liefert Vormerkungen im alten
  /// Format (aus dem Zustand), falls vorhanden.
  Future<List<PendingOp>> _loadState() async {
    remoteShas.clear();
    unreadable.clear();
    newer.clear();
    _stateExtra = {};
    lastTreeSha = null;
    lastSync = null;
    metaSha = null;
    repoSchema = 1;
    verified = 0;
    pushLog.clear();
    pushPausedUntil = null;
    _stateStamp = await _stampOf(_stateFile);
    if (_stateStamp == null) return const [];
    try {
      return _readState(await crypto.decryptDoc(await _stateFile.readAsBytes(), key));
    } catch (_) {
      // Unlesbarer Zustand: neu aufbauen. Der nächste Sync gleicht alles
      // über die SHAs wieder ab – lieber einmal mehr laden als abstürzen.
      remoteShas.clear();
      return const [];
    }
  }

  List<PendingOp> _readState(Map<String, dynamic> state) {
    Map<String, String> strings(Object? v) => v is Map
        ? {
            for (final e in v.entries)
              if (e.key is String && e.value is String)
                e.key as String: e.value as String,
          }
        : {};
    remoteShas.addAll(strings(state['remote_shas']));
    final tree = state['last_tree_sha'];
    lastTreeSha = tree is String ? tree : null;
    final ls = state['last_sync'];
    lastSync = ls is String ? DateTime.tryParse(ls) : null;
    final ms = state['meta_sha'];
    metaSha = ms is String ? ms : null;
    final rs = state['repo_schema'];
    repoSchema = rs is num ? rs.toInt() : 1;
    final ve = state['verified'];
    verified = ve is num ? ve.toInt() : 0;
    // Nicht lesbare Dateien nur merken, solange dieselbe Leser-Generation
    // läuft – eine aktualisierte App versucht es erneut.
    if (state['reader'] == kReaderGeneration) {
      unreadable.addAll(strings(state['unreadable']));
      newer.addAll(strings(state['newer']));
    }
    final pl = state['push_log'];
    if (pl is List) pushLog.addAll(pl.whereType<num>().map((n) => n.toInt()));
    final pu = state['push_paused_until'];
    pushPausedUntil = pu is String ? DateTime.tryParse(pu) : null;
    _stateExtra = {
      for (final e in state.entries)
        if (!_stateKeys.contains(e.key)) e.key: e.value,
    };
    final pending = state['pending'];
    return pending is List ? pending.map(PendingOp.tryParse).whereType<PendingOp>().toList() : const [];
  }

  static const _stateKeys = {
    'remote_shas', 'pending', 'last_tree_sha', 'last_sync', 'meta_sha',
    'repo_schema', 'unreadable', 'newer', 'reader', 'verified', 'push_log', 'push_paused_until',
  };

  /// Liest das Journal und fasst die Einträge je Dokument zusammen: der
  /// jüngste bestimmt die Art (Ändern/Löschen), die bekannten Stände aller
  /// zählen. Liefert true, wenn sich gegenüber dem Speicher etwas geändert hat.
  Future<bool> _loadJournal() async {
    final names = <String>[];
    try {
      await for (final f in _journalDir.list()) {
        final name = f.uri.pathSegments.last;
        if (f is File && name.endsWith('.op')) names.add(name);
      }
    } on PathNotFoundException {
      // Noch kein Journal.
    }
    final before = {for (final op in _pending) ...op.files};
    if (before.length == names.length && names.every(before.contains)) return false;
    final byPath = <String, List<PendingOp>>{};
    for (final name in names) {
      var op = _journalCache[name];
      if (op == null) {
        try {
          op = PendingOp.tryParse(await crypto.decryptDoc(await _journalFile(name).readAsBytes(), key));
        } catch (e) {
          AppLog.warn('speicher', 'Journal-Eintrag $name unlesbar: $e');
        }
        if (op == null) continue;
        _journalCache[name] = op;
      }
      (byPath[op.path] ??= []).add(PendingOp(
          path: op.path, isDelete: op.isDelete, at: op.at, known: op.known, files: [name], baseSha: op.baseSha));
    }
    _journalCache.removeWhere((name, _) => !names.contains(name));
    _pending
      ..clear()
      ..addAll(byPath.values.map((ops) {
        ops.sort((a, b) => a.at.compareTo(b.at));
        final known = <String>{
          for (final op in ops) ...op.known,
        }.toList();
        return PendingOp(
          path: ops.last.path,
          isDelete: ops.last.isDelete,
          at: ops.last.at,
          known: known.length > PendingOp.maxKnown ? known.sublist(known.length - PendingOp.maxKnown) : known,
          files: [for (final op in ops) ...op.files],
          // Die älteste Änderung bestimmt, worauf alles beruht.
          baseSha: ops.first.baseSha,
        );
      }));
    _pending.sort((a, b) => a.at.compareTo(b.at));
    return true;
  }

  /// Gleicht den Speicher mit der Platte ab, wenn ein anderer Store (App,
  /// Hintergrund-Abgleich, Widget) inzwischen etwas geschrieben hat:
  /// Sync-Zustand, geänderte oder gelöschte Dokumente, neue Vormerkungen.
  /// Liefert true, wenn sich dabei etwas geändert hat.
  Future<bool> refresh() => _serial(() async {
        var changed = false;
        // Eigenen, noch laufenden Schreibvorgang abwarten – sonst sähe er wie
        // eine fremde Änderung aus.
        await _stateWrite.then((_) {}, onError: (_) {});
        if (await _stampOf(_stateFile) != _stateStamp) {
          final legacy = await _loadState();
          if (legacy.isNotEmpty) await _migrateLegacy(legacy);
          changed = true;
        }
        final seen = <String>{};
        try {
          await for (final e in _docDir.list()) {
            if (e is! File || !e.path.endsWith('.enc')) continue;
            final path = _pathOf(e);
            seen.add(path);
            final stamp = await _stampOf(e);
            if (stamp == null || stamp == _stamps[path]) continue;
            try {
              _docs[path] = await crypto.decryptDoc(await e.readAsBytes(), key);
              _stamps[path] = stamp;
              changed = true;
            } catch (_) {
              // Unlesbar: die bisherige Fassung behalten, beim nächsten Mal erneut.
            }
          }
        } on PathNotFoundException {
          // Noch keine Dokumente.
        }
        for (final path in _docs.keys.where((p) => !seen.contains(p)).toList()) {
          _docs.remove(path);
          _stamps.remove(path);
          changed = true;
        }
        if (await _loadJournal()) changed = true;
        return changed;
      });

  /// Übernimmt einen Remote-Stand – aber nur, wenn lokal nichts dagegen
  /// spricht: keine eigene Vormerkung und keine Änderung eines anderen
  /// Stores seit dem letzten Laden (die wird beim nächsten Abgleich gesendet).
  /// Liefert false, wenn nichts übernommen wurde.
  Future<bool> adoptRemote(String path, Map<String, dynamic> doc, String sha) => _serial(() async {
        if (hasPendingFor(path) || await touchedElsewhere(path)) return false;
        remoteShas[path] = sha;
        _dropBase(path);
        _docs[path] = doc;
        final f = _docFile(path);
        await _writeAtomic(f, await crypto.encryptJson(doc, key));
        final stamp = await _stampOf(f);
        if (stamp != null) _stamps[path] = stamp;
        return true;
      });

  /// Entfernt ein remote gelöschtes Dokument – unter denselben Bedingungen
  /// wie [adoptRemote].
  Future<bool> removeRemote(String path) => _serial(() async {
        if (hasPendingFor(path) || await touchedElsewhere(path)) return false;
        remoteShas.remove(path);
        _docs.remove(path);
        _stamps.remove(path);
        _dropBase(path);
        try {
          await _docFile(path).delete();
        } on PathNotFoundException {
          // Schon weg.
        }
        return true;
      });

  /// true, wenn ein anderer Store das Dokument seit dem letzten Laden
  /// geändert oder eine Änderung daran vorgemerkt hat – dann darf der
  /// Abgleich es nicht mit dem Remote-Stand überschreiben.
  Future<bool> touchedElsewhere(String path) async {
    if (await _stampOf(_docFile(path)) != _stamps[path]) return true;
    final prefix = '${_escape(path)}~';
    final mine = {...?_opFor(path)?.files};
    try {
      await for (final f in _journalDir.list()) {
        final name = f.uri.pathSegments.last;
        if (name.startsWith(prefix) && name.endsWith('.op') && !mine.contains(name)) return true;
      }
    } on PathNotFoundException {
      return false;
    }
    return false;
  }

  // ---------------------------------------------------------- Schreiben

  /// Speichert ein Dokument lokal. [fromRemote]=true beim Übernehmen von
  /// Remote-Ständen (erzeugt keine Vormerkung).
  Future<void> put(String path, Map<String, dynamic> data, {bool fromRemote = false}) => _serial(() async {
        final before = _docs[path];
        final earlier = _opFor(path);
        if (fromRemote) {
          _dropBase(path);
        } else if (earlier == null && before != null && !identical(before, data) && remoteShas.containsKey(path)) {
          // Erste lokale Änderung seit dem Abgleich: die Fassung sichern, die
          // dieser Store zuletzt abgeglichen hat und auf der die Änderung beruht.
          try {
            await _baseDir.create(recursive: true);
            await _writeAtomic(_baseFile(path), await crypto.encryptJson(before, key));
          } catch (_) {}
        }
        _docs[path] = data;
        final f = _docFile(path);
        await _writeAtomic(f, await crypto.encryptJson(data, key));
        final stamp = await _stampOf(f);
        if (stamp != null) _stamps[path] = stamp;
        if (!fromRemote) {
          final known = [
            if (earlier != null && !earlier.isDelete) ...earlier.known,
            if (before != null && !identical(before, data)) docHash(before),
          ];
          await _journal(PendingOp(
              path: path,
              isDelete: false,
              known: known.length > PendingOp.maxKnown ? known.sublist(known.length - PendingOp.maxKnown) : known,
              files: [...?earlier?.files],
              baseSha: _baseShaFor(path, earlier)));
        }
      });

  Future<void> delete(String path, {bool fromRemote = false}) => _serial(() async {
        final earlier = _opFor(path);
        final before = _docs[path];
        _docs.remove(path);
        _stamps.remove(path);
        _dropBase(path);
        try {
          await _docFile(path).delete();
        } on PathNotFoundException {
          // Schon weg (z. B. von einem anderen Store gelöscht).
        }
        if (fromRemote) {
          remoteShas.remove(path);
        } else {
          // Auch bei noch nie gesendeten Dokumenten vormerken: ob remote etwas
          // zu löschen ist, entscheidet der Abgleich mit frischem Stand.
          await _journal(PendingOp(
              path: path,
              isDelete: true,
              known: [
                if (earlier != null && !earlier.isDelete) ...earlier.known,
                if (before != null) docHash(before),
              ],
              files: [...?earlier?.files],
              baseSha: _baseShaFor(path, earlier)));
        }
      });

  /// Vermerkt eine lokale Änderung, ohne das Dokument neu zu schreiben (z. B.
  /// wenn der Prüfabgleich eine nie gesendete Änderung findet).
  Future<void> requeue(String path) => _serial(() async {
        if (_docs[path] == null) return;
        final earlier = _opFor(path);
        await _journal(PendingOp(
            path: path,
            isDelete: false,
            known: earlier?.known,
            files: [...?earlier?.files],
            baseSha: _baseShaFor(path, earlier)));
      });

  /// Worauf eine neue Änderung beruht: dasselbe wie eine noch offene frühere
  /// Änderung, sonst der Remote-Stand, den dieser Store kennt.
  String? _baseShaFor(String path, PendingOp? earlier) =>
      earlier != null ? earlier.baseSha : (remoteShas[path] ?? '');

  /// Legt den Journal-Eintrag an und ersetzt im Speicher eine frühere
  /// Vormerkung desselben Dokuments (deren Einträge übernimmt [op]).
  Future<void> _journal(PendingOp op) async {
    final name = '${_escape(op.path)}~${op.at.microsecondsSinceEpoch}_$_tmpTag${_seq++}.op';
    await _journalDir.create(recursive: true);
    await _writeAtomic(_journalFile(name), await crypto.encryptJson(op.toJson(), key), flush: true);
    _journalCache[name] = op;
    op.files.add(name);
    _pending.removeWhere((p) => p.path == op.path);
    _pending.add(op);
  }

  /// Nach erfolgreichem Senden: genau die Journal-Einträge dieser Änderung
  /// entfernen – neuere eines anderen Stores bleiben stehen.
  void markSynced(PendingOp op, {String? newSha}) {
    _pending.remove(op);
    for (final name in op.files) {
      try {
        _journalFile(name).deleteSync();
      } catch (_) {}
      _journalCache.remove(name);
    }
    if (!hasPendingFor(op.path)) _dropBase(op.path);
    if (op.isDelete) {
      remoteShas.remove(op.path);
    } else if (newSha != null) {
      remoteShas[op.path] = newSha;
    }
  }

  /// Serialisierte Schreibvorgänge – parallele Aufrufe überholen sich nicht.
  /// Ein fehlgeschlagener Schreibvorgang blockiert die folgenden nicht –
  /// sonst scheiterte jeder weitere Abgleich bis zum Neustart der App.
  /// Nur der Abgleich (unter der Sync-Sperre) ruft das auf.
  Future<void> saveState() {
    final next = _stateWrite.then((_) {}, onError: (_) {}).then((_) => _writeState());
    _stateWrite = next;
    return next;
  }

  Future<void> _writeState() async {
    final bytes = await crypto.encryptJson({
      ..._stateExtra,
      'remote_shas': remoteShas,
      'last_tree_sha': lastTreeSha,
      'last_sync': lastSync?.toIso8601String(),
      'meta_sha': metaSha,
      'repo_schema': repoSchema,
      'unreadable': unreadable,
      'newer': newer,
      'reader': kReaderGeneration,
      'verified': verified,
      'push_log': pushLog,
      'push_paused_until': pushPausedUntil?.toIso8601String(),
    }, key);
    try {
      await _stateFile.parent.create(recursive: true);
      await _writeAtomic(_stateFile, bytes, flush: true);
      _stateStamp = await _stampOf(_stateFile);
    } catch (e) {
      AppLog.error('speicher', 'Sync-Zustand nicht gespeichert', e);
      rethrow;
    }
  }

  /// Löscht alle lokalen Daten dieser Datenquelle.
  Future<void> wipe() => _serial(() async {
        final dir = Directory(baseDir);
        if (await dir.exists()) await dir.delete(recursive: true);
        _docs.clear();
        _stamps.clear();
        _stateStamp = null;
        remoteShas.clear();
        _pending.clear();
        _journalCache.clear();
        unreadable.clear();
        newer.clear();
        lastTreeSha = null;
        lastSync = null;
        metaSha = null;
        repoSchema = 1;
        verified = 0;
        pushLog.clear();
        pushPausedUntil = null;
      });
}

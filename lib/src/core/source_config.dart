import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'crypto_service.dart';
import 'github_api.dart';
import 'werkstatt.dart';

/// Zugangsdaten einer Datenquelle (= ein privates Daten-Repo).
/// Sicher abgelegt via flutter_secure_storage (Android Keystore).
class SourceConfig {
  SourceConfig({
    required this.id,
    required this.label,
    required this.owner,
    required this.repo,
    this.branch = 'main',
    required this.token,
    this.apiBase = kGithubApiBase,
    required this.masterKeyB64,
    required this.cryptoParams,
    this.rememberKey = true,
    Map<String, dynamic>? extra,
  }) : extra = extra ?? {};

  /// Lokale ID (Ordnername der lokalen Kopie).
  final String id;

  /// Anzeigename, z. B. "Gemeinsam" oder "Privat".
  String label;
  String owner;
  String repo;
  String branch;
  String token;
  String apiBase;

  /// Abgeleiteter Master-Key (Base64). Leer, wenn rememberKey=false.
  String masterKeyB64;
  final CryptoParams cryptoParams;
  bool rememberKey;

  /// Felder einer anderen App-Version – bleiben beim Speichern erhalten.
  final Map<String, dynamic> extra;

  GithubConfig get github => GithubConfig(
      owner: owner, repo: repo, branch: branch, token: token, apiBase: apiBase);

  bool get isMock => apiBase != kGithubApiBase;

  Map<String, dynamic> toJson() => {
        ...extra,
        'id': id,
        'label': label,
        'owner': owner,
        'repo': repo,
        'branch': branch,
        'token': token,
        'api_base': apiBase,
        'master_key': rememberKey ? masterKeyB64 : '',
        'crypto_params': cryptoParams.toJson(),
        'remember_key': rememberKey,
      };

  static const _known = {
    'id', 'label', 'owner', 'repo', 'branch', 'token', 'api_base',
    'master_key', 'crypto_params', 'remember_key',
  };

  /// Wirft bei fehlenden Pflichtfeldern (id, owner, repo, Schlüsselparameter).
  factory SourceConfig.fromJson(Map<String, dynamic> j) {
    String? str(String k) => j[k] is String ? j[k] as String : null;
    final params = j['crypto_params'];
    return SourceConfig(
      id: str('id')!,
      label: str('label') ?? str('repo')!,
      owner: str('owner')!,
      repo: str('repo')!,
      branch: str('branch') ?? 'main',
      token: str('token') ?? '',
      apiBase: str('api_base') ?? kGithubApiBase,
      masterKeyB64: str('master_key') ?? '',
      cryptoParams:
          CryptoParams.fromJson((params as Map).cast<String, dynamic>()),
      rememberKey: j['remember_key'] is bool ? j['remember_key'] as bool : true,
      extra: {
        for (final e in j.entries)
          if (!_known.contains(e.key)) e.key: e.value,
      },
    );
  }
}

/// Persistiert die Liste der Datenquellen im Keystore.
///
/// In der Linux-Vorschau der Werkstatt (kein Schlüsselbund im Container)
/// stattdessen in einer Datei im App-Verzeichnis – nur dort.
class SourceConfigStore {
  SourceConfigStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _kSources = 'sources_v1';

  bool get _useFile => kDesktopPreview;

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/werkstatt-secrets.json');

  Future<Map<String, String>> _readFile() async {
    final f = await _file();
    if (!await f.exists()) return {};
    return (jsonDecode(await f.readAsString()) as Map).cast<String, String>();
  }

  Future<String?> _read(String key) async =>
      _useFile ? (await _readFile())[key] : _storage.read(key: key);

  Future<void> _write(String key, String? value) async {
    if (!_useFile) {
      return value == null ? _storage.delete(key: key) : _storage.write(key: key, value: value);
    }
    final m = await _readFile();
    if (value == null) {
      m.remove(key);
    } else {
      m[key] = value;
    }
    final f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(m));
  }

  /// Einträge, die diese App-Version nicht versteht (z. B. nach einem
  /// Downgrade). Sie werden nicht angezeigt, aber auch nicht gelöscht.
  final List<Object?> _unreadable = [];

  Future<List<SourceConfig>> load() async {
    _unreadable.clear();
    final raw = await _read(_kSources);
    if (raw == null || raw.isEmpty) return [];
    Object? list;
    try {
      list = jsonDecode(raw);
    } on FormatException {
      return [];
    }
    if (list is! List) return [];
    final out = <SourceConfig>[];
    for (final e in list) {
      try {
        out.add(SourceConfig.fromJson((e as Map).cast<String, dynamic>()));
      } catch (_) {
        _unreadable.add(e);
      }
    }
    return out;
  }

  Future<void> save(List<SourceConfig> sources) => _write(
      _kSources,
      jsonEncode([
        ...sources.map((s) => s.toJson()),
        ..._unreadable.where((u) => !(u is Map &&
            sources.any((s) => s.id == u['id']))),
      ]));

  /// Beliebige weitere Geheimnisse (z. B. SMTP-Passwort).
  Future<String?> readSecret(String key) => _read('secret_$key');
  Future<void> writeSecret(String key, String? value) => _write('secret_$key', value);

  Future<void> clear() async {
    if (_useFile) {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } else {
      await _storage.deleteAll();
    }
  }
}

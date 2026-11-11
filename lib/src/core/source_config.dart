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
  });

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

  GithubConfig get github => GithubConfig(
      owner: owner, repo: repo, branch: branch, token: token, apiBase: apiBase);

  bool get isMock => apiBase != kGithubApiBase;

  Map<String, dynamic> toJson() => {
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

  factory SourceConfig.fromJson(Map<String, dynamic> j) => SourceConfig(
        id: j['id'] as String,
        label: j['label'] as String? ?? j['repo'] as String,
        owner: j['owner'] as String,
        repo: j['repo'] as String,
        branch: j['branch'] as String? ?? 'main',
        token: j['token'] as String,
        apiBase: j['api_base'] as String? ?? kGithubApiBase,
        masterKeyB64: j['master_key'] as String? ?? '',
        cryptoParams: CryptoParams.fromJson(
            (j['crypto_params'] as Map).cast<String, dynamic>()),
        rememberKey: j['remember_key'] as bool? ?? true,
      );
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

  Future<List<SourceConfig>> load() async {
    final raw = await _read(_kSources);
    if (raw == null || raw.isEmpty) return [];
    return (jsonDecode(raw) as List)
        .map((e) => SourceConfig.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<void> save(List<SourceConfig> sources) =>
      _write(_kSources, jsonEncode(sources.map((s) => s.toJson()).toList()));

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

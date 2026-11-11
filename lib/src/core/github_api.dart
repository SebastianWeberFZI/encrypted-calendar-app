import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Standard-Endpunkt; in der Werkstatt zeigt die App auf den Mock-Server.
const String kGithubApiBase = 'https://api.github.com';

class GithubConfig {
  const GithubConfig({
    required this.owner,
    required this.repo,
    this.branch = 'main',
    required this.token,
    this.apiBase = kGithubApiBase,
  });

  final String owner;
  final String repo;
  final String branch;
  final String token;
  final String apiBase;
}

class RemoteFile {
  const RemoteFile({required this.path, required this.sha, this.content});
  final String path;
  final String sha;
  final Uint8List? content;
}

/// Stand des Repos: Pfad -> Blob-SHA aller Dateien + Baum-SHA.
class RepoTree {
  const RepoTree({required this.sha, required this.files});
  final String sha;
  final Map<String, String> files;

  static const empty = RepoTree(sha: '', files: {});
}

class GithubApiException implements Exception {
  const GithubApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  bool get isNotFound => statusCode == 404;
  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  /// SHA-Konflikt: Datei wurde zwischenzeitlich remote geändert.
  bool get isConflict => statusCode == 409 || statusCode == 422;

  @override
  String toString() => 'GitHub-API-Fehler $statusCode: $message';
}

/// Dünner Client für die GitHub-REST-API – genügt als komplettes
/// "Datenbank-Protokoll": Baum lesen, Blobs laden, Dateien schreiben/löschen.
class GithubApi {
  GithubApi(this.config, {http.Client? client})
      : _client = client ?? http.Client();

  final GithubConfig config;
  final http.Client _client;
  static const _timeout = Duration(seconds: 25);

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${config.token}',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = config.apiBase.endsWith('/')
        ? config.apiBase.substring(0, config.apiBase.length - 1)
        : config.apiBase;
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  String get _repoPath => '/repos/${config.owner}/${config.repo}';

  Uri _contentsUri(String path, [Map<String, String>? query]) =>
      _uri('$_repoPath/contents/$path', query);

  Future<http.Response> _get(Uri uri, {Map<String, String>? extra}) =>
      _client.get(uri, headers: {..._headers, ...?extra}).timeout(_timeout);

  /// Prüft Token und Repo-Zugriff; wirft bei Fehlern.
  Future<void> testConnection() async {
    final res = await _get(_uri(_repoPath));
    if (res.statusCode != 200) {
      throw GithubApiException(res.statusCode, _errorMessage(res));
    }
  }

  /// Alle Dateien des Branches mit ihren Blob-SHAs in einem Request.
  /// Leeres Repo -> [RepoTree.empty].
  Future<RepoTree> getTree() async {
    final res = await _get(
        _uri('$_repoPath/git/trees/${config.branch}', {'recursive': '1'}));
    if (res.statusCode == 404 || res.statusCode == 409) return RepoTree.empty;
    if (res.statusCode != 200) {
      throw GithubApiException(res.statusCode, _errorMessage(res));
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final files = <String, String>{
      for (final e in (json['tree'] as List).cast<Map<String, dynamic>>())
        if (e['type'] == 'blob') e['path'] as String: e['sha'] as String,
    };
    return RepoTree(sha: json['sha'] as String? ?? '', files: files);
  }

  /// Lädt eine Datei; null bei 404.
  ///
  /// Der Inhalt kommt über die Git-Blobs-API, NICHT aus dem content-Feld der
  /// Contents-API: Letztere transkodiert vermeintliches UTF-16 – zufällige
  /// Ciphertext-Bytes können so verfälscht ankommen (Lehre aus der TODO-App).
  Future<RemoteFile?> getFile(String path) async {
    final res = await _get(_contentsUri(path, {'ref': config.branch}));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw GithubApiException(res.statusCode, _errorMessage(res));
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final sha = json['sha'] as String;
    return RemoteFile(path: path, sha: sha, content: await getBlob(sha));
  }

  Future<Uint8List> getBlob(String sha) async {
    final res = await _get(_uri('$_repoPath/git/blobs/$sha'));
    if (res.statusCode != 200) {
      throw GithubApiException(res.statusCode, _errorMessage(res));
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return base64Decode(
        (json['content'] as String? ?? '').replaceAll(RegExp(r'\s'), ''));
  }

  /// Legt eine Datei an oder aktualisiert sie. [sha] ist beim Aktualisieren
  /// Pflicht (optimistische Sperre). Liefert den neuen Blob-SHA.
  Future<String> putFile(String path, List<int> content, String message,
      {String? sha}) async {
    final res = await _client
        .put(
          _contentsUri(path),
          headers: _headers,
          body: jsonEncode({
            'message': message,
            'content': base64Encode(content),
            'branch': config.branch,
            'sha': ?sha,
          }),
        )
        .timeout(_timeout);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw GithubApiException(res.statusCode, _errorMessage(res));
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return (json['content'] as Map<String, dynamic>)['sha'] as String;
  }

  Future<void> deleteFile(String path, String sha, String message) async {
    final res = await _client
        .delete(
          _contentsUri(path),
          headers: _headers,
          body: jsonEncode({
            'message': message,
            'sha': sha,
            'branch': config.branch,
          }),
        )
        .timeout(_timeout);
    if (res.statusCode == 404) return; // schon weg — Ziel erreicht
    if (res.statusCode != 200) {
      throw GithubApiException(res.statusCode, _errorMessage(res));
    }
  }

  String _errorMessage(http.Response res) {
    try {
      return (jsonDecode(res.body) as Map<String, dynamic>)['message']
              as String? ??
          res.body;
    } catch (_) {
      return res.body;
    }
  }
}

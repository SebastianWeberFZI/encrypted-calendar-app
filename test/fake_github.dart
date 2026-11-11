import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Minimaler In-Memory-Nachbau der benutzten GitHub-Endpunkte (für Tests).
class FakeGithub {
  final Map<String, Uint8List> files = {};
  final Map<String, Uint8List> blobs = {};
  int writes = 0;

  static String blobSha(List<int> data) =>
      sha1.convert([...utf8.encode('blob ${data.length}\u0000'), ...data]).toString();

  http.Client client() => MockClient((req) async {
        final path = req.url.path;
        final m = RegExp(r'^/repos/[^/]+/[^/]+(.*)$').firstMatch(path);
        if (m == null) return _json(404, {'message': 'Not Found'});
        final rest = m.group(1)!;
        if (rest.isEmpty) return _json(200, {'name': 'repo'});
        if (rest.startsWith('/git/trees/')) {
          if (files.isEmpty) return _json(409, {'message': 'Git Repository is empty.'});
          final tree = [
            for (final e in files.entries)
              {'path': e.key, 'type': 'blob', 'sha': blobSha(e.value)}
          ];
          return _json(200, {'sha': blobSha(utf8.encode(jsonEncode(tree))), 'tree': tree});
        }
        if (rest.startsWith('/git/blobs/')) {
          final sha = rest.substring('/git/blobs/'.length);
          final b = blobs[sha];
          if (b == null) return _json(404, {'message': 'Not Found'});
          return _json(200, {'sha': sha, 'content': base64Encode(b)});
        }
        if (rest.startsWith('/contents/')) {
          final p = rest.substring('/contents/'.length);
          final cur = files[p];
          switch (req.method) {
            case 'GET':
              if (cur == null) return _json(404, {'message': 'Not Found'});
              return _json(200, {'type': 'file', 'path': p, 'sha': blobSha(cur)});
            case 'PUT':
              final body = jsonDecode(req.body) as Map<String, dynamic>;
              final given = body['sha'] as String?;
              if (cur != null && given == null) return _json(422, {'message': 'sha missing'});
              if (cur != null && given != blobSha(cur)) return _json(409, {'message': 'conflict'});
              if (cur == null && given != null) return _json(409, {'message': 'conflict'});
              final data = base64Decode(body['content'] as String);
              files[p] = data;
              blobs[blobSha(data)] = data;
              writes++;
              return _json(cur == null ? 201 : 200, {
                'content': {'path': p, 'sha': blobSha(data)}
              });
            case 'DELETE':
              if (cur == null) return _json(404, {'message': 'Not Found'});
              final body = jsonDecode(req.body) as Map<String, dynamic>;
              if (body['sha'] != blobSha(cur)) return _json(409, {'message': 'conflict'});
              files.remove(p);
              writes++;
              return _json(200, {'content': null});
          }
        }
        return _json(404, {'message': 'Not Found'});
      });

  http.Response _json(int status, Object body) => http.Response(jsonEncode(body), status,
      headers: {'content-type': 'application/json'});
}

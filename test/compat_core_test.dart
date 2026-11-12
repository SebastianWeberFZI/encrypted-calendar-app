import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:encrypted_calendar_app/src/core/crypto_service.dart';
import 'package:encrypted_calendar_app/src/core/doc_store.dart';
import 'package:encrypted_calendar_app/src/core/github_api.dart';
import 'package:encrypted_calendar_app/src/core/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_github.dart';

/// Kompatibilität: Daten älterer und neuerer App-Versionen dürfen die App
/// weder zum Absturz bringen noch beim Speichern verloren gehen.
void main() {
  final crypto = CryptoService();
  late SecretKey key;
  late Directory tmp;
  late FakeGithub gh;

  setUpAll(() async {
    key = await crypto.deriveKey('test-passphrase',
        const CryptoParams(salt: 'AAAAAAAAAAAAAAAAAAAAAA==', memoryKiB: 1024, iterations: 1, parallelism: 1));
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('compat');
    gh = FakeGithub();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<(DocStore, SyncEngine)> device(String name) async {
    final store = DocStore(baseDir: '${tmp.path}/$name', crypto: crypto, key: key);
    await store.init();
    final api = GithubApi(const GithubConfig(owner: 'o', repo: 'r', token: 't'), client: gh.client());
    return (
      store,
      SyncEngine(store: store, api: api, crypto: crypto, key: key, managedDirs: const ['docs'])
    );
  }

  void putRemote(String path, List<int> data) {
    final bytes = Uint8List.fromList(data);
    gh.files[path] = bytes;
    gh.blobs[FakeGithub.blobSha(bytes)] = bytes;
  }

  Future<Uint8List> enc(Object json) => crypto.encryptJson(json, key);

  /// Wie eine künftige App mit Formatversion 2 verschlüsseln würde.
  Future<Uint8List> encV2(Object json) async {
    final v1 = await enc(json);
    return Uint8List.fromList([2, ...v1.sublist(1)]);
  }

  void putMeta(int schema) => putRemote('meta.json',
      utf8.encode(jsonEncode({'version': 1, 'kdf': 'argon2id', 'salt': 'AAAA', 'schema': schema})));

  test('Unbekannte Felder überleben den Weg Gerät → Repo → Gerät', () async {
    final (a, ea) = await device('a');
    final (b, eb) = await device('b');
    putMeta(1);
    putRemote('docs/1.enc', await enc({'id': '1', 'title': 'Neu', 'zukunft': {'x': 1}}));
    await ea.sync();
    expect(a.get('docs/1.enc')!['zukunft'], {'x': 1});
    await a.put('docs/1.enc', {...a.get('docs/1.enc')!, 'title': 'Geändert'});
    await ea.sync();
    await eb.sync();
    expect(b.get('docs/1.enc'), containsPair('zukunft', {'x': 1}));
    expect(b.get('docs/1.enc'), containsPair('title', 'Geändert'));
  });

  test('Dokument im Format einer neueren Version: übersprungen, nicht überschrieben, nicht ständig neu geladen', () async {
    final (a, ea) = await device('a');
    putMeta(1);
    putRemote('docs/ok.enc', await enc({'id': 'ok'}));
    putRemote('docs/neu.enc', await encV2({'id': 'neu'}));
    final r = await ea.sync();
    expect(r.pulled, 1);
    expect(r.skipped, 1);
    expect(r.newer, 1);
    expect(a.get('docs/neu.enc'), isNull);

    final reads = gh.blobReads;
    final r2 = await ea.sync();
    expect(gh.blobReads, reads, reason: 'unlesbare Datei nicht bei jedem Abgleich neu laden');
    expect(r2.newer, 1, reason: 'Hinweis bleibt, solange die Datei unlesbar ist');

    // Auch nach einem Neustart (Zustand aus der Datei) nicht erneut laden.
    final (_, ea2) = await device('a');
    expect((await ea2.sync()).newer, 1);
    expect(gh.blobReads, reads);

    // Die neuere App löscht die Datei wieder: Hinweis verschwindet.
    gh.files.remove('docs/neu.enc');
    expect((await ea2.sync()).newer, 0);
  });

  test('Veraltete lokale Kopie wird nicht über eine neuere Fassung geschrieben', () async {
    final (a, ea) = await device('a');
    putMeta(1);
    putRemote('docs/1.enc', await enc({'id': '1', 'title': 'Alt'}));
    await ea.sync();
    // Eine neuere App speichert das Dokument im neuen Format …
    final v2 = await encV2({'id': '1', 'title': 'Neu'});
    putRemote('docs/1.enc', v2);
    // … während hier noch die alte Fassung bearbeitet wird.
    await a.put('docs/1.enc', {'id': '1', 'title': 'Lokal'});
    final r = await ea.sync();
    expect(r.newer, 1);
    expect(gh.files['docs/1.enc'], v2, reason: 'neuere Fassung bleibt unangetastet');
    expect(a.get('docs/1.enc'), isNull);
    expect(a.pendingCount, 0);
  });

  test('Beschädigte und unerwartete Inhalte blockieren den Abgleich nicht', () async {
    final (a, ea) = await device('a');
    putMeta(1);
    putRemote('docs/liste.enc', await enc([1, 2, 3]));
    putRemote('docs/kaputt.enc', [1, 2, 3]);
    putRemote('docs/leer.enc', []);
    putRemote('docs/kein-json.enc', await crypto.encryptBytes(utf8.encode('{nicht json'), key));
    putRemote('docs/gut.enc', await enc({'id': 'gut'}));
    final r = await ea.sync();
    expect(r.pulled, 1);
    expect(r.skipped, 4);
    expect(a.get('docs/gut.enc'), isNotNull);
  });

  test('Repo von einer neueren App umgestellt: kein Schreiben, lokale Änderungen bleiben', () async {
    final (a, ea) = await device('a');
    putMeta(1);
    await ea.sync();
    putMeta(2);
    await a.put('docs/1.enc', {'id': '1'});
    // Der erste Abgleich schreibt noch (meta.json wird beim Laden geprüft) …
    await expectLater(ea.sync(), throwsA(isA<RepoTooNewException>()));
    final writes = gh.writes;
    // … danach wird nichts mehr geschrieben.
    await a.put('docs/2.enc', {'id': '2'});
    await expectLater(ea.sync(), throwsA(isA<RepoTooNewException>()));
    expect(gh.writes, writes);
    expect(a.pendingCount, 1);
    expect(a.get('docs/2.enc'), isNotNull);
    // Auch nach einem Neustart.
    final (a2, ea2) = await device('a');
    await expectLater(ea2.sync(), throwsA(isA<RepoTooNewException>()));
    expect(a2.get('docs/2.enc'), isNotNull);
    // Wird die Umstellung zurückgenommen, läuft der Abgleich wieder.
    putMeta(1);
    final r = await ea2.sync();
    expect(r.pushed, 1);
    expect(gh.files.containsKey('docs/2.enc'), isTrue);
  });

  test('Einrichtung: neueres Repo-Format gibt eine klare Meldung', () async {
    final api = GithubApi(const GithubConfig(owner: 'o', repo: 'r', token: 't'), client: gh.client());
    putMeta(2);
    await expectLater(SyncEngine.fetchMeta(api), throwsA(isA<RepoTooNewException>()));
    putRemote('meta.json', utf8.encode(jsonEncode({'kdf': 'scrypt', 'salt': 'AAAA'})));
    await expectLater(SyncEngine.fetchMeta(api), throwsA(isA<RepoTooNewException>()));
    putRemote('meta.json', utf8.encode(jsonEncode({'salt': 'AAAA', 'zukunft': true})));
    expect((await SyncEngine.fetchMeta(api))!.salt, 'AAAA');
  });

  test('Sync-Zustand mit fremden oder kaputten Einträgen wird gelesen', () async {
    final dir = '${tmp.path}/z';
    await Directory('$dir/docs').create(recursive: true);
    await File('$dir/state.enc').writeAsBytes(await enc({
      'remote_shas': {'docs/1.enc': 'abc', 'x': 5},
      'pending': [
        {'path': 'docs/1.enc', 'delete': false, 'at': 'kein Datum'},
        {'delete': true},
        'unsinn',
      ],
      'last_sync': 42,
      'neues_feld': [1, 2],
    }));
    await File('$dir/docs/docs__kaputt.enc').writeAsBytes([9, 9, 9]);
    await File('$dir/docs/docs__liste.enc').writeAsBytes(await enc([1]));
    final store = DocStore(baseDir: dir, crypto: crypto, key: key);
    await store.init();
    expect(store.pendingCount, 1);
    expect(store.remoteShas, {'docs/1.enc': 'abc'});
    expect(store.docs, isEmpty);
    await store.saveState();
    final state = await crypto.decryptDoc(await File('$dir/state.enc').readAsBytes(), key);
    expect(state['neues_feld'], [1, 2], reason: 'fremde Zustandsfelder bleiben erhalten');
  });

  test('Völlig unlesbarer Sync-Zustand: App startet trotzdem', () async {
    final dir = '${tmp.path}/y';
    await Directory('$dir/docs').create(recursive: true);
    await File('$dir/state.enc').writeAsBytes([1, 2, 3, 4]);
    final store = DocStore(baseDir: dir, crypto: crypto, key: key);
    await store.init();
    expect(store.pendingCount, 0);
  });
}

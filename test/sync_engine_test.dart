import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:encrypted_calendar_app/src/core/crypto_service.dart';
import 'package:encrypted_calendar_app/src/core/doc_store.dart';
import 'package:encrypted_calendar_app/src/core/github_api.dart';
import 'package:encrypted_calendar_app/src/core/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_github.dart';

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
    tmp = await Directory.systemTemp.createTemp('sync');
    gh = FakeGithub();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<(DocStore, SyncEngine)> device(String name, {List<String>? conflicts}) async {
    final store = DocStore(baseDir: '${tmp.path}/$name', crypto: crypto, key: key);
    await store.init();
    final api = GithubApi(const GithubConfig(owner: 'o', repo: 'r', token: 't'), client: gh.client());
    final engine = SyncEngine(
      store: store, api: api, crypto: crypto, key: key,
      managedDirs: const ['events'],
      onConflict: (path, loser, winner) async => conflicts?.add('${loser['title']}<${winner['title']}'),
    );
    return (store, engine);
  }

  Map<String, dynamic> doc(String title, DateTime at) =>
      {'id': title, 'title': title, 'updated_at': at.toIso8601String()};

  test('Änderungen wandern von Gerät A zu Gerät B, Löschungen auch', () async {
    final (a, ea) = await device('a');
    final (b, eb) = await device('b');
    await a.put('events/1.enc', doc('Zahnarzt', DateTime(2026, 1, 1)));
    await a.put('events/2.enc', doc('Kino', DateTime(2026, 1, 1)));
    expect((await ea.sync()).pushed, 2);
    expect(gh.files.keys, containsAll(['events/1.enc', 'events/2.enc']));

    final r = await eb.sync();
    expect(r.pulled, 2);
    expect(b.get('events/1.enc')!['title'], 'Zahnarzt');

    await b.delete('events/2.enc');
    await eb.sync();
    final r2 = await ea.sync();
    expect(a.get('events/2.enc'), isNull);
    expect(r2.changes.single.after, isNull);
  });

  test('Remote liegt nur verschlüsselt', () async {
    final (a, ea) = await device('a');
    await a.put('events/1.enc', doc('Geheimer Termin', DateTime(2026, 1, 1)));
    await ea.sync();
    final raw = String.fromCharCodes(gh.files['events/1.enc']!);
    expect(raw.contains('Geheimer'), isFalse);
  });

  test('Konflikt: jüngere Änderung gewinnt, unterlegene geht an onConflict', () async {
    final conflicts = <String>[];
    final (a, ea) = await device('a', conflicts: conflicts);
    final (b, eb) = await device('b', conflicts: conflicts);
    await a.put('events/1.enc', doc('Original', DateTime(2026, 1, 1)));
    await ea.sync();
    await eb.sync();

    await a.put('events/1.enc', doc('Version A', DateTime(2026, 1, 2)));
    await b.put('events/1.enc', doc('Version B', DateTime(2026, 1, 3)));
    await ea.sync();
    final r = await eb.sync(); // B ist jünger -> gewinnt
    expect(r.conflicts, 1);
    expect(conflicts, ['Version A<Version B']);
    await ea.sync();
    expect(a.get('events/1.enc')!['title'], 'Version B');
  });

  test('Offline gespeicherte Änderungen bleiben in der Queue', () async {
    final (a, _) = await device('a');
    await a.put('events/1.enc', doc('Offline', DateTime(2026, 1, 1)));
    final reopened = DocStore(baseDir: '${tmp.path}/a', crypto: crypto, key: key);
    await reopened.init();
    expect(reopened.pendingCount, 1);
    expect(reopened.get('events/1.enc')!['title'], 'Offline');
  });

  test('Schlüsselprobe erkennt falsche Passphrase', () async {
    final api = GithubApi(const GithubConfig(owner: 'o', repo: 'r', token: 't'), client: gh.client());
    final params = const CryptoParams(salt: 'AAAAAAAAAAAAAAAAAAAAAA==', memoryKiB: 1024, iterations: 1, parallelism: 1);
    await SyncEngine.initializeRemote(api, crypto, key, params, app: 'test');
    expect(await SyncEngine.verifyKey(api, crypto, key), isTrue);
    final wrong = await crypto.deriveKey('falsch', params);
    expect(await SyncEngine.verifyKey(api, crypto, wrong), isFalse);
    expect((await SyncEngine.fetchMeta(api))!.salt, params.salt);
  });

  test('deterministische IDs sind stabil und schlüsselabhängig', () async {
    final id1 = await crypto.deterministicId('liste\nmilch', key);
    final id2 = await crypto.deterministicId('liste\nmilch', key);
    final other = await crypto.deterministicId('liste\nbrot', key);
    expect(id1, id2);
    expect(id1, isNot(other));
    expect(id1.length, 32);
  });
}

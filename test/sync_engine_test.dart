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

  Future<(DocStore, SyncEngine)> device(String name,
      {List<String>? conflicts, List<Set<String>> groups = const []}) async {
    final store = DocStore(baseDir: '${tmp.path}/$name', crypto: crypto, key: key);
    await store.init();
    final api = GithubApi(const GithubConfig(owner: 'o', repo: 'r', token: 't'), client: gh.client());
    final engine = SyncEngine(
      store: store, api: api, crypto: crypto, key: key,
      managedDirs: const ['events'],
      onConflict: (path, loser, winner) async => conflicts?.add('${loser['title']}<${winner['title']}'),
      mergeGroups: groups,
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

  test('Gleicher Inhalt auf beiden Seiten ist kein Konflikt', () async {
    final conflicts = <String>[];
    final (a, ea) = await device('a', conflicts: conflicts);
    final (b, eb) = await device('b', conflicts: conflicts);
    await a.put('events/1.enc', doc('Original', DateTime(2026, 1, 1)));
    await ea.sync();
    await eb.sync();

    // Beide ändern dasselbe auf dieselbe Weise (z. B. über den Google-Abgleich).
    await a.put('events/1.enc', {...doc('Neu', DateTime(2026, 1, 2)), 'updated_by': 'A'});
    await b.put('events/1.enc', {...doc('Neu', DateTime(2026, 1, 3)), 'updated_by': 'B'});
    await ea.sync();
    final r = await eb.sync();
    expect(r.conflicts, 0);
    expect(conflicts, isEmpty);
    expect(b.pendingCount, 0);
    expect(b.get('events/1.enc')!['title'], 'Neu');
  });

  test('Verschiedene Felder gleichzeitig geändert: zusammengeführt, kein Konflikt', () async {
    final conflicts = <String>[];
    const groups = [{'start', 'end'}];
    final (a, ea) = await device('a', conflicts: conflicts, groups: groups);
    final (b, eb) = await device('b', conflicts: conflicts, groups: groups);
    await a.put('events/1.enc', {...doc('Kino', DateTime(2026, 1, 1)), 'location': 'Metropol', 'start': '20', 'end': '22'});
    await ea.sync();
    await eb.sync();

    // A ändert den Titel, B den Ort – beides bleibt erhalten.
    await a.put('events/1.enc', {...a.get('events/1.enc')!, 'title': 'Kino mit Jana', 'updated_at': '2026-01-02T00:00:00.000'});
    await b.put('events/1.enc', {...b.get('events/1.enc')!, 'location': 'Cinema', 'updated_at': '2026-01-03T00:00:00.000'});
    await ea.sync();
    final r = await eb.sync();
    expect(r.conflicts, 0);
    expect(r.merged, 1);
    expect(conflicts, isEmpty);
    expect(b.get('events/1.enc'), containsPair('title', 'Kino mit Jana'));
    expect(b.get('events/1.enc'), containsPair('location', 'Cinema'));
    expect(b.pendingCount, 0);
    await ea.sync();
    expect(a.get('events/1.enc'), containsPair('location', 'Cinema'));
    expect(a.get('events/1.enc'), containsPair('title', 'Kino mit Jana'));

    // Beginn hier, Ende dort: gehören zusammen, also ein echter Konflikt.
    await a.put('events/1.enc', {...a.get('events/1.enc')!, 'start': '19', 'updated_at': '2026-01-04T00:00:00.000'});
    await b.put('events/1.enc', {...b.get('events/1.enc')!, 'end': '23', 'updated_at': '2026-01-05T00:00:00.000'});
    await ea.sync();
    final r2 = await eb.sync();
    expect(r2.merged, 0);
    expect(r2.conflicts, 1);
    expect(b.get('events/1.enc'), containsPair('end', '23'));
    expect(b.get('events/1.enc'), containsPair('start', '20'));
  });

  test('Veraltete Version aus dem anderen Prozess ist kein Konflikt', () async {
    final conflicts = <String>[];
    // App und Hintergrund-Abgleich: zwei Stores auf derselben lokalen Kopie.
    final (ui, eui) = await device('a', conflicts: conflicts);
    await ui.put('events/1.enc', doc('V1', DateTime(2026, 1, 1)));
    await eui.sync();
    await ui.put('events/1.enc', doc('V2', DateTime(2026, 1, 2)));

    final (bg, ebg) = await device('a', conflicts: conflicts);
    expect(bg.pendingCount, 1);
    expect((await ebg.sync()).pushed, 1); // Hintergrund sendet V2

    // Die App hält V2 noch für offen (mit der alten Version-ID), der Abgleich
    // lädt aber zuerst den Stand des Hintergrunds: nichts mehr zu senden.
    final r1 = await eui.sync();
    expect(r1.reloaded, isTrue);
    expect(r1.conflicts, 0);
    expect(r1.pushed, 0);
    expect(ui.pendingCount, 0);

    // Echter Konflikt: der Hintergrund hat V4 gesendet, die App ändert danach.
    await bg.put('events/1.enc', doc('V4', DateTime(2026, 1, 4)));
    await ebg.sync();
    await ui.put('events/1.enc', doc('V3', DateTime(2026, 1, 3)));
    await ui.put('events/1.enc', doc('V3b', DateTime(2026, 1, 5)));
    final r2 = await eui.sync();
    // V4 kennt die App nicht: Konflikt, die jüngere Fassung gewinnt.
    expect(r2.conflicts, 1);
    expect(conflicts, ['V4<V3b']);

    // Hat die App nach dem Hintergrund-Abgleich weiter geändert (und dabei
    // dessen Stand überschrieben), beruht ihre Fassung trotzdem auf W2.
    conflicts.clear();
    final (ui2, eui2) = await device('c', conflicts: conflicts);
    await eui2.sync();
    await ui2.put('events/1.enc', doc('W1', DateTime(2026, 2, 1)));
    await eui2.sync();
    await ui2.put('events/1.enc', doc('W2', DateTime(2026, 2, 2)));
    final (bg2, ebg2) = await device('c', conflicts: conflicts);
    await ebg2.sync(); // sendet W2
    await ui2.put('events/1.enc', doc('W3', DateTime(2026, 2, 3)));
    final r3 = await eui2.sync();
    expect(r3.conflicts, 0);
    expect(conflicts, isEmpty);
    expect(bg2.pendingCount, 0);
    final (check, echeck) = await device('d');
    await echeck.sync();
    expect(check.get('events/1.enc')!['title'], 'W3');
  });

  test('Viele Änderungen gehen gedrosselt raus; Drosselung durch GitHub pausiert das Senden', () async {
    final (a, ea) = await device('a');
    for (var i = 0; i < 70; i++) {
      await a.put('events/$i.enc', doc('T$i', DateTime(2026, 1, 1)), persistState: false);
    }
    await a.saveState();
    expect((await ea.sync()).pushed, SyncEngine.maxPushPerSync);
    expect(a.pendingCount, 70 - SyncEngine.maxPushPerSync);
    expect((await ea.sync()).pushed, 70 - SyncEngine.maxPushPerSync);
    expect(a.pendingCount, 0);

    // GitHub drosselt: kein Fehler, Empfangen geht weiter, Senden pausiert
    final (b, eb) = await device('b');
    await b.put('events/b.enc', doc('Von B', DateTime(2026, 1, 3)));
    await eb.sync();
    gh.throttle = true;
    await a.put('events/x.enc', doc('X', DateTime(2026, 1, 2)));
    final r = await ea.sync();
    expect(r.pushed, 0);
    expect(a.get('events/b.enc')!['title'], 'Von B');
    expect(a.pendingCount, 1);
    expect(a.pushPausedUntil, isNotNull);
    gh.throttle = false;
    expect((await ea.sync()).pushed, 0, reason: 'Pause läuft noch');
    a.pushPausedUntil = DateTime.now().subtract(const Duration(seconds: 1));
    expect((await ea.sync()).pushed, 1);
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

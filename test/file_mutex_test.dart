import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:encrypted_calendar_app/src/core/file_mutex.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('mutex'));
  tearDown(() => tmp.delete(recursive: true));

  test('Schließt gleichzeitige Durchläufe aus und räumt auf', () async {
    final path = '${tmp.path}/x.mutex';
    var inside = 0, maxInside = 0;
    Future<void> work() async {
      inside++;
      maxInside = max(maxInside, inside);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      inside--;
    }

    await Future.wait([for (var i = 0; i < 5; i++) ...[FileMutex(path).run(work), FileMutex(path).run(work)]]);
    expect(maxInside, 1);
    expect(File(path).existsSync(), isFalse);
  });

  test('Wirkt auch zwischen zwei Isolaten desselben Prozesses', () async {
    final path = '${tmp.path}/iso.mutex';
    final log = '${tmp.path}/log.txt';
    Future<void> work(String who) => FileMutex(path).run(() async {
          File(log).writeAsStringSync('$who+\n', mode: FileMode.append);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          File(log).writeAsStringSync('$who-\n', mode: FileMode.append);
        });
    await Future.wait([Isolate.run(() => work('a')), work('b')]);
    final lines = File(log).readAsLinesSync();
    expect(lines, anyOf(equals(['a+', 'a-', 'b+', 'b-']), equals(['b+', 'b-', 'a+', 'a-'])));
  });

  test('Liegengebliebene Sperren werden übernommen', () async {
    // Prozess der Sperre läuft nicht mehr.
    final dead = File('${tmp.path}/dead.mutex')..writeAsStringSync('999999999 abc');
    expect(await FileMutex(dead.path, timeout: const Duration(seconds: 5)).run(() async => 1), 1);
    // Herzschlag zu alt.
    final old = File('${tmp.path}/old.mutex')..writeAsStringSync('$pid abc');
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));
    expect(await FileMutex(old.path, timeout: const Duration(seconds: 5)).run(() async => 2), 2);
  });

  test('Fehler im Durchlauf geben die Sperre frei', () async {
    final path = '${tmp.path}/err.mutex';
    await expectLater(FileMutex(path).run(() async => throw StateError('x')), throwsStateError);
    expect(File(path).existsSync(), isFalse);
    expect(await FileMutex(path).run(() async => 3), 3);
  });
}

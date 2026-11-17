import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'app_log.dart';

/// Gegenseitiger Ausschluss über eine exklusiv angelegte Datei.
///
/// `RandomAccessFile.lock` sperrt nur zwischen Prozessen – App und
/// Hintergrund-Abgleich laufen auf Android aber meist als zwei Isolate im
/// selben Prozess und bekämen beide die Sperre. Das exklusive Anlegen einer
/// Datei ist dagegen auch zwischen Isolaten atomar.
///
/// Hinterlässt ein abgebrochener Durchlauf die Datei, gilt sie als veraltet,
/// sobald ihr Prozess nicht mehr läuft oder ihr Herzschlag (Änderungszeit)
/// länger als [stale] zurückliegt.
class FileMutex {
  FileMutex(this.path, {this.stale = const Duration(seconds: 90), this.timeout = const Duration(minutes: 10)});

  final String path;
  final Duration stale;
  final Duration timeout;

  static const _beat = Duration(seconds: 15);
  static final _random = Random();

  Future<T> run<T>(Future<T> Function() body) async {
    final f = File(path);
    final token = '$pid ${_random.nextInt(1 << 32).toRadixString(36)}';
    await _acquire(f, token);
    final beat = Timer.periodic(_beat, (_) {
      try {
        f.setLastModifiedSync(DateTime.now());
      } catch (_) {}
    });
    try {
      return await body();
    } finally {
      beat.cancel();
      try {
        if (f.readAsStringSync() == token) f.deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _acquire(File f, String token) async {
    await f.parent.create(recursive: true);
    final started = DateTime.now();
    var waited = false;
    while (true) {
      try {
        await f.create(exclusive: true);
        await f.writeAsString(token, flush: true);
        if (waited) {
          AppLog.info('sperre', '${_name(f)} nach ${DateTime.now().difference(started).inSeconds} s frei');
        }
        return;
      } on FileSystemException {
        if (await _isStale(f)) {
          AppLog.warn('sperre', '${_name(f)}: liegengebliebene Sperre entfernt');
          try {
            await f.delete();
          } catch (_) {}
          continue;
        }
        if (!waited) AppLog.info('sperre', '${_name(f)} belegt (anderer Abgleich läuft), warte');
        waited = true;
        if (DateTime.now().difference(started) > timeout) {
          throw TimeoutException('${_name(f)} bleibt belegt', timeout);
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  Future<bool> _isStale(File f) async {
    try {
      final st = await f.stat();
      if (st.type == FileSystemEntityType.notFound) return false;
      if (DateTime.now().difference(st.modified) > stale) return true;
      // Prozess der Sperre beendet (z. B. App abgestürzt oder vom System beendet)?
      final holder = int.tryParse((await f.readAsString()).split(' ').first);
      if (holder != null && holder != pid && Directory('/proc/self').existsSync()) {
        return !Directory('/proc/$holder').existsSync();
      }
    } catch (_) {}
    return false;
  }

  static String _name(File f) => f.uri.pathSegments.skip(f.uri.pathSegments.length - 2).join('/');
}

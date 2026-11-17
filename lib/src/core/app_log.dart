import 'dart:io';

/// Lokales Protokoll für die Fehlersuche: eine Textdatei je Tag unter
/// `<App-Daten>/logs`, die letzten [keepDays] Tage. App und Hintergrund-Abgleich
/// schreiben in dieselbe Datei; die Zeilen sind mit `[ui]` bzw. `[bg]` markiert.
///
/// Ohne [init] (z. B. in Tests) wird nichts geschrieben. Schreibfehler werden
/// verschluckt – das Protokoll darf die App nie stören.
class AppLog {
  AppLog._();

  static const keepDays = 14;

  /// Ab dieser Größe werden an diesem Tag nur noch Warnungen und Fehler notiert.
  static const maxBytesPerDay = 4 * 1024 * 1024;

  static Directory? _dir;
  static String _process = 'ui';

  static Directory? get dir => _dir;

  static Future<void> init(String baseDir, {String process = 'ui'}) async {
    try {
      final d = Directory('$baseDir/logs');
      await d.create(recursive: true);
      _dir = d;
      _process = process;
      final cutoff = DateTime.now().subtract(const Duration(days: keepDays));
      await for (final f in d.list()) {
        if (f is File && f.path.endsWith('.log') && (await f.stat()).modified.isBefore(cutoff)) {
          await f.delete();
        }
      }
    } catch (_) {}
  }

  static void info(String tag, String message) => _write('I', tag, message);
  static void warn(String tag, String message) => _write('W', tag, message);

  static void error(String tag, String message, [Object? error, StackTrace? stack]) => _write('E', tag, [
        message,
        if (error != null) '$error',
        if (stack != null) stack.toString().split('\n').take(10).join(' ⏎ '),
      ].join(' | '));

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String fileNameFor(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}.log';

  static void _write(String level, String tag, String message) {
    final d = _dir;
    if (d == null) return;
    try {
      final now = DateTime.now();
      final f = File('${d.path}/${fileNameFor(now)}');
      if (level == 'I' && f.existsSync() && f.lengthSync() > maxBytesPerDay) return;
      f.writeAsStringSync('${now.toIso8601String()} $level [$_process] $tag: ${message.replaceAll('\n', ' ⏎ ')}\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// Alle Protokolldateien, älteste zuerst.
  static Future<List<File>> files() async {
    final d = _dir;
    if (d == null || !await d.exists()) return [];
    final out = [
      await for (final f in d.list())
        if (f is File && f.path.endsWith('.log')) f,
    ]..sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// Die letzten [max] Zeilen, neueste zuerst.
  static Future<List<String>> tail(int max) async {
    final out = <String>[];
    for (final f in (await files()).reversed) {
      final lines = await f.readAsLines();
      for (final l in lines.reversed) {
        if (l.isEmpty) continue;
        out.add(l);
        if (out.length >= max) return out;
      }
    }
    return out;
  }

  static Future<void> clear() async {
    for (final f in await files()) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }
}

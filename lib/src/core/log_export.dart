import 'dart:io';

import 'package:flutter/services.dart';

import 'app_log.dart';

/// Legt die Protokolldateien (plus eine Info-Datei) im öffentlichen Ordner
/// „Download/[folder]“ ab. Von dort lassen sie sich per USB-Kabel auf den
/// Rechner ziehen. Ab Android 10 ohne Berechtigung (eigene Dateien).
class LogExport {
  LogExport._();

  static const _channel = MethodChannel('de.sweber/files');

  /// Liefert den Zielordner zur Anzeige. [prefix] steht vor jedem Dateinamen
  /// (z. B. „kalender“), [info] landet als `<prefix>-info.txt` daneben.
  static Future<String> toDownloads({
    required String folder,
    required String prefix,
    required String info,
  }) async {
    final logs = await AppLog.files();
    final dir = AppLog.dir;
    if (dir == null) throw StateError('Kein Protokoll vorhanden');
    final infoFile = File('${dir.path}/info.txt');
    await infoFile.writeAsString(info);
    final files = [
      {'path': infoFile.path, 'name': '$prefix-info.txt'},
      for (final f in logs)
        {
          'path': f.path,
          // .txt: Android hängt bei Textdateien sonst selbst „.txt“ an
          'name': '$prefix-${f.uri.pathSegments.last.replaceAll('.log', '')}.txt',
        },
    ];
    final where = await _channel.invokeMethod<String>('saveToDownloads', {'folder': folder, 'files': files});
    AppLog.info('protokoll', 'exportiert: ${files.length} Dateien nach ${where ?? folder}');
    return where ?? 'Download/$folder';
  }
}

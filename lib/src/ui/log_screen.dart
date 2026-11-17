import 'package:flutter/material.dart';

import '../core/app_log.dart';
import '../core/log_export.dart';

/// Zeigt das lokale Protokoll (neueste Zeilen zuerst) und legt es zum
/// Herüberziehen auf den Rechner im Download-Ordner ab.
class LogScreen extends StatefulWidget {
  const LogScreen({
    super.key,
    required this.folder,
    required this.prefix,
    required this.info,
  });

  /// Unterordner in „Download“, z. B. „Kalender-Protokoll“.
  final String folder;

  /// Präfix der exportierten Dateinamen, z. B. „kalender“.
  final String prefix;

  /// Liefert den Text der Info-Datei (Version, Quellen, Einstellungen).
  final Future<String> Function() info;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  static const _maxLines = 1500;

  List<String>? _lines;
  bool _onlyProblems = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lines = await AppLog.tail(_maxLines);
    if (mounted) setState(() => _lines = lines);
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final where = await LogExport.toDownloads(
          folder: widget.folder, prefix: widget.prefix, info: await widget.info());
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Protokoll abgelegt'),
          content: Text('Die Dateien liegen auf dem Handy unter\n\n$where\n\n'
              'Handy per USB-Kabel anschließen, „Dateiübertragung“ wählen und den Ordner '
              'im Explorer unter „Interner Speicher › Download“ öffnen.\n\n'
              'Bei Konflikten stehen auch Termininhalte (Titel, Orte …) darin – '
              'die Dateien deshalb nicht öffentlich teilen.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export fehlgeschlagen: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Protokoll löschen?'),
        content: const Text('Alle gespeicherten Protokolltage werden entfernt. '
            'Bereits exportierte Dateien im Download-Ordner bleiben.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Löschen')),
        ],
      ),
    );
    if (ok != true) return;
    await AppLog.clear();
    AppLog.info('protokoll', 'Protokoll gelöscht');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final all = _lines;
    final lines = all == null
        ? null
        : _onlyProblems
            ? all.where((l) => _LogLine.parse(l).level != 'I').toList()
            : all;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Protokoll'),
        actions: [
          IconButton(
            tooltip: 'Neu laden',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          IconButton(
            tooltip: 'Löschen',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clear,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _export,
        icon: _busy
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.download_outlined),
        label: const Text('In „Download“ ablegen'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'Die App notiert hier ${AppLog.keepDays} Tage lang, was beim Abgleich '
            'passiert – App und Hintergrund-Abruf. Der Export legt je Tag eine Datei '
            'in „Download/${widget.folder}“ ab.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SwitchListTile(
          dense: true,
          title: const Text('Nur Warnungen und Fehler'),
          value: _onlyProblems,
          onChanged: (v) => setState(() => _onlyProblems = v),
        ),
        const Divider(height: 1),
        Expanded(
          child: lines == null
              ? const Center(child: CircularProgressIndicator())
              : lines.isEmpty
                  ? const Center(child: Text('Noch keine Einträge'))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: lines.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (c, i) {
                          final l = _LogLine.parse(lines[i]);
                          final color = switch (l.level) {
                            'E' => scheme.error,
                            'W' => Colors.orange.shade800,
                            _ => scheme.onSurface,
                          };
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            child: SelectableText.rich(
                              TextSpan(
                                style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: color),
                                children: [
                                  TextSpan(
                                    text: '${l.time} ${l.process} ${l.tag}\n',
                                    style: TextStyle(color: scheme.onSurfaceVariant),
                                  ),
                                  TextSpan(text: l.message),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
        ),
      ]),
    );
  }
}

/// Eine Protokollzeile: `<ISO-Zeit> <I|W|E> [ui|bg] <tag>: <Text>`.
class _LogLine {
  _LogLine(this.time, this.level, this.process, this.tag, this.message);

  final String time;
  final String level;
  final String process;
  final String tag;
  final String message;

  static final _re = RegExp(r'^(\S+) ([IWE]) \[(\w+)\] ([^:]+): (.*)$');

  static _LogLine parse(String line) {
    final m = _re.firstMatch(line);
    if (m == null) return _LogLine('', 'I', '', '', line);
    final t = DateTime.tryParse(m[1]!);
    String two(int n) => n.toString().padLeft(2, '0');
    final time = t == null
        ? m[1]!
        : '${two(t.day)}.${two(t.month)}. ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    return _LogLine(time, m[2]!, m[3]!, m[4]!, m[5]!);
  }
}

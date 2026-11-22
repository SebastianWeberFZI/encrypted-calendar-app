import 'dart:convert';

import 'package:http/http.dart' as http;

/// Fehler beim Laden eines Kalender-Abos (Text für die Anzeige).
class IcsFetchException implements Exception {
  const IcsFetchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Lädt eine iCalendar-Datei.
///
/// Die Adresse kann direkt auf die Datei zeigen (auch `webcal://`) oder auf
/// eine Seite, die sie erst über ein Formular herausgibt – wie der
/// Abfallkalender des Landkreises Germersheim („Als ICS herunterladen“ mit
/// Sitzungs-Token). Dann wird dieses Formular wie im Browser abgeschickt.
Future<String> fetchIcs(String address, {http.Client? client, Duration timeout = const Duration(seconds: 30)}) async {
  final c = client ?? http.Client();
  try {
    final url = normalizeIcsUrl(address);
    final headers = {'User-Agent': 'Kalender-App (ICS-Abo)', 'Accept': 'text/calendar, text/html;q=0.8, */*;q=0.5'};
    final first = await c.get(url, headers: headers).timeout(timeout);
    _check(first);
    final body = _decode(first);
    if (looksLikeIcs(body)) return body;

    final form = findDownloadForm(body, url);
    if (form == null) {
      throw const IcsFetchException('Unter der Adresse liegt weder eine Kalenderdatei noch ein Download-Formular');
    }
    final cookie = _cookies(first.headers['set-cookie']);
    final second = await c
        .post(form.action,
            headers: {
              ...headers,
              'Content-Type': 'application/x-www-form-urlencoded',
              // Wie ein Browser: Seiten mit CSRF-Schutz (z. B. Contao beim
              // Landkreis Germersheim) prüfen die Herkunft des Formulars.
              'Origin': url.origin,
              'Referer': url.toString(),
              if (cookie.isNotEmpty) 'Cookie': cookie,
            },
            body: form.fields)
        .timeout(timeout);
    _check(second);
    final ics = _decode(second);
    if (!looksLikeIcs(ics)) {
      throw const IcsFetchException('Das Download-Formular lieferte keine Kalenderdatei');
    }
    return ics;
  } on IcsFetchException {
    rethrow;
  } on FormatException {
    throw const IcsFetchException('Ungültige Adresse');
  } catch (e) {
    throw IcsFetchException('Abruf fehlgeschlagen: $e');
  } finally {
    if (client == null) c.close();
  }
}

/// `webcal://…` → `https://…`; ohne Schema → https.
Uri normalizeIcsUrl(String address) {
  var a = address.trim();
  if (a.toLowerCase().startsWith('webcal://')) a = 'https://${a.substring(9)}';
  if (!a.contains('://')) a = 'https://$a';
  final u = Uri.parse(a);
  if (u.scheme != 'https' && u.scheme != 'http' || u.host.isEmpty) {
    throw const FormatException('Ungültige Adresse');
  }
  return u;
}

bool looksLikeIcs(String body) => body.trimLeft().replaceFirst('\uFEFF', '').toUpperCase().startsWith('BEGIN:VCALENDAR');

void _check(http.Response r) {
  if (r.statusCode >= 400) {
    throw IcsFetchException('Server antwortet mit Fehler ${r.statusCode}');
  }
}

String _decode(http.Response r) {
  try {
    return utf8.decode(r.bodyBytes);
  } on FormatException {
    return latin1.decode(r.bodyBytes);
  }
}

/// `a=1; Path=/; HttpOnly, b=2; Expires=Wed, 01 Jan …` → `a=1; b=2`.
String _cookies(String? setCookie) {
  if (setCookie == null || setCookie.isEmpty) return '';
  return setCookie
      .split(RegExp(r',(?=\s*[A-Za-z0-9_\-.]+=)'))
      .map((c) => c.split(';').first.trim())
      .where((c) => c.contains('='))
      .join('; ');
}

/// Formular, das die Kalenderdatei herausgibt.
class DownloadForm {
  DownloadForm(this.action, this.fields);
  final Uri action;
  final Map<String, String> fields;
}

/// Sucht auf einer HTML-Seite ein POST-Formular mit versteckten Feldern, das
/// eine ICS-Datei herunterlädt (Schaltfläche oder Feld mit „ICS“, „iCal“,
/// „Kalender“ oder „herunterladen“).
DownloadForm? findDownloadForm(String html, Uri page) {
  final forms = RegExp(r'<form\b([^>]*)>(.*?)</form>', caseSensitive: false, dotAll: true).allMatches(html);
  DownloadForm? fallback;
  for (final f in forms) {
    final attrs = f[1]!;
    final inner = f[2]!;
    final method = _attr(attrs, 'method')?.toUpperCase() ?? 'GET';
    if (method != 'POST') continue;
    final fields = <String, String>{};
    for (final i in RegExp(r'<input\b([^>]*)>', caseSensitive: false).allMatches(inner)) {
      final a = i[1]!;
      if ((_attr(a, 'type') ?? 'text').toLowerCase() != 'hidden') continue;
      final name = _attr(a, 'name');
      if (name != null && name.isNotEmpty) fields[name] = _attr(a, 'value') ?? '';
    }
    if (fields.isEmpty) continue;
    final action = _attr(attrs, 'action');
    final target = action == null || action.isEmpty ? page : page.resolve(_unescape(action));
    final form = DownloadForm(target, fields);
    final text = inner.replaceAll(RegExp(r'<[^>]+>'), ' ').toLowerCase();
    final hint = RegExp(r'\bics\b|ical|kalender|herunterladen|download').hasMatch(text) ||
        fields.keys.any((k) => k.toLowerCase().contains('ics'));
    if (hint) return form;
    fallback ??= form;
  }
  return fallback;
}

String? _attr(String attrs, String name) {
  final m = RegExp('\\b$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))', caseSensitive: false).firstMatch(attrs);
  if (m == null) return null;
  return _unescape(m[1] ?? m[2] ?? m[3] ?? '');
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');

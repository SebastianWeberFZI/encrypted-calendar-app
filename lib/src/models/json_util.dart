/// Tolerantes Lesen von Dokumenten.
///
/// Dokumente können von älteren oder neueren App-Versionen stammen. Ein
/// fehlendes Feld, ein unerwarteter Typ oder ein unbekannter Wert darf die
/// App nie zum Absturz bringen: Es gilt der Standardwert. Unbekannte Felder
/// werden in `extra` gesammelt und beim Speichern unverändert zurückgeschrieben,
/// damit eine ältere App die Daten einer neueren nicht beschneidet.
library;

String jStr(Object? v, [String fallback = '']) => v is String ? v : fallback;

String? jStrOrNull(Object? v) => v is String ? v : null;

int? jIntOrNull(Object? v) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

int jInt(Object? v, int fallback) => jIntOrNull(v) ?? fallback;

bool jBool(Object? v, bool fallback) => v is bool ? v : fallback;

DateTime? jDate(Object? v) => v is String ? DateTime.tryParse(v) : null;

Map<String, dynamic>? jMap(Object? v) =>
    v is Map ? v.map((k, val) => MapEntry('$k', val)) : null;

/// Alle Objekte einer Liste (andere Einträge werden ignoriert).
List<Map<String, dynamic>> jMaps(Object? v) => v is List
    ? [for (final e in v) if (jMap(e) != null) jMap(e)!]
    : [];

List<String> jStrings(Object? v) =>
    v is List ? [for (final e in v) if (e is String) e] : [];

List<int> jInts(Object? v) =>
    v is List ? [for (final e in v) if (jIntOrNull(e) != null) jIntOrNull(e)!] : [];

List<DateTime> jDates(Object? v) =>
    v is List ? [for (final e in v) if (jDate(e) != null) jDate(e)!] : [];

/// Felder, die dieses Modell nicht kennt.
Map<String, dynamic> unknownFields(Map<String, dynamic> j, Set<String> known) =>
    {for (final e in j.entries) if (!known.contains(e.key)) e.key: e.value};

/// ID aus dem Dateinamen (`events/<id>.enc` → `<id>`).
String? idFromPath(String? path) {
  if (path == null) return null;
  final name = path.split('/').last;
  return name.endsWith('.enc') ? name.substring(0, name.length - 4) : null;
}

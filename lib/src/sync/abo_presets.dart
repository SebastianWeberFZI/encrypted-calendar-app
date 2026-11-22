/// Vorlagen für Kalender-Abos, deren Adresse man sich sonst auf einer
/// Webseite zusammenklicken müsste.
library;

/// Abfuhrtermine der Abfallwirtschaft Landkreis Germersheim.
///
/// Die Seite des Kreises erzeugt die ICS-Datei über ein Formular; die
/// Adresse der Seite (mit Ortschaft und Abfallarten) genügt als Abo-Adresse,
/// das Formular schickt die App beim Abruf selbst ab.
class GermersheimWaste {
  static const label = 'Abfallwirtschaft Germersheim';
  static const host = 'https://www.abfallwirtschaft-germersheim.de';
  static const _small = '/online-service/abfall-termine/abfalltermine-ics-export-bis-240-liter.html';
  static const _large = '/online-service/abfall-kalender/abfalltermine-ics-export-ueber-240-liter.html';

  static const places = [
    'Bellheim', 'Berg', 'Büchelberg', 'Erlenbach', 'Freckenfeld', 'Freisbach',
    'Germersheim', 'Hagenbach', 'Hatzenbühl', 'Hördt', 'Jockgrim', 'Kandel',
    'Knittelsheim', 'Kuhardt', 'Leimersheim', 'Lingenfeld', 'Lustadt',
    'Maximiliansau', 'Minfeld', 'Neuburg', 'Neupotz', 'Ottersheim',
    'Rheinzabern', 'Rülzheim', 'Schaidt', 'Scheibenhardt', 'Schwegenheim',
    'Sondernheim', 'Steinweiler', 'Vollmersweiler', 'Weingarten', 'Westheim',
    'Winden', 'Wörth', 'Zeiskam',
  ];

  /// Abfallarten je Behältergröße (über 240 l: Gelber Container statt Sack).
  static List<String> types({required bool large}) => [
        'Bioabfall',
        large ? 'Gelber Cont.' : 'Gelber Sack',
        'Glasbox',
        'Heckenschnitt',
        'Papier',
        'Problemmüll',
        'Restmüll',
      ];

  /// Farben (aus der Kalender-Palette) mit der Abfallart als Bedeutung –
  /// Abo-Termine mit diesem Titel bekommen die Farbe.
  static const colors = {
    'Restmüll': 0xFF78909C, // Grau
    'Bioabfall': 0xFF8D6E63, // Braun
    'Papier': 0xFF4A74D9, // Blau
    'Gelber Sack': 0xFFD4A21E, // Senf
    'Gelber Cont.': 0xFFD4A21E,
    'Glasbox': 0xFF5BAA5E, // Grün
    'Heckenschnitt': 0xFF2E9C8E, // Petrol
    'Problemmüll': 0xFFE05A5A, // Rot
  };

  static String url({required String place, required List<String> types, bool large = false}) {
    final q = [
      'icsortschaft=${Uri.encodeComponent(place)}',
      for (final t in types) 'icsabfallart[]=${Uri.encodeComponent(t)}',
    ].join('&');
    return '$host${large ? _large : _small}?$q';
  }

  /// Ortschaft, Abfallarten und Behälter aus einer Adresse dieser Seite
  /// (zum Wiederherstellen der Auswahl im Dialog); null bei anderen Adressen.
  static ({String place, List<String> types, bool large})? parse(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.host.endsWith('abfallwirtschaft-germersheim.de')) return null;
    final large = u.path == _large;
    if (!large && u.path != _small) return null;
    final all = u.queryParametersAll;
    final place = all['icsortschaft']?.firstOrNull ?? '';
    final types = all['icsabfallart[]'] ?? const <String>[];
    return (place: place, types: types, large: large);
  }
}

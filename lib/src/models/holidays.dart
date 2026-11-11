/// Gesetzliche Feiertage in Deutschland je Bundesland (lokal berechnet).
library;

const Map<String, String> kBundeslaender = {
  'BW': 'Baden-Württemberg',
  'BY': 'Bayern',
  'BE': 'Berlin',
  'BB': 'Brandenburg',
  'HB': 'Bremen',
  'HH': 'Hamburg',
  'HE': 'Hessen',
  'MV': 'Mecklenburg-Vorpommern',
  'NI': 'Niedersachsen',
  'NW': 'Nordrhein-Westfalen',
  'RP': 'Rheinland-Pfalz',
  'SL': 'Saarland',
  'SN': 'Sachsen',
  'ST': 'Sachsen-Anhalt',
  'SH': 'Schleswig-Holstein',
  'TH': 'Thüringen',
};

/// Ostersonntag (Gauß/Anonymer gregorianischer Algorithmus).
DateTime easterSunday(int year) {
  final a = year % 19, b = year ~/ 100, c = year % 100;
  final d = b ~/ 4, e = b % 4, f = (b + 8) ~/ 25, g = (b - f + 1) ~/ 3;
  final h = (19 * a + b - d - g + 15) % 30;
  final i = c ~/ 4, k = c % 4;
  final l = (32 + 2 * e + 2 * i - h - k) % 7;
  final m = (a + 11 * h + 22 * l) ~/ 451;
  final month = (h + l - 7 * m + 114) ~/ 31;
  final day = ((h + l - 7 * m + 114) % 31) + 1;
  return DateTime(year, month, day);
}

/// Feiertage eines Jahres für ein Bundesland: Datum -> Name.
Map<DateTime, String> holidaysFor(int year, String state) {
  final e = easterSunday(year);
  DateTime ea(int days) => DateTime(e.year, e.month, e.day + days);
  final out = <DateTime, String>{
    DateTime(year, 1, 1): 'Neujahr',
    ea(-2): 'Karfreitag',
    ea(1): 'Ostermontag',
    DateTime(year, 5, 1): 'Tag der Arbeit',
    ea(39): 'Christi Himmelfahrt',
    ea(50): 'Pfingstmontag',
    DateTime(year, 10, 3): 'Tag der Deutschen Einheit',
    DateTime(year, 12, 25): '1. Weihnachtstag',
    DateTime(year, 12, 26): '2. Weihnachtstag',
  };
  bool inState(List<String> states) => states.contains(state);
  if (inState(['BW', 'BY', 'ST'])) out[DateTime(year, 1, 6)] = 'Heilige Drei Könige';
  if (inState(['BE']) || (inState(['MV']) && year >= 2023)) {
    out[DateTime(year, 3, 8)] = 'Frauentag';
  }
  if (inState(['BB'])) {
    out[e] = 'Ostersonntag';
    out[ea(49)] = 'Pfingstsonntag';
  }
  if (inState(['BW', 'BY', 'HE', 'NW', 'RP', 'SL'])) out[ea(60)] = 'Fronleichnam';
  if (inState(['SL'])) out[DateTime(year, 8, 15)] = 'Mariä Himmelfahrt';
  if (inState(['TH']) && year >= 2019) out[DateTime(year, 9, 20)] = 'Weltkindertag';
  if (inState(['BB', 'HB', 'HH', 'MV', 'NI', 'SN', 'ST', 'SH', 'TH'])) {
    out[DateTime(year, 10, 31)] = 'Reformationstag';
  }
  if (inState(['BW', 'BY', 'NW', 'RP', 'SL'])) out[DateTime(year, 11, 1)] = 'Allerheiligen';
  if (inState(['SN'])) {
    // Mittwoch vor dem 23. November
    var d = DateTime(year, 11, 22);
    while (d.weekday != DateTime.wednesday) {
      d = DateTime(d.year, d.month, d.day - 1);
    }
    out[d] = 'Buß- und Bettag';
  }
  return out;
}

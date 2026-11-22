import 'package:uuid/uuid.dart';

import 'json_util.dart';

/// Version des Dokumentformats, mit der diese App schreibt. Jedes Dokument
/// trägt die Version der App, die es zuletzt gespeichert hat.
const int kSchemaVersion = 1;
const _uuid = Uuid();

String newId() => _uuid.v4();

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _two(int v) => v.toString().padLeft(2, '0');
String isoDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String isoLocal(DateTime d) =>
    '${isoDate(d)}T${_two(d.hour)}:${_two(d.minute)}';

/// Art eines Kalenders.
enum CalendarKind {
  standard('standard', 'Termine'),
  birthdays('birthdays', 'Geburtstage');

  const CalendarKind(this.code, this.label);
  final String code;
  final String label;

  static CalendarKind fromCode(String? c) => CalendarKind.values
      .firstWhere((k) => k.code == c, orElse: () => CalendarKind.standard);
}

/// Erinnerung relativ zum Terminbeginn. Bei ganztägigen Terminen ist der
/// Bezugspunkt 9:00 Uhr am Tag des Termins.
class Reminder {
  const Reminder({
    this.minutesBefore = 0,
    this.push = true,
    this.email = false,
    this.extra = const {},
  });

  final int minutesBefore;
  final bool push;
  final bool email;

  /// Unbekannte Felder (neuere App-Version), bleiben erhalten.
  final Map<String, dynamic> extra;

  Reminder copyWith({int? minutesBefore, bool? push, bool? email}) => Reminder(
      minutesBefore: minutesBefore ?? this.minutesBefore,
      push: push ?? this.push,
      email: email ?? this.email,
      extra: extra);

  Map<String, dynamic> toJson() => {
        ...extra,
        'minutes_before': minutesBefore,
        'push': push,
        'email': email,
      };

  static const _known = {'minutes_before', 'push', 'email'};

  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
        minutesBefore: jInt(j['minutes_before'], 0),
        push: jBool(j['push'], true),
        email: jBool(j['email'], false),
        extra: unknownFields(j, _known),
      );

  @override
  bool operator ==(Object other) =>
      other is Reminder &&
      other.minutesBefore == minutesBefore &&
      other.push == push &&
      other.email == email;

  @override
  int get hashCode => Object.hash(minutesBefore, push, email);
}

/// Bedeutung einer Farbe innerhalb eines Kalenders, z. B. Blau = "Arzt".
/// Gehört zur Kalenderdefinition und wird mit ihr synchronisiert; andere
/// Kalender dürfen dieselbe Farbe anders belegen.
class ColorLabel {
  const ColorLabel(
      {required this.color, required this.label, this.extra = const {}});

  final int color;
  final String label;
  final Map<String, dynamic> extra;

  Map<String, dynamic> toJson() => {...extra, 'color': color, 'label': label};

  factory ColorLabel.fromJson(Map<String, dynamic> j) => ColorLabel(
        color: jInt(j['color'], 0xFF78909C),
        label: jStr(j['label']),
        extra: unknownFields(j, const {'color', 'label'}),
      );
}

/// Ein Kalender (z. B. Geburtstage, Orte, TODOs) innerhalb einer Datenquelle.
class CalendarDef {
  CalendarDef({
    String? id,
    required this.sourceId,
    required this.name,
    required this.color,
    this.kind = CalendarKind.standard,
    this.emoji = '',
    List<Reminder>? defaultReminders,
    List<ColorLabel>? colorLabels,
    this.sortOrder = 0,
    this.sync,
    this.subscription,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.updatedBy = '',
    Map<String, dynamic>? extra,
    this.unknownKind,
  })  : id = id ?? newId(),
        defaultReminders = defaultReminders ?? [],
        colorLabels = colorLabels ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        extra = extra ?? {};

  final String id;

  /// Unbekannte Felder (neuere App-Version), bleiben beim Speichern erhalten.
  final Map<String, dynamic> extra;

  /// Kalenderart einer neueren App-Version; wird als "Termine" angezeigt und
  /// unverändert zurückgeschrieben, solange niemand die Art ändert.
  final String? unknownKind;

  /// Lokale ID der Datenquelle (nicht im Dokument gespeichert).
  final String sourceId;
  String name;
  int color;
  CalendarKind kind;
  String emoji;
  List<Reminder> defaultReminders;

  /// Farben mit Bedeutung für Termine dieses Kalenders.
  List<ColorLabel> colorLabels;
  int sortOrder;

  /// Kalender mit Terminen aus dem Handy-Kalender einer Person (z. B.
  /// „Sarah – Google“): `{"type": "device", "owner": "Sarah", "label": "Google"}`.
  /// Nur [syncOwner] ändert diese Termine – ihr Handy gleicht sie ab.
  Map<String, dynamic>? sync;

  /// Abo eines Internet-Kalenders (ICS), z. B. Abfuhrtermine:
  /// `{"url": "https://…", "label": "Abfallwirtschaft Germersheim"}`. Die
  /// Termine kommen ausschließlich aus dem Abo – niemand ändert sie von Hand,
  /// jedes Handy gleicht sie regelmäßig ab.
  Map<String, dynamic>? subscription;
  final DateTime createdAt;
  DateTime updatedAt;
  String updatedBy;

  String get syncOwner => sync == null ? '' : jStr(sync!['owner']);
  String get syncLabel => sync == null ? '' : jStr(sync!['label'], 'Google');
  bool get isSynced => sync != null;

  bool get isSubscription => subscription != null;
  String get subscriptionUrl => subscription == null ? '' : jStr(subscription!['url']);
  String get subscriptionLabel => subscription == null ? '' : jStr(subscription!['label'], 'Internet-Kalender');

  /// Darf [user] Termine dieses Kalenders anlegen und ändern? Abo-Termine
  /// niemand – das Abo würde Änderungen beim nächsten Abgleich überschreiben.
  bool editableBy(String user) =>
      subscription == null && (sync == null || syncOwner.isEmpty || syncOwner == user);

  /// Eindeutiger Schlüssel über alle Datenquellen.
  String get key => '$sourceId/$id';
  String get path => 'calendars/$id.enc';

  /// Bedeutung einer Terminfarbe in diesem Kalender (null = keine).
  String? labelFor(int? color) {
    if (color == null) return null;
    for (final l in colorLabels) {
      if (l.color == color && l.label.isNotEmpty) return l.label;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        ...extra,
        'id': id,
        'name': name,
        'color': color,
        'kind': unknownKind != null && kind == CalendarKind.standard
            ? unknownKind
            : kind.code,
        'emoji': emoji,
        'default_reminders': defaultReminders.map((r) => r.toJson()).toList(),
        'color_labels': colorLabels.map((l) => l.toJson()).toList(),
        'sort_order': sortOrder,
        'sync': ?sync,
        'subscription': ?subscription,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'updated_by': updatedBy,
        'schema_version': kSchemaVersion,
      };

  static const _known = {
    'id', 'name', 'color', 'kind', 'emoji', 'default_reminders',
    'color_labels', 'sort_order', 'sync', 'subscription', 'created_at', 'updated_at', 'updated_by',
    'schema_version',
  };

  /// [path] (Dateipfad im Repo) liefert die ID, falls sie im Dokument fehlt.
  factory CalendarDef.fromJson(Map<String, dynamic> j, String sourceId,
      {String? path}) {
    final id = idFromPath(path) ?? jStrOrNull(j['id']);
    if (id == null || id.isEmpty) {
      throw const FormatException('Kalender ohne ID');
    }
    final kindCode = jStrOrNull(j['kind']);
    final known = CalendarKind.values.any((k) => k.code == kindCode);
    return CalendarDef(
      id: id,
      sourceId: sourceId,
      name: jStr(j['name'], 'Kalender'),
      color: jInt(j['color'], 0xFF3F7F6E),
      kind: CalendarKind.fromCode(kindCode),
      unknownKind: kindCode != null && !known ? kindCode : null,
      emoji: jStr(j['emoji']),
      defaultReminders:
          jMaps(j['default_reminders']).map(Reminder.fromJson).toList(),
      colorLabels: jMaps(j['color_labels']).map(ColorLabel.fromJson).toList(),
      sortOrder: jInt(j['sort_order'], 0),
      sync: jMap(j['sync']),
      subscription: jMap(j['subscription']),
      createdAt: jDate(j['created_at']),
      updatedAt: jDate(j['updated_at']),
      updatedBy: jStr(j['updated_by']),
      extra: unknownFields(j, _known),
    );
  }
}

enum RecurrenceFreq {
  daily('daily', 'Täglich', 'Tag', 'Tage'),
  weekly('weekly', 'Wöchentlich', 'Woche', 'Wochen'),
  monthly('monthly', 'Monatlich', 'Monat', 'Monate'),
  yearly('yearly', 'Jährlich', 'Jahr', 'Jahre');

  const RecurrenceFreq(this.code, this.label, this.unit, this.unitPlural);
  final String code;
  final String label;
  final String unit;
  final String unitPlural;

  static RecurrenceFreq fromCode(String? c) =>
      tryCode(c) ?? RecurrenceFreq.weekly;

  static RecurrenceFreq? tryCode(String? c) =>
      RecurrenceFreq.values.where((f) => f.code == c).firstOrNull;
}

/// Kürzel der Wochentage in RRULEs (Index 0 = Montag).
const kRuleDays = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

/// Wochentag mit Ordnungszahl, z. B. „2. Dienstag“ (2, 2) oder „letzter
/// Freitag“ (-1, 5); [n] = 0 heißt „jeder“ dieser Wochentage.
class NthWeekday {
  const NthWeekday(this.weekday, [this.n = 0]);

  /// 1 = Montag … 7 = Sonntag.
  final int weekday;
  final int n;

  String get code => '${n == 0 ? '' : n}${kRuleDays[weekday - 1]}';

  static NthWeekday? tryParse(String s) {
    final m = RegExp(r'^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$').firstMatch(s.trim().toUpperCase());
    if (m == null) return null;
    final n = m[1] == null ? 0 : int.parse(m[1]!.replaceFirst('+', ''));
    if (n.abs() > 53) return null;
    return NthWeekday(kRuleDays.indexOf(m[2]!) + 1, n);
  }

  @override
  bool operator ==(Object other) => other is NthWeekday && other.weekday == weekday && other.n == n;

  @override
  int get hashCode => Object.hash(weekday, n);
}

/// Wiederholung nach RFC 5545 (RRULE), in dem Umfang, den Kalender wie Google
/// anlegen: FREQ (täglich bis jährlich), INTERVAL, BYDAY (auch „2. Dienstag“),
/// BYMONTHDAY (auch „letzter Tag“), BYMONTH, BYSETPOS, WKST, UNTIL, COUNT.
///
/// Einfache Regeln (nur [byWeekday]) werden wie bisher gespeichert, damit
/// ältere App-Versionen sie lesen. Alles darüber hinaus steht als RRULE in
/// `{"freq": "rrule", "rrule": "…"}` – ältere Versionen zeigen den Termin dann
/// einmal an, statt ihn falsch zu wiederholen.
class Recurrence {
  const Recurrence({
    required this.freq,
    this.interval = 1,
    this.byWeekday = const [],
    this.byDay = const [],
    this.byMonthDay = const [],
    this.byMonth = const [],
    this.bySetPos = const [],
    this.weekStart = 1,
    this.until,
    this.count,
    this.extra = const {},
  });

  final RecurrenceFreq freq;

  /// Unbekannte Regelteile einer neueren App-Version. Sie bleiben erhalten,
  /// solange die Regel unverändert bleibt; wer die Regel hier bearbeitet,
  /// legt sie mit den Mitteln dieser Version neu fest.
  final Map<String, dynamic> extra;
  final int interval;

  /// 1 = Montag … 7 = Sonntag; nur bei wöchentlich, leer = Wochentag des Starts.
  final List<int> byWeekday;

  /// Monatlich/jährlich: Wochentage, ggf. mit Ordnungszahl („2. Dienstag“).
  final List<NthWeekday> byDay;

  /// Tage im Monat (1 … 31, negativ vom Monatsende: -1 = letzter Tag).
  final List<int> byMonthDay;

  /// Monate (1 … 12).
  final List<int> byMonth;

  /// Auswahl aus den Tagen eines Zeitraums (1 = erster, -1 = letzter).
  final List<int> bySetPos;

  /// Erster Tag der Woche (1 = Montag); zählt nur bei wöchentlich mit Abstand.
  final int weekStart;

  /// Letzter möglicher Tag (inklusive).
  final DateTime? until;

  /// Gesamtzahl der Vorkommen inkl. des ersten.
  final int? count;

  /// Mit den Mitteln älterer App-Versionen darstellbar?
  bool get isSimple =>
      byDay.isEmpty && byMonthDay.isEmpty && byMonth.isEmpty && bySetPos.isEmpty && weekStart == 1;

  /// Muster ohne Ende (FREQ … WKST), feste Reihenfolge.
  String get pattern {
    final parts = ['FREQ=${freq.code.toUpperCase()}'];
    if (interval > 1) parts.add('INTERVAL=$interval');
    if (byMonth.isNotEmpty) parts.add('BYMONTH=${(byMonth.toSet().toList()..sort()).join(',')}');
    if (byMonthDay.isNotEmpty) parts.add('BYMONTHDAY=${(byMonthDay.toSet().toList()..sort()).join(',')}');
    final days = freq == RecurrenceFreq.weekly
        ? [for (final d in byWeekday.toSet().toList()..sort()) NthWeekday(d)]
        : (byDay.toSet().toList()..sort((a, b) => a.n != b.n ? a.n.compareTo(b.n) : a.weekday.compareTo(b.weekday)));
    if (days.isNotEmpty) parts.add('BYDAY=${days.map((d) => d.code).join(',')}');
    if (bySetPos.isNotEmpty) parts.add('BYSETPOS=${(bySetPos.toSet().toList()..sort()).join(',')}');
    if (weekStart != 1) parts.add('WKST=${kRuleDays[weekStart - 1]}');
    return parts.join(';');
  }

  /// Muster (ohne UNTIL/COUNT) → Regel; null, wenn es Teile enthält, die die
  /// App nicht abbilden kann (z. B. stündlich, BYWEEKNO, BYYEARDAY).
  static Recurrence? tryParsePattern(String rule) {
    final map = <String, String>{};
    for (final p in rule.replaceFirst(RegExp(r'^RRULE:', caseSensitive: false), '').split(';')) {
      final i = p.indexOf('=');
      if (i <= 0) continue;
      map[p.substring(0, i).trim().toUpperCase()] = p.substring(i + 1).trim().toUpperCase();
    }
    final parsedFreq = RecurrenceFreq.tryCode(map['FREQ']?.toLowerCase());
    if (parsedFreq == null) return null;
    var freq = parsedFreq;
    const allowed = {'FREQ', 'INTERVAL', 'BYDAY', 'BYMONTHDAY', 'BYMONTH', 'BYSETPOS', 'WKST', 'COUNT', 'UNTIL'};
    if (map.keys.any((k) => !allowed.contains(k))) return null;
    final interval = int.tryParse(map['INTERVAL'] ?? '1') ?? 0;
    if (interval < 1 || interval > 999) return null;
    List<int>? ints(String key, int min, int max) {
      final v = map[key];
      if (v == null) return const [];
      final out = <int>[];
      for (final x in v.split(',')) {
        final n = int.tryParse(x.trim().replaceFirst('+', ''));
        if (n == null || n == 0 || n < min || n > max) return null;
        out.add(n);
      }
      return out.toSet().toList()..sort();
    }

    final byMonthDay = ints('BYMONTHDAY', -31, 31);
    final byMonth = ints('BYMONTH', 1, 12);
    final bySetPos = ints('BYSETPOS', -366, 366);
    if (byMonthDay == null || byMonth == null || bySetPos == null) return null;
    final byDay = <NthWeekday>[];
    for (final d in (map['BYDAY'] ?? '').split(',')) {
      if (d.trim().isEmpty) continue;
      final w = NthWeekday.tryParse(d);
      if (w == null) return null;
      byDay.add(w);
    }
    var weekStart = 1;
    if (map['WKST'] != null) {
      weekStart = kRuleDays.indexOf(map['WKST']!) + 1;
      if (weekStart == 0) return null;
    }
    var byWeekday = <int>[];
    switch (freq) {
      case RecurrenceFreq.daily:
        if (byMonthDay.isNotEmpty || byMonth.isNotEmpty || bySetPos.isNotEmpty) return null;
        if (byDay.isNotEmpty) {
          // „täglich, nur Mo–Fr“ = wöchentlich an diesen Tagen
          if (interval != 1 || byDay.any((d) => d.n != 0)) return null;
          freq = RecurrenceFreq.weekly;
          byWeekday = [for (final d in byDay) d.weekday];
        }
      case RecurrenceFreq.weekly:
        if (byMonthDay.isNotEmpty || byMonth.isNotEmpty || bySetPos.isNotEmpty) return null;
        if (byDay.any((d) => d.n != 0)) return null;
        byWeekday = [for (final d in byDay) d.weekday];
      case RecurrenceFreq.monthly:
        if (byDay.any((d) => d.n.abs() > 5)) return null;
      case RecurrenceFreq.yearly:
        break;
    }
    final monthlyOrYearly = freq == RecurrenceFreq.monthly || freq == RecurrenceFreq.yearly;
    return Recurrence(
      freq: freq,
      interval: interval,
      byWeekday: byWeekday.toSet().toList()..sort(),
      byDay: monthlyOrYearly ? byDay : const [],
      byMonthDay: byMonthDay,
      byMonth: byMonth,
      bySetPos: bySetPos,
      weekStart: weekStart,
    );
  }

  /// Gleichwertige, möglichst einfache Form für einen Beginn am [start]
  /// (z. B. „monatlich am 12.“ ohne BYMONTHDAY, wenn der Termin am 12. beginnt).
  Recurrence normalized(DateTime start) {
    var days = byWeekday.toSet().toList()..sort();
    var md = byMonthDay.toSet().toList()..sort();
    var months = byMonth.toSet().toList()..sort();
    var wkst = weekStart;
    switch (freq) {
      case RecurrenceFreq.daily:
        wkst = 1;
      case RecurrenceFreq.weekly:
        if (days.length == 1 && days.first == start.weekday) days = [];
        if (interval == 1 || days.length < 2) wkst = 1;
      case RecurrenceFreq.monthly:
        wkst = 1;
        if (byDay.isEmpty && bySetPos.isEmpty && months.isEmpty && md.length == 1 && md.first == start.day) md = [];
      case RecurrenceFreq.yearly:
        wkst = 1;
        if (byDay.isEmpty && bySetPos.isEmpty) {
          if (months.length == 1 && months.first == start.month && (md.isEmpty || (md.length == 1 && md.first == start.day))) {
            months = [];
            md = [];
          }
        }
    }
    return Recurrence(
      freq: freq,
      interval: interval,
      byWeekday: freq == RecurrenceFreq.weekly ? days : const [],
      byDay: byDay,
      byMonthDay: md,
      byMonth: months,
      bySetPos: bySetPos,
      weekStart: wkst,
      until: until,
      count: count,
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() => isSimple
      ? {
          ...extra,
          'freq': freq.code,
          'interval': interval,
          if (byWeekday.isNotEmpty) 'by_weekday': byWeekday,
          if (until != null) 'until': isoDate(until!),
          if (count != null) 'count': count,
        }
      : {
          'freq': 'rrule',
          'rrule': pattern,
          if (until != null) 'until': isoDate(until!),
          if (count != null) 'count': count,
        };

  static const _known = {'freq', 'interval', 'by_weekday', 'until', 'count'};

  /// null, wenn die Wiederholungsart unbekannt ist (neuere App-Version).
  static Recurrence? tryFromJson(Map<String, dynamic> j) {
    final count = jIntOrNull(j['count']);
    final until = jDate(j['until']);
    if (jStrOrNull(j['freq']) == 'rrule') {
      final r = tryParsePattern(jStr(j['rrule']));
      if (r == null || unknownFields(j, const {'freq', 'rrule', 'until', 'count'}).isNotEmpty) return null;
      return r.copyWith(until: until, count: count != null && count > 0 ? count : null);
    }
    final freq = RecurrenceFreq.tryCode(jStrOrNull(j['freq']));
    if (freq == null) return null;
    return Recurrence(
      freq: freq,
      interval: jInt(j['interval'], 1).clamp(1, 999),
      byWeekday: jInts(j['by_weekday']).where((d) => d >= 1 && d <= 7).toList(),
      until: until,
      count: count != null && count > 0 ? count : null,
      extra: unknownFields(j, _known),
    );
  }

  factory Recurrence.fromJson(Map<String, dynamic> j) =>
      tryFromJson(j) ??
      Recurrence(freq: RecurrenceFreq.weekly, extra: unknownFields(j, _known));

  Recurrence copyWith({
    RecurrenceFreq? freq,
    int? interval,
    List<int>? byWeekday,
    List<NthWeekday>? byDay,
    List<int>? byMonthDay,
    List<int>? byMonth,
    List<int>? bySetPos,
    DateTime? until,
    bool clearUntil = false,
    int? count,
    bool clearCount = false,
  }) =>
      Recurrence(
        freq: freq ?? this.freq,
        interval: interval ?? this.interval,
        byWeekday: byWeekday ?? this.byWeekday,
        byDay: byDay ?? this.byDay,
        byMonthDay: byMonthDay ?? this.byMonthDay,
        byMonth: byMonth ?? this.byMonth,
        bySetPos: bySetPos ?? this.bySetPos,
        weekStart: weekStart,
        until: clearUntil ? null : (until ?? this.until),
        count: clearCount ? null : (count ?? this.count),
      );
}

/// Ein Termin (eine Datei `events/<id>.enc`).
class CalendarEvent {
  CalendarEvent({
    String? id,
    required this.sourceId,
    required this.calendarId,
    this.title = '',
    this.allDay = false,
    required this.start,
    required this.end,
    this.timeZone = 'Europe/Berlin',
    this.location = '',
    this.description = '',
    this.url = '',
    this.color,
    this.recurrence,
    List<DateTime>? exdates,
    List<Reminder>? reminders,
    this.birthYear,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.updatedBy = '',
    Map<String, dynamic>? extra,
  })  : id = id ?? newId(),
        exdates = exdates ?? [],
        reminders = reminders ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        extra = extra ?? {};

  final String id;

  /// Unbekannte Felder (neuere App-Version), bleiben beim Speichern erhalten.
  /// Enthält auch eine Wiederholungsregel, die diese Version nicht kennt –
  /// der Termin erscheint dann nur einmal, die Regel geht nicht verloren.
  final Map<String, dynamic> extra;
  String sourceId;
  String calendarId;
  String title;
  bool allDay;

  /// Lokale Zeit. Ganztägig: nur Datum relevant, [end] = letzter Tag (inklusive).
  DateTime start;
  DateTime end;
  String timeZone;
  String location;
  String description;
  String url;
  int? color;
  Recurrence? recurrence;
  List<DateTime> exdates;
  List<Reminder> reminders;

  /// Nur Geburtstagskalender: Geburtsjahr für die Altersanzeige.
  int? birthYear;
  final DateTime createdAt;
  DateTime updatedAt;
  String updatedBy;

  String get path => 'events/$id.enc';
  String get calendarKey => '$sourceId/$calendarId';

  /// Herkunft im Handy-Kalender (nur übernommene Termine).
  Map<String, dynamic>? get google {
    final g = extra['google'];
    return g is Map ? g.cast<String, dynamic>() : null;
  }

  /// Einzelnes Vorkommen einer Serie, die die App nicht abbilden kann –
  /// änderbar nur im Ursprungskalender.
  bool get isForeignInstance => google?['instance'] != null;

  /// Wem der übernommene Termin gehört – nur sie ändert ihn, auch wenn er
  /// einem anderen Kalender zugeordnet ist ('' = ältere Übernahme ohne Angabe).
  String get googleOwner => jStr(google?['owner']);
  Duration get duration => end.difference(start);
  bool get isMultiDay => dateOnly(end).isAfter(dateOnly(start));

  CalendarEvent copy({String? id, String? title}) {
    final c = CalendarEvent.fromJson({...toJson(), 'id': id ?? this.id, 'title': ?title}, sourceId);
    // Eine Kopie mit neuer ID ist kein übernommener Google-Termin mehr.
    if (id != null && id != this.id) c.extra.remove('google');
    return c;
  }

  Map<String, dynamic> toJson() => {
        ...extra,
        'id': id,
        'calendar_id': calendarId,
        'title': title,
        'all_day': allDay,
        'start': allDay ? isoDate(start) : isoLocal(start),
        'end': allDay ? isoDate(end) : isoLocal(end),
        'time_zone': timeZone,
        if (location.isNotEmpty) 'location': location,
        if (description.isNotEmpty) 'description': description,
        if (url.isNotEmpty) 'url': url,
        if (color != null) 'color': color,
        if (recurrence != null) 'recurrence': recurrence!.toJson(),
        if (exdates.isNotEmpty) 'exdates': exdates.map(isoDate).toList(),
        'reminders': reminders.map((r) => r.toJson()).toList(),
        'birth_year': ?birthYear,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'updated_by': updatedBy,
        'schema_version': kSchemaVersion,
      };

  static const _known = {
    'id', 'calendar_id', 'title', 'all_day', 'start', 'end', 'time_zone',
    'location', 'description', 'url', 'color', 'recurrence', 'exdates',
    'reminders', 'birth_year', 'created_at', 'updated_at', 'updated_by',
    'schema_version',
  };

  /// [path] (Dateipfad im Repo) liefert die ID, falls sie im Dokument fehlt.
  /// Wirft [FormatException], wenn kein Beginn lesbar ist.
  factory CalendarEvent.fromJson(Map<String, dynamic> j, String sourceId,
      {String? path}) {
    final id = idFromPath(path) ?? jStrOrNull(j['id']);
    if (id == null || id.isEmpty) {
      throw const FormatException('Termin ohne ID');
    }
    final allDay = jBool(j['all_day'], false);
    final start = jDate(j['start']);
    if (start == null) throw const FormatException('Termin ohne Beginn');
    var end = jDate(j['end']) ?? start;
    if (end.isBefore(start)) end = start;
    final extra = unknownFields(j, _known);
    final recJson = jMap(j['recurrence']);
    final recurrence = recJson == null ? null : Recurrence.tryFromJson(recJson);
    if (recJson != null && recurrence == null) extra['recurrence'] = recJson;
    return CalendarEvent(
      id: id,
      sourceId: sourceId,
      calendarId: jStr(j['calendar_id']),
      title: jStr(j['title']),
      allDay: allDay,
      start: allDay ? dateOnly(start) : start,
      end: allDay ? dateOnly(end) : end,
      timeZone: jStr(j['time_zone'], 'Europe/Berlin'),
      location: jStr(j['location']),
      description: jStr(j['description']),
      url: jStr(j['url']),
      color: jIntOrNull(j['color']),
      recurrence: recurrence,
      exdates: jDates(j['exdates']),
      reminders: jMaps(j['reminders']).map(Reminder.fromJson).toList(),
      birthYear: jIntOrNull(j['birth_year']),
      createdAt: jDate(j['created_at']),
      updatedAt: jDate(j['updated_at']),
      updatedBy: jStr(j['updated_by']),
      extra: extra,
    );
  }
}

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
  final DateTime createdAt;
  DateTime updatedAt;
  String updatedBy;

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
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'updated_by': updatedBy,
        'schema_version': kSchemaVersion,
      };

  static const _known = {
    'id', 'name', 'color', 'kind', 'emoji', 'default_reminders',
    'color_labels', 'sort_order', 'created_at', 'updated_at', 'updated_by',
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

/// Vereinfachte RRULE: FREQ, INTERVAL, BYDAY (nur wöchentlich), UNTIL, COUNT.
class Recurrence {
  const Recurrence({
    required this.freq,
    this.interval = 1,
    this.byWeekday = const [],
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

  /// Letzter möglicher Tag (inklusive).
  final DateTime? until;

  /// Gesamtzahl der Vorkommen inkl. des ersten.
  final int? count;

  Map<String, dynamic> toJson() => {
        ...extra,
        'freq': freq.code,
        'interval': interval,
        if (byWeekday.isNotEmpty) 'by_weekday': byWeekday,
        if (until != null) 'until': isoDate(until!),
        if (count != null) 'count': count,
      };

  static const _known = {'freq', 'interval', 'by_weekday', 'until', 'count'};

  /// null, wenn die Wiederholungsart unbekannt ist (neuere App-Version).
  static Recurrence? tryFromJson(Map<String, dynamic> j) {
    final freq = RecurrenceFreq.tryCode(jStrOrNull(j['freq']));
    if (freq == null) return null;
    final count = jIntOrNull(j['count']);
    return Recurrence(
      freq: freq,
      interval: jInt(j['interval'], 1).clamp(1, 999),
      byWeekday: jInts(j['by_weekday']).where((d) => d >= 1 && d <= 7).toList(),
      until: jDate(j['until']),
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
    DateTime? until,
    bool clearUntil = false,
    int? count,
    bool clearCount = false,
  }) =>
      Recurrence(
        freq: freq ?? this.freq,
        interval: interval ?? this.interval,
        byWeekday: byWeekday ?? this.byWeekday,
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
  Duration get duration => end.difference(start);
  bool get isMultiDay => dateOnly(end).isAfter(dateOnly(start));

  CalendarEvent copy({String? id, String? title}) =>
      CalendarEvent.fromJson({...toJson(), 'id': id ?? this.id,
        'title': ?title}, sourceId);

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

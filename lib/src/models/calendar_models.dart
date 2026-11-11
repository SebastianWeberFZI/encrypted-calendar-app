import 'package:uuid/uuid.dart';

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
  const Reminder({this.minutesBefore = 0, this.push = true, this.email = false});

  final int minutesBefore;
  final bool push;
  final bool email;

  Reminder copyWith({int? minutesBefore, bool? push, bool? email}) => Reminder(
      minutesBefore: minutesBefore ?? this.minutesBefore,
      push: push ?? this.push,
      email: email ?? this.email);

  Map<String, dynamic> toJson() =>
      {'minutes_before': minutesBefore, 'push': push, 'email': email};

  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
        minutesBefore: (j['minutes_before'] as num?)?.toInt() ?? 0,
        push: j['push'] as bool? ?? true,
        email: j['email'] as bool? ?? false,
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
  const ColorLabel({required this.color, required this.label});

  final int color;
  final String label;

  Map<String, dynamic> toJson() => {'color': color, 'label': label};

  factory ColorLabel.fromJson(Map<String, dynamic> j) => ColorLabel(
        color: (j['color'] as num?)?.toInt() ?? 0xFF78909C,
        label: j['label'] as String? ?? '',
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
  })  : id = id ?? newId(),
        defaultReminders = defaultReminders ?? [],
        colorLabels = colorLabels ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;

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
        'id': id,
        'name': name,
        'color': color,
        'kind': kind.code,
        'emoji': emoji,
        'default_reminders': defaultReminders.map((r) => r.toJson()).toList(),
        'color_labels': colorLabels.map((l) => l.toJson()).toList(),
        'sort_order': sortOrder,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'updated_by': updatedBy,
        'schema_version': kSchemaVersion,
      };

  factory CalendarDef.fromJson(Map<String, dynamic> j, String sourceId) =>
      CalendarDef(
        id: j['id'] as String,
        sourceId: sourceId,
        name: j['name'] as String? ?? 'Kalender',
        color: (j['color'] as num?)?.toInt() ?? 0xFF3F7F6E,
        kind: CalendarKind.fromCode(j['kind'] as String?),
        emoji: j['emoji'] as String? ?? '',
        defaultReminders: (j['default_reminders'] as List? ?? [])
            .map((r) => Reminder.fromJson((r as Map).cast<String, dynamic>()))
            .toList(),
        colorLabels: (j['color_labels'] as List? ?? [])
            .map((l) => ColorLabel.fromJson((l as Map).cast<String, dynamic>()))
            .toList(),
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
        updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? ''),
        updatedBy: j['updated_by'] as String? ?? '',
      );
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

  static RecurrenceFreq fromCode(String? c) => RecurrenceFreq.values
      .firstWhere((f) => f.code == c, orElse: () => RecurrenceFreq.weekly);
}

/// Vereinfachte RRULE: FREQ, INTERVAL, BYDAY (nur wöchentlich), UNTIL, COUNT.
class Recurrence {
  const Recurrence({
    required this.freq,
    this.interval = 1,
    this.byWeekday = const [],
    this.until,
    this.count,
  });

  final RecurrenceFreq freq;
  final int interval;

  /// 1 = Montag … 7 = Sonntag; nur bei wöchentlich, leer = Wochentag des Starts.
  final List<int> byWeekday;

  /// Letzter möglicher Tag (inklusive).
  final DateTime? until;

  /// Gesamtzahl der Vorkommen inkl. des ersten.
  final int? count;

  Map<String, dynamic> toJson() => {
        'freq': freq.code,
        'interval': interval,
        if (byWeekday.isNotEmpty) 'by_weekday': byWeekday,
        if (until != null) 'until': isoDate(until!),
        if (count != null) 'count': count,
      };

  factory Recurrence.fromJson(Map<String, dynamic> j) => Recurrence(
        freq: RecurrenceFreq.fromCode(j['freq'] as String?),
        interval: (j['interval'] as num?)?.toInt().clamp(1, 999) ?? 1,
        byWeekday: (j['by_weekday'] as List? ?? [])
            .map((e) => (e as num).toInt())
            .toList(),
        until: DateTime.tryParse(j['until'] as String? ?? ''),
        count: (j['count'] as num?)?.toInt(),
      );

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
  })  : id = id ?? newId(),
        exdates = exdates ?? [],
        reminders = reminders ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
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

  factory CalendarEvent.fromJson(Map<String, dynamic> j, String sourceId) {
    final allDay = j['all_day'] as bool? ?? false;
    final start = DateTime.parse(j['start'] as String);
    var end = DateTime.tryParse(j['end'] as String? ?? '') ?? start;
    if (end.isBefore(start)) end = start;
    return CalendarEvent(
      id: j['id'] as String,
      sourceId: sourceId,
      calendarId: j['calendar_id'] as String? ?? '',
      title: j['title'] as String? ?? '',
      allDay: allDay,
      start: allDay ? dateOnly(start) : start,
      end: allDay ? dateOnly(end) : end,
      timeZone: j['time_zone'] as String? ?? 'Europe/Berlin',
      location: j['location'] as String? ?? '',
      description: j['description'] as String? ?? '',
      url: j['url'] as String? ?? '',
      color: (j['color'] as num?)?.toInt(),
      recurrence: j['recurrence'] == null
          ? null
          : Recurrence.fromJson((j['recurrence'] as Map).cast<String, dynamic>()),
      exdates: (j['exdates'] as List? ?? [])
          .map((e) => DateTime.tryParse(e as String))
          .whereType<DateTime>()
          .toList(),
      reminders: (j['reminders'] as List? ?? [])
          .map((r) => Reminder.fromJson((r as Map).cast<String, dynamic>()))
          .toList(),
      birthYear: (j['birth_year'] as num?)?.toInt(),
      createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? ''),
      updatedBy: j['updated_by'] as String? ?? '',
    );
  }
}

import 'package:system_calendar/system_calendar.dart';

/// Ein Kalender auf dem Handy (z. B. ein Google-Kalender von Sarahs Konto).
class DeviceCalendar {
  const DeviceCalendar({
    required this.id,
    required this.name,
    this.account = '',
    this.accountType = '',
    this.owner = '',
    this.color = 0xFF4285F4,
    this.accessLevel = 700,
    this.primary = false,
    this.visible = true,
  });

  final int id;
  final String name;
  final String account;
  final String accountType;
  final String owner;
  final int color;

  /// CalendarContract: 500 = Mitwirkender (darf schreiben), 700 = Eigentümer.
  final int accessLevel;
  final bool primary;
  final bool visible;

  bool get writable => accessLevel >= 500;
  bool get isGoogle => accountType == 'com.google';

  /// Hauptkalender eines Kontos (bei Google: der mit der E-Mail-Adresse).
  bool get isMain => primary || (owner.isNotEmpty && owner == account && name == account);

  String get label => account.isEmpty || account == name ? name : '$name ($account)';

  factory DeviceCalendar.fromRow(Map<String, Object?> r) => DeviceCalendar(
        id: _int(r['_id']) ?? -1,
        name: _str(r['calendar_displayName']),
        account: _str(r['account_name']),
        accountType: _str(r['account_type']),
        owner: _str(r['ownerAccount']),
        color: (_int(r['calendar_color']) ?? 0xFF4285F4) | 0xFF000000,
        accessLevel: _int(r['calendar_access_level']) ?? 0,
        primary: _int(r['isPrimary']) == 1,
        visible: _int(r['visible']) != 0,
      );
}

/// Ein Termin im Kalenderspeicher des Handys (Spalten von CalendarContract.Events).
class DeviceEvent {
  const DeviceEvent({
    required this.id,
    required this.calendarId,
    this.title = '',
    this.description = '',
    this.location = '',
    required this.dtstart,
    this.dtend,
    this.duration,
    this.allDay = false,
    this.timeZone = 'UTC',
    this.rrule,
    this.rdate,
    this.exdate,
    this.originalId,
    this.originalInstanceTime,
    this.status,
    this.deleted = false,
    this.customAppPackage,
    this.customAppUri,
  });

  final int id;
  final int calendarId;
  final String title;
  final String description;
  final String location;
  final int dtstart;
  final int? dtend;
  final String? duration;
  final bool allDay;
  final String timeZone;
  final String? rrule;
  final String? rdate;
  final String? exdate;

  /// Ausnahme einer Serie: ID der Serie und Beginn des ersetzten Vorkommens.
  final int? originalId;
  final int? originalInstanceTime;

  /// 0 vorläufig, 1 bestätigt, 2 abgesagt.
  final int? status;
  final bool deleted;
  final String? customAppPackage;
  final String? customAppUri;

  bool get isException => originalId != null;
  bool get canceled => status == 2;
  bool get recurring => (rrule ?? '').isNotEmpty || (rdate ?? '').isNotEmpty;

  factory DeviceEvent.fromRow(Map<String, Object?> r) => DeviceEvent(
        id: _int(r['_id']) ?? -1,
        calendarId: _int(r['calendar_id']) ?? -1,
        title: _str(r['title']),
        description: _str(r['description']),
        location: _str(r['eventLocation']),
        dtstart: _int(r['dtstart']) ?? 0,
        dtend: _int(r['dtend']),
        duration: _strOrNull(r['duration']),
        allDay: _int(r['allDay']) == 1,
        timeZone: _str(r['eventTimezone'], 'UTC'),
        rrule: _strOrNull(r['rrule']),
        rdate: _strOrNull(r['rdate']),
        exdate: _strOrNull(r['exdate']),
        originalId: _int(r['original_id']),
        originalInstanceTime: _int(r['originalInstanceTime']),
        status: _int(r['eventStatus']),
        deleted: _int(r['deleted']) == 1,
        customAppPackage: _strOrNull(r['customAppPackage']),
        customAppUri: _strOrNull(r['customAppUri']),
      );
}

/// Zugriff auf die Kalender des Handys – im Test durch eine Attrappe ersetzt.
abstract class DeviceCalendarApi {
  Future<bool> hasPermission();
  Future<List<DeviceCalendar>> calendars();

  /// Termine der Kalender, die nach [fromMillis] noch stattfinden (ohne gelöschte).
  Future<List<DeviceEvent>> events(List<int> calendarIds, int fromMillis);

  /// Termine per ID, auch als gelöscht markierte.
  Future<List<DeviceEvent>> eventsByIds(List<int> ids);
  Future<List<(int, int)>> instances(int eventId, int fromMillis, int toMillis);
  Future<int> insert(Map<String, Object?> values);
  Future<void> update(int id, Map<String, Object?> values);
  Future<void> delete(int id);
}

/// Die echte Umsetzung über das Plugin `system_calendar`.
class AndroidCalendarApi implements DeviceCalendarApi {
  const AndroidCalendarApi();

  @override
  Future<bool> hasPermission() => SystemCalendar.hasPermission();

  @override
  Future<List<DeviceCalendar>> calendars() async =>
      (await SystemCalendar.calendars()).map(DeviceCalendar.fromRow).toList();

  @override
  Future<List<DeviceEvent>> events(List<int> calendarIds, int fromMillis) async =>
      (await SystemCalendar.events(calendarIds: calendarIds, fromMillis: fromMillis))
          .map(DeviceEvent.fromRow)
          .toList();

  @override
  Future<List<DeviceEvent>> eventsByIds(List<int> ids) async {
    final out = <DeviceEvent>[];
    // In Portionen, damit die Abfrage nicht zu lang wird.
    for (var i = 0; i < ids.length; i += 200) {
      out.addAll((await SystemCalendar.eventsByIds(ids.skip(i).take(200).toList())).map(DeviceEvent.fromRow));
    }
    return out;
  }

  @override
  Future<List<(int, int)>> instances(int eventId, int fromMillis, int toMillis) async => [
        for (final r in await SystemCalendar.instances(eventId, fromMillis, toMillis))
          (_int(r['begin']) ?? 0, _int(r['end']) ?? 0),
      ];

  @override
  Future<int> insert(Map<String, Object?> values) => SystemCalendar.insertEvent(values);

  @override
  Future<void> update(int id, Map<String, Object?> values) => SystemCalendar.updateEvent(id, values);

  @override
  Future<void> delete(int id) => SystemCalendar.deleteEvent(id);
}

int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : (v is String ? int.tryParse(v) : null));
String _str(Object? v, [String fallback = '']) => v is String ? v : (v == null ? fallback : v.toString());
String? _strOrNull(Object? v) {
  final s = v?.toString();
  return s == null || s.isEmpty ? null : s;
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models/json_util.dart';

enum CalendarViewMode { month, week, agenda }

/// Geräte-lokale Einstellungen (nicht synchronisiert, keine Geheimnisse).
class LocalSettings {
  LocalSettings._(this._p);

  final SharedPreferences _p;

  static Future<LocalSettings> load() async =>
      LocalSettings._(await SharedPreferences.getInstance());

  Future<void> reload() => _p.reload();

  // ---------------------------------------------------------------- Profil
  String get userName => _p.getString('user_name') ?? '';
  set userName(String v) => _p.setString('user_name', v);

  // ---------------------------------------------------------------- Ansicht
  Set<String> get hiddenCalendars =>
      (_p.getStringList('hidden_calendars') ?? const []).toSet();
  set hiddenCalendars(Set<String> v) =>
      _p.setStringList('hidden_calendars', v.toList());

  bool get showHolidays => _p.getBool('show_holidays') ?? true;
  set showHolidays(bool v) => _p.setBool('show_holidays', v);

  String get holidayState => _p.getString('holiday_state') ?? 'BW';
  set holidayState(String v) => _p.setString('holiday_state', v);

  bool get showCalendarBar => _p.getBool('show_calendar_bar') ?? true;
  set showCalendarBar(bool v) => _p.setBool('show_calendar_bar', v);

  CalendarViewMode get viewMode => CalendarViewMode.values.firstWhere(
      (m) => m.name == _p.getString('view_mode'),
      orElse: () => CalendarViewMode.month);
  set viewMode(CalendarViewMode v) => _p.setString('view_mode', v.name);

  int get themeColor => _p.getInt('theme_color') ?? 0xFF3F7F6E;
  set themeColor(int v) => _p.setInt('theme_color', v);

  // ---------------------------------------------------------------- Widgets
  /// null = alle sichtbaren Kalender.
  Set<String>? get widgetCalendars {
    final l = _p.getStringList('widget_calendars');
    return l?.toSet();
  }

  set widgetCalendars(Set<String>? v) => v == null
      ? _p.remove('widget_calendars')
      : _p.setStringList('widget_calendars', v.toList());

  bool get widgetShowHolidays => _p.getBool('widget_holidays') ?? true;
  set widgetShowHolidays(bool v) => _p.setBool('widget_holidays', v);

  // ---------------------------------------------------------------- Push
  bool get pushEnabled => _p.getBool('push_enabled') ?? true;
  set pushEnabled(bool v) => _p.setBool('push_enabled', v);

  // ---------------------------------------------------------------- E-Mail
  EmailSettings get email {
    final raw = _p.getString('email_settings');
    if (raw == null) return EmailSettings();
    try {
      return EmailSettings.fromJson(jMap(jsonDecode(raw)) ?? {});
    } on FormatException {
      return EmailSettings();
    }
  }

  set email(EmailSettings v) =>
      _p.setString('email_settings', jsonEncode(v.toJson()));

  /// Bereits versandte Mail-Erinnerungen (Schlüssel -> Zeitpunkt).
  Map<String, String> get sentMails {
    try {
      final m = jMap(jsonDecode(_p.getString('sent_mails') ?? '{}')) ?? {};
      return {
        for (final e in m.entries)
          if (e.value is String) e.key: e.value as String,
      };
    } on FormatException {
      return {};
    }
  }
  set sentMails(Map<String, String> v) =>
      _p.setString('sent_mails', jsonEncode(v));

  String get lastAgendaMail => _p.getString('last_agenda_mail') ?? '';
  set lastAgendaMail(String v) => _p.setString('last_agenda_mail', v);

  // ---------------------------------------------------------------- Laufzeit
  /// Herzschlag der Vordergrund-App; der Hintergrund-Worker pausiert solange.
  DateTime? get foregroundBeat =>
      DateTime.tryParse(_p.getString('foreground_beat') ?? '');
  set foregroundBeat(DateTime? v) => v == null
      ? _p.remove('foreground_beat')
      : _p.setString('foreground_beat', v.toIso8601String());
}

class EmailSettings {
  EmailSettings({
    this.enabled = false,
    this.host = '',
    this.port = 587,
    this.ssl = false,
    this.username = '',
    this.from = '',
    this.to = '',
    this.dailyAgenda = false,
    this.dailyAgendaHour = 7,
    Set<String>? excludedCalendars,
    Map<String, dynamic>? extra,
  })  : excludedCalendars = excludedCalendars ?? {},
        extra = extra ?? {};

  /// Einstellungen einer anderen App-Version – bleiben erhalten.
  final Map<String, dynamic> extra;

  bool enabled;
  String host;
  int port;

  /// true = SSL/TLS direkt (Port 465), false = STARTTLS bzw. unverschlüsselt.
  bool ssl;
  String username;
  String from;
  String to;
  bool dailyAgenda;
  int dailyAgendaHour;
  Set<String> excludedCalendars;

  bool get isComplete => host.isNotEmpty && to.isNotEmpty;

  Map<String, dynamic> toJson() => {
        ...extra,
        'enabled': enabled,
        'host': host,
        'port': port,
        'ssl': ssl,
        'username': username,
        'from': from,
        'to': to,
        'daily_agenda': dailyAgenda,
        'daily_agenda_hour': dailyAgendaHour,
        'excluded': excludedCalendars.toList(),
      };

  static const _known = {
    'enabled', 'host', 'port', 'ssl', 'username', 'from', 'to',
    'daily_agenda', 'daily_agenda_hour', 'excluded',
  };

  factory EmailSettings.fromJson(Map<String, dynamic> j) => EmailSettings(
        enabled: jBool(j['enabled'], false),
        host: jStr(j['host']),
        port: jInt(j['port'], 587),
        ssl: jBool(j['ssl'], false),
        username: jStr(j['username']),
        from: jStr(j['from']),
        to: jStr(j['to']),
        dailyAgenda: jBool(j['daily_agenda'], false),
        dailyAgendaHour: jInt(j['daily_agenda_hour'], 7).clamp(0, 23),
        excludedCalendars: jStrings(j['excluded']).toSet(),
        extra: unknownFields(j, _known),
      );
}

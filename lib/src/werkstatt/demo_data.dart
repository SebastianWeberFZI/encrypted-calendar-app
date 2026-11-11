import '../models/calendar_models.dart';

/// Beispieltermine rund um heute – nur im Werkstatt-Modus, damit die
/// Ansichten beim Design-Review gefüllt sind.
List<CalendarEvent> demoEvents(List<CalendarDef> calendars, {required String user}) {
  CalendarDef? cal(String name) => calendars.where((c) => c.name == name).firstOrNull;
  final today = dateOnly(DateTime.now());
  final monday = today.subtract(Duration(days: today.weekday - 1));
  DateTime day(int offset, [int h = 0, int m = 0]) =>
      DateTime(today.year, today.month, today.day + offset, h, m);
  DateTime wd(int week, int weekday, [int h = 0, int m = 0]) =>
      DateTime(monday.year, monday.month, monday.day + week * 7 + weekday - 1, h, m);

  final out = <CalendarEvent>[];
  void add(String calendar, String title, DateTime start, DateTime end,
      {bool allDay = false, String location = '', String description = '', Recurrence? rec,
      List<Reminder> reminders = const [], int? birthYear, int? color}) {
    final c = cal(calendar);
    if (c == null) return;
    out.add(CalendarEvent(
      sourceId: c.sourceId,
      calendarId: c.id,
      title: title,
      start: start,
      end: end,
      allDay: allDay,
      location: location,
      description: description,
      recurrence: rec,
      reminders: reminders,
      birthYear: birthYear,
      color: color,
      updatedBy: user,
    ));
  }

  const yearly = Recurrence(freq: RecurrenceFreq.yearly);
  // Geburtstage
  add('Geburtstage', 'Mama', day(3), day(3), allDay: true, rec: yearly, birthYear: 1962,
      reminders: const [Reminder(minutesBefore: 1440), Reminder(minutesBefore: 0, email: true)]);
  add('Geburtstage', 'Lukas', day(12), day(12), allDay: true, rec: yearly, birthYear: 1991);
  add('Geburtstage', 'Oma Hilde', day(-6), day(-6), allDay: true, rec: yearly, birthYear: 1938);
  add('Geburtstage', 'Jana', day(24), day(24), allDay: true, rec: yearly, birthYear: 1994);

  // Gemeinsam
  add('Gemeinsam', 'Yoga', wd(-2, 2, 18, 30), wd(-2, 2, 19, 45),
      location: 'Yogaloft Südstadt',
      rec: const Recurrence(freq: RecurrenceFreq.weekly, byWeekday: [2]),
      reminders: const [Reminder(minutesBefore: 60)], color: 0xFF5BAA5E);
  add('Gemeinsam', 'Wocheneinkauf', wd(-2, 6, 10), wd(-2, 6, 11),
      rec: const Recurrence(freq: RecurrenceFreq.weekly, byWeekday: [6]));
  add('Gemeinsam', 'Abendessen bei Jana & Tim', wd(0, 6, 19), wd(0, 6, 22, 30),
      location: 'Kaiserstraße 12', description: 'Nachtisch mitbringen!',
      reminders: const [Reminder(minutesBefore: 120, email: true)], color: 0xFF9B59B6);
  add('Gemeinsam', 'Kino', wd(1, 5, 20, 15), wd(1, 5, 22, 30), location: 'Schauburg');
  add('Gemeinsam', 'Zahnarzt Sebastian', day(2, 8, 30), day(2, 9, 15),
      location: 'Praxis Dr. Berger', reminders: const [Reminder(minutesBefore: 1440, push: true, email: true)],
      color: 0xFF4A74D9);
  add('Gemeinsam', 'Brunch mit Eltern', wd(2, 7, 11), wd(2, 7, 14), color: 0xFF9B59B6);
  add('Gemeinsam', 'Hausversammlung', day(9, 19), day(9, 20, 30), color: 0xFFE05A5A);

  // Orte
  add('Orte', 'Wochenende Schwarzwald', wd(1, 5), wd(1, 7), allDay: true,
      location: 'Hinterzarten', description: 'Ferienwohnung „Tannenblick“, Check-in ab 15 Uhr');
  add('Orte', 'Sebastian in Berlin', wd(2, 2), wd(2, 4), allDay: true, location: 'Berlin');
  add('Orte', 'Urlaub Lissabon', day(30), day(37), allDay: true, location: 'Lissabon');

  // TODOs
  add('TODOs', 'Steuererklärung abgeben', day(5), day(5), allDay: true,
      reminders: const [Reminder(minutesBefore: 2880, email: true)], color: 0xFFE05A5A);
  add('TODOs', 'Fahrrad zur Inspektion', day(1), day(1), allDay: true);
  add('TODOs', 'Rauchmelder testen', day(15), day(15), allDay: true);
  add('TODOs', 'Müll rausstellen', wd(-1, 4), wd(-1, 4), allDay: true,
      rec: const Recurrence(freq: RecurrenceFreq.weekly, interval: 2, byWeekday: [4]));

  // Privat
  add('Privat', 'Laufen', wd(-1, 1, 7), wd(-1, 1, 7, 45),
      rec: const Recurrence(freq: RecurrenceFreq.weekly, byWeekday: [1, 4]));
  add('Arbeit', 'Teammeeting', wd(-1, 3, 9, 30), wd(-1, 3, 10, 30),
      rec: const Recurrence(freq: RecurrenceFreq.weekly, byWeekday: [3]), color: 0xFF2A9FD6);
  add('Arbeit', 'Projektabgabe', day(8), day(8), allDay: true, color: 0xFFF08C3A);
  return out;
}

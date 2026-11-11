import '../models/calendar_models.dart';

/// Vorschläge für die ersten Kalender einer neuen Datenquelle.
List<CalendarDef> calendarTemplates(String sourceId, {bool private = false}) => private
    ? [
        CalendarDef(sourceId: sourceId, name: 'Privat', emoji: '🔒', color: 0xFF6A5ACD,
            defaultReminders: const [Reminder(minutesBefore: 30)]),
        CalendarDef(sourceId: sourceId, name: 'Arbeit', emoji: '💼', color: 0xFF78909C,
            defaultReminders: const [Reminder(minutesBefore: 15)],
            colorLabels: const [
              ColorLabel(color: 0xFF2A9FD6, label: 'Meeting'),
              ColorLabel(color: 0xFFF08C3A, label: 'Deadline'),
            ]),
      ]
    : [
        CalendarDef(sourceId: sourceId, name: 'Gemeinsam', emoji: '💞', color: 0xFF2E9C8E,
            defaultReminders: const [Reminder(minutesBefore: 60)],
            colorLabels: const [
              ColorLabel(color: 0xFFE05A5A, label: 'Wichtig'),
              ColorLabel(color: 0xFF4A74D9, label: 'Arzt & Behörden'),
              ColorLabel(color: 0xFF5BAA5E, label: 'Sport'),
              ColorLabel(color: 0xFF9B59B6, label: 'Freunde & Familie'),
            ]),
        CalendarDef(sourceId: sourceId, name: 'Geburtstage', emoji: '🎂', color: 0xFFE0609A,
            kind: CalendarKind.birthdays,
            defaultReminders: const [Reminder(minutesBefore: 1440), Reminder(minutesBefore: 0)]),
        CalendarDef(sourceId: sourceId, name: 'Orte', emoji: '📍', color: 0xFF4A74D9),
        CalendarDef(sourceId: sourceId, name: 'TODOs', emoji: '✅', color: 0xFFF08C3A,
            defaultReminders: const [Reminder(minutesBefore: 0)],
            colorLabels: const [ColorLabel(color: 0xFFE05A5A, label: 'Dringend')]),
      ];

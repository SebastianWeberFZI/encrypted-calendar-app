import 'package:mailer/mailer.dart' as mailer;
import 'package:mailer/smtp_server.dart';

import '../calendar_repository.dart';
import '../models/calendar_models.dart';
import '../models/occurrences.dart';
import '../settings.dart';
import '../ui/format.dart';

/// E-Mail-Benachrichtigungen direkt vom Handy (SMTP).
///
/// Versand durch den Hintergrund-Worker (ca. alle 15 Min.) und – solange die
/// App offen ist – minütlich. Mails können daher bis ~15 Min. vor dem
/// Erinnerungszeitpunkt kommen; verpasste werden bis zu 6 h nachgeholt,
/// sofern der Termin noch nicht vorbei ist.
class EmailService {
  static const lookAhead = Duration(minutes: 15);
  static const catchUp = Duration(hours: 6);

  static Future<void> send(EmailSettings s, String password,
      {required String subject, required String body}) async {
    final server = SmtpServer(
      s.host,
      port: s.port,
      ssl: s.ssl,
      allowInsecure: true, // erlaubt Server ohne STARTTLS (z. B. Werkstatt)
      username: s.username.isEmpty ? null : s.username,
      password: password.isEmpty ? null : password,
    );
    final from = s.from.isNotEmpty ? s.from : s.username;
    final msg = mailer.Message()
      ..from = mailer.Address(from, 'Kalender')
      ..recipients.add(s.to)
      ..subject = subject
      ..text = body;
    await mailer.send(msg, server, timeout: const Duration(seconds: 30));
  }

  /// Verschickt fällige Mail-Erinnerungen und ggf. die tägliche Agenda.
  /// Liefert die Anzahl versandter Mails.
  static Future<int> dispatchDue(
      CalendarRepository repo, LocalSettings settings, String? password,
      {DateTime? now}) async {
    final s = settings.email;
    if (!s.enabled || !s.isComplete) return 0;
    now ??= DateTime.now();
    var count = 0;
    final sent = Map.of(settings.sentMails);
    final keys = {
      for (final c in repo.calendars)
        if (!s.excludedCalendars.contains(c.key)) c.key
    };
    final occ = repo.occurrences(now.subtract(const Duration(days: 1)),
        now.add(const Duration(days: 2)),
        calendarKeys: keys);
    for (final o in occ) {
      final e = o.event!;
      for (var i = 0; i < e.reminders.length; i++) {
        final r = e.reminders[i];
        if (!r.email) continue;
        final at = reminderTime(o, r);
        final key = '${o.key}#$i';
        if (sent.containsKey(key)) continue;
        if (at.isAfter(now.add(lookAhead)) || at.isBefore(now.subtract(catchUp))) {
          continue;
        }
        final ended = o.allDay ? o.endDay.add(const Duration(days: 1)) : o.end;
        if (ended.isBefore(now)) continue;
        await send(s, password ?? '',
            subject: 'Erinnerung: ${o.title} – ${_whenShort(o, now)}',
            body: reminderBody(o, repo));
        sent[key] = now.toIso8601String();
        count++;
      }
    }
    // Alte Einträge aufräumen
    sent.removeWhere((_, v) =>
        (DateTime.tryParse(v) ?? now!).isBefore(now!.subtract(const Duration(days: 8))));
    settings.sentMails = sent;

    final today = isoDate(now);
    if (s.dailyAgenda &&
        now.hour >= s.dailyAgendaHour &&
        settings.lastAgendaMail != today) {
      final dayOcc = repo.occurrences(dateOnly(now),
          dateOnly(now).add(const Duration(days: 1)),
          calendarKeys: keys);
      await send(s, password ?? '',
          subject: 'Deine Termine am ${fmtDayHeader(now)}',
          body: agendaBody(now, dayOcc, repo));
      settings.lastAgendaMail = today;
      count++;
    }
    return count;
  }

  static String _whenShort(Occurrence o, DateTime now) {
    final day = relativeDay(o.start, now: now).toLowerCase();
    final d = day.contains(',') ? fmtDayHeader(o.start) : day;
    return o.allDay ? d : '$d ${fmtTime(o.start)} Uhr';
  }

  static String reminderBody(Occurrence o, CalendarRepository repo) {
    final e = o.event!;
    final b = StringBuffer()
      ..writeln(o.title)
      ..writeln(o.allDay
          ? '${fmtDateLong(o.start)}${o.isMultiDay ? ' bis ${fmtDateLong(o.end)}' : ''}'
          : '${fmtDateLong(o.start)}, ${occurrenceTimeText(o)} Uhr');
    if (e.location.isNotEmpty) b.writeln('Ort: ${e.location}');
    if (o.calendar != null) b.writeln('Kalender: ${o.calendar!.name}');
    if (e.description.isNotEmpty) b..writeln()..writeln(e.description);
    b..writeln()..writeln('– gesendet von deiner Kalender-App');
    return b.toString();
  }

  static String agendaBody(
      DateTime day, List<Occurrence> occ, CalendarRepository repo) {
    final b = StringBuffer()..writeln(fmtDateLong(day))..writeln();
    if (occ.isEmpty) b.writeln('Keine Termine – genieß den Tag!');
    for (final o in occ) {
      final loc = o.event?.location ?? '';
      b.writeln('• ${occurrenceTimeText(o, day: day).padRight(11)} ${o.title}'
          '${loc.isEmpty ? '' : ' ($loc)'}');
    }
    b..writeln()..writeln('– gesendet von deiner Kalender-App');
    return b.toString();
  }
}

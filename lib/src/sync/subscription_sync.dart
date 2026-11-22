import 'package:http/http.dart' as http;

import '../calendar_repository.dart';
import '../core/app_log.dart';
import '../core/doc_store.dart';
import '../models/calendar_models.dart';
import '../settings.dart';
import 'ics.dart';
import 'ics_fetch.dart';

/// Gegenstück für den Abgleich eines Abos (im Test ein Speicher im Arbeitsspeicher).
abstract class SubscriptionData {
  List<CalendarEvent> eventsOf(CalendarDef cal);

  /// Gleiche Eingabe = gleiche Termin-ID auf allen Handys derselben Datenquelle.
  Future<String> eventId(CalendarDef cal, String key);
  Future<void> saveEvent(CalendarEvent e);
  Future<void> deleteEvent(CalendarEvent e);
}

/// Die Repo-Daten der App.
class RepoSubscriptionData implements SubscriptionData {
  RepoSubscriptionData(this.repo);
  final CalendarRepository repo;

  @override
  List<CalendarEvent> eventsOf(CalendarDef cal) =>
      repo.events.where((e) => e.calendarKey == cal.key).toList();

  @override
  Future<String> eventId(CalendarDef cal, String key) {
    final src = repo.source(cal.sourceId);
    if (src == null) throw StateError('Datenquelle ${cal.sourceId} fehlt');
    return repo.crypto.deterministicId('abo|${cal.id}|$key', src.key);
  }

  @override
  Future<void> saveEvent(CalendarEvent e) => repo.saveEvent(e);
  @override
  Future<void> deleteEvent(CalendarEvent e) => repo.deleteEvent(e);
}

class SubscriptionResult {
  int added = 0, changed = 0, removed = 0, total = 0;
  final List<String> log = [];

  bool get changedAny => added + changed + removed > 0;

  String get summary {
    final parts = [
      if (added > 0) '$added neu',
      if (changed > 0) '$changed geändert',
      if (removed > 0) '$removed entfernt',
    ];
    return '$total Termine${parts.isEmpty ? ', unverändert' : ' – ${parts.join(', ')}'}';
  }
}

/// Bringt einen Abo-Kalender auf den Stand einer iCalendar-Datei.
///
/// Termin-IDs entstehen aus Kalender, Tag (bzw. Beginn) und Titel – nicht aus
/// der UID der Datei, die manche Anbieter (z. B. Abfallkalender) bei jedem
/// Abruf neu würfeln. So legen beide Handys dieselben Termine an, ohne
/// Doppelte und ohne Konflikte; ein verlegter Termin ist ein neuer.
class SubscriptionSync {
  SubscriptionSync(this.data, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final SubscriptionData data;
  final DateTime Function() _now;

  static String keyOf(IcsEvent e) =>
      '${e.allDay ? isoDate(e.start) : isoLocal(e.start)}|${e.summary.trim().toLowerCase()}';

  Future<SubscriptionResult> apply(CalendarDef cal, List<IcsEvent> feed) async {
    final res = SubscriptionResult();
    final today = dateOnly(_now());
    final existing = {for (final e in data.eventsOf(cal)) e.id: e};

    final wanted = <String, CalendarEvent>{};
    for (final f in feed) {
      final key = keyOf(f);
      final id = await data.eventId(cal, key);
      if (wanted.containsKey(id)) continue; // doppelt in der Datei
      wanted[id] = _toEvent(cal, id, f, existing[id]);
    }
    res.total = wanted.length;

    for (final e in wanted.values) {
      final old = existing[e.id];
      if (old != null && sameDocContent(old.toJson(), e.toJson())) continue;
      await data.saveEvent(e);
      if (old == null) {
        res.added++;
        res.log.add('+ ${_label(e)}');
      } else {
        res.changed++;
        res.log.add('~ ${_label(e)}');
      }
    }

    // Fehlende Termine entfernen – aber nur, wo die Datei Auskunft gibt:
    // Viele Anbieter liefern nur „ab heute“. Vergangenes und Heutiges bleibt
    // dann stehen; liefert die Datei auch Vergangenes, gilt sie ab ihrem
    // frühesten Termin. Eine leere Datei entfernt nichts.
    if (wanted.isNotEmpty) {
      final earliest = wanted.values.map((e) => dateOnly(e.start)).reduce((a, b) => a.isBefore(b) ? a : b);
      final cutoff = earliest.isBefore(today) ? earliest : today.add(const Duration(days: 1));
      for (final e in existing.values) {
        if (wanted.containsKey(e.id)) continue;
        final r = e.recurrence;
        final reaches = r == null
            ? !dateOnly(e.start).isBefore(cutoff)
            : (r.until == null || !r.until!.isBefore(cutoff));
        if (!reaches) continue;
        await data.deleteEvent(e);
        res.removed++;
        res.log.add('− ${_label(e)}');
      }
    }
    return res;
  }

  CalendarEvent _toEvent(CalendarDef cal, String id, IcsEvent f, CalendarEvent? old) {
    final title = f.summary.trim().isEmpty ? cal.name : f.summary.trim();
    final lower = title.toLowerCase();
    final color = cal.colorLabels
        .where((l) => l.label.trim().isNotEmpty && l.label.trim().toLowerCase() == lower)
        .firstOrNull
        ?.color;
    return CalendarEvent(
      id: id,
      sourceId: cal.sourceId,
      calendarId: cal.id,
      title: title,
      allDay: f.allDay,
      start: f.start,
      end: f.end,
      location: f.location,
      description: f.description == f.summary.trim() ? '' : f.description,
      url: f.url,
      color: color,
      recurrence: f.recurrence,
      exdates: List.of(f.exdates)..sort(),
      reminders: List.of(cal.defaultReminders),
      // Fester Wert, damit beide Handys dasselbe Dokument erzeugen.
      createdAt: dateOnly(f.start),
      updatedAt: old?.updatedAt,
      updatedBy: old?.updatedBy ?? '',
      extra: old == null ? null : Map.of(old.extra),
    );
  }

  static String _label(CalendarEvent e) {
    final d = e.start;
    final day = '${d.day}.${d.month}.${d.year}';
    return e.allDay ? '$day ${e.title}' : '$day ${isoLocal(d).substring(11, 16)} ${e.title}';
  }
}

/// Abruf der Abos auf diesem Handy: höchstens alle [interval], nach einem
/// Fehler frühestens nach [retry] erneut.
class SubscriptionService {
  static const interval = Duration(hours: 12);
  static const retry = Duration(hours: 1);
  static bool _running = false;

  static bool isDue(SubscriptionStatus? st, DateTime now) {
    if (st == null) return true;
    final tried = st.lastTry;
    if (tried != null && !now.isBefore(tried) && now.difference(tried) < retry) return false;
    final ok = st.lastOk;
    return ok == null || now.isBefore(ok) || now.difference(ok) >= interval;
  }

  /// Ruft fällige Abos ab (mit [force] alle bzw. nur [onlyKey]) und gleicht
  /// ihre Termine ab. Ergebnis je Kalender-Schlüssel; leer, wenn nichts fällig.
  static Future<Map<String, SubscriptionResult>> refreshDue(
    CalendarRepository repo,
    LocalSettings settings, {
    bool force = false,
    String? onlyKey,
    http.Client? client,
  }) async {
    final out = <String, SubscriptionResult>{};
    if (_running) return out;
    final cals = [
      for (final c in repo.calendars)
        if (c.isSubscription && c.subscriptionUrl.isNotEmpty && (onlyKey == null || c.key == onlyKey)) c,
    ];
    if (cals.isEmpty) return out;
    _running = true;
    try {
      await settings.reload(); // der andere Prozess (App/Hintergrund) schreibt auch
      for (final cal in cals) {
        final now = DateTime.now();
        final status = settings.subscriptionStatus;
        final st = status[cal.key] ?? SubscriptionStatus();
        if (!force && !isDue(status[cal.key], now)) continue;
        st.lastTry = now;
        try {
          final text = await fetchIcs(cal.subscriptionUrl, client: client);
          final List<IcsEvent> feed;
          try {
            feed = parseIcs(text);
          } on FormatException catch (e) {
            throw IcsFetchException(e.message);
          }
          final r = await SubscriptionSync(RepoSubscriptionData(repo)).apply(cal, feed);
          out[cal.key] = r;
          st
            ..lastOk = now
            ..error = ''
            ..count = r.total
            ..summary = r.summary;
          AppLog.info('abo', '${cal.name}: ${r.summary}');
          for (final line in r.log) {
            AppLog.info('abo', '${cal.name}: $line');
          }
          if (feed.isEmpty) AppLog.warn('abo', '${cal.name}: Datei ohne Termine – nichts entfernt');
        } catch (e) {
          st.error = '$e';
          AppLog.warn('abo', '${cal.name}: Abruf fehlgeschlagen: $e');
        }
        final latest = settings.subscriptionStatus;
        latest[cal.key] = st;
        settings.subscriptionStatus = latest;
      }
    } finally {
      _running = false;
    }
    return out;
  }

  /// Vorschau für den Editor: Termine der Adresse, ohne etwas zu speichern.
  static Future<List<IcsEvent>> preview(String url, {http.Client? client}) async {
    final text = await fetchIcs(url, client: client);
    try {
      return parseIcs(text);
    } on FormatException catch (e) {
      throw IcsFetchException(e.message);
    }
  }
}

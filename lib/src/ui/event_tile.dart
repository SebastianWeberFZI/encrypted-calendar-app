import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/occurrences.dart';
import 'event_detail_sheet.dart';
import 'format.dart';
import 'theme.dart';

/// Listeneintrag für ein Vorkommen (Tagesliste, Woche, Agenda).
class EventTile extends StatelessWidget {
  const EventTile({super.key, required this.state, required this.occ, this.day, this.dense = false});

  final AppState state;
  final Occurrence occ;
  final DateTime? day;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = Color(occ.color);
    final timeText = occurrenceTimeText(occ, day: day);
    final loc = occ.event?.location ?? '';
    final sub = [
      ?occ.colorLabel,
      if (loc.isNotEmpty) loc,
      if (occ.calendar != null && state.calendars.length > 1) occ.calendar!.name,
      if (occ.holiday) 'Feiertag',
    ].join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: occ.holiday ? null : () => showEventDetail(context, state, occ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 5 : 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 62,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: occ.allDay || occ.isMultiDay
                  ? Text(occ.isMultiDay && !occ.allDay ? timeText : 'ganztägig',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(fmtTime(occ.start),
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      if (!occ.end.isAtSameMomentAs(occ.start))
                        Text(fmtTime(occ.end),
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                    ]),
            ),
          ),
          Container(
            width: 4,
            height: dense ? 32 : 40,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
                color: occ.holiday ? kSundayColor : color,
                borderRadius: BorderRadius.circular(2)),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '${occ.emoji.isEmpty ? '' : '${occ.emoji} '}${occ.title}',
                style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: occ.holiday ? kSundayColor : null),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (sub.isNotEmpty)
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              if (occ.isMultiDay && occ.allDay)
                Text(timeText,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
          if (occ.event?.recurrence != null)
            Icon(Icons.repeat, size: 16, color: theme.colorScheme.outline),
          if (occ.event?.reminders.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(
                  occ.event!.reminders.any((r) => r.email)
                      ? Icons.mark_email_unread_outlined
                      : Icons.notifications_none,
                  size: 16,
                  color: theme.colorScheme.outline),
            ),
        ]),
      ),
    );
  }
}

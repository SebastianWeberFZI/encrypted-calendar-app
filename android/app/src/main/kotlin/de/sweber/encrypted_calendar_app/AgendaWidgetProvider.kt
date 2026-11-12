package de.sweber.encrypted_calendar_app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import java.time.LocalDate

/** Agenda-Widget: scrollbare Liste der nächsten Termine mit Tagesüberschriften. */
class AgendaWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val today = LocalDate.now()
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_agenda)
            val snap = WidgetData.load(context)
            views.setTextViewText(R.id.agenda_title,
                "${WidgetData.weekdaysShort[today.dayOfWeek.value - 1]}., ${today.dayOfMonth}. ${WidgetData.months[today.monthValue - 1]}")
            views.setInt(R.id.agenda_title, "setTextColor", snap.theme)
            val svc = Intent(context, AgendaWidgetService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
            }
            views.setRemoteAdapter(R.id.agenda_list, svc)
            views.setEmptyView(R.id.agenda_list, R.id.agenda_empty)
            // Vorlage ohne URI: jeder Eintrag liefert sein Datum per Fill-in-Intent
            views.setPendingIntentTemplate(R.id.agenda_list,
                WidgetData.launchIntent(context, null, id * 16 + 4, mutable = true))
            views.setOnClickPendingIntent(R.id.agenda_title,
                WidgetData.launchIntent(context, "kalender://day?date=$today", id * 16 + 5))
            views.setOnClickPendingIntent(R.id.agenda_add,
                WidgetData.launchIntent(context, "kalender://new?date=$today", id * 16 + 6))
            views.setOnClickPendingIntent(R.id.agenda_settings, WidgetData.configIntent(context, id))
            manager.updateAppWidget(id, views)
        }
        manager.notifyAppWidgetViewDataChanged(ids, R.id.agenda_list)
    }

    override fun onDeleted(context: Context, ids: IntArray) = WidgetPrefs.remove(context, ids)
}

class AgendaWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        AgendaFactory(applicationContext, intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, 0))
}

private class AgendaFactory(private val context: Context, private val widgetId: Int) :
    RemoteViewsService.RemoteViewsFactory {
    private sealed class Row {
        data class Header(val day: LocalDate, val holiday: Boolean) : Row()
        data class Event(val day: LocalDate, val ev: WidgetEvent) : Row()
    }

    private var rows: List<Row> = emptyList()

    override fun onCreate() {}
    override fun onDestroy() {}

    override fun onDataSetChanged() {
        val snap = WidgetData.load(context).forWidget(context, widgetId)
        val today = LocalDate.now()
        val out = ArrayList<Row>()
        for (i in 0 until 30) {
            val d = today.plusDays(i.toLong())
            val evs = snap.events.filter {
                if (it.multiDay) (it.start == d || (i == 0 && it.covers(d))) else it.start == d
            }.sortedWith(compareBy<WidgetEvent>({ if (it.holiday) 0 else if (it.allDay) 1 else 2 }, { it.time }))
            if (evs.isEmpty()) continue
            out.add(Row.Header(d, evs.any { it.holiday }))
            evs.forEach { out.add(Row.Event(d, it)) }
        }
        rows = out
    }

    override fun getCount() = rows.size
    override fun getViewTypeCount() = 2
    override fun getItemId(position: Int) = position.toLong()
    override fun hasStableIds() = false
    override fun getLoadingView(): RemoteViews? = null

    override fun getViewAt(position: Int): RemoteViews {
        val today = LocalDate.now()
        return when (val r = rows[position]) {
            is Row.Header -> RemoteViews(context.packageName, R.layout.widget_agenda_header).apply {
                val rel = when (r.day) {
                    today -> "Heute · "
                    today.plusDays(1) -> "Morgen · "
                    else -> ""
                }
                setTextViewText(R.id.header_text,
                    "$rel${WidgetData.weekdays[r.day.dayOfWeek.value - 1]}, ${r.day.dayOfMonth}. ${WidgetData.months[r.day.monthValue - 1]}")
                val color = when {
                    r.holiday || r.day.dayOfWeek.value == 7 -> 0xFFD9534F.toInt()
                    r.day.dayOfWeek.value == 6 -> 0xFF3F7FBF.toInt()
                    else -> 0xFF6E675F.toInt()
                }
                setTextColor(R.id.header_text, color)
                setOnClickFillInIntent(R.id.header_text, Intent().setData(Uri.parse("kalender://day?date=${r.day}")))
            }
            is Row.Event -> RemoteViews(context.packageName, R.layout.widget_agenda_item).apply {
                val e = r.ev
                setInt(R.id.item_bar, "setBackgroundColor", if (e.holiday) 0xFFD9534F.toInt() else e.color)
                setTextViewText(R.id.item_time, when {
                    e.holiday -> "Feiertag"
                    e.multiDay -> "${e.start.dayOfMonth}.–${e.end.dayOfMonth}.${e.end.monthValue}."
                    e.allDay -> "ganztägig"
                    else -> e.time
                })
                setTextViewText(R.id.item_title, e.title)
                setTextViewText(R.id.item_sub, e.location)
                setViewVisibility(R.id.item_sub, if (e.location.isEmpty()) android.view.View.GONE else android.view.View.VISIBLE)
                setOnClickFillInIntent(R.id.item_root, Intent().setData(Uri.parse("kalender://day?date=${r.day}")))
            }
        }
    }
}

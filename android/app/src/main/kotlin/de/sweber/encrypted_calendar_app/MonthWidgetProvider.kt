package de.sweber.encrypted_calendar_app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import kotlin.math.max
import kotlin.math.min

/**
 * Monats-Widget: scrollbare Liste von Wochenzeilen ab der aktuellen Woche (ein halbes
 * Jahr), farbige Terminbalken wie in der App. Tippen auf einen Tag öffnet direkt den
 * Termin-Editor für dieses Datum. Kalenderauswahl je Widget über das Zahnrad.
 */
class MonthWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) update(context, manager, id)
        manager.notifyAppWidgetViewDataChanged(ids, R.id.month_list)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle) {
        update(context, manager, id)
        manager.notifyAppWidgetViewDataChanged(intArrayOf(id), R.id.month_list)
    }

    override fun onDeleted(context: Context, ids: IntArray) = WidgetPrefs.remove(context, ids)

    private fun update(context: Context, manager: AppWidgetManager, id: Int) {
        val snap = WidgetData.load(context)
        val today = LocalDate.now()
        val views = RemoteViews(context.packageName, R.layout.widget_month)
        // Titel = heute (ein Monatsname wäre beim Scrollen irreführend; Monatswechsel stehen fett in den Zeilen)
        views.setTextViewText(R.id.month_title,
            "${WidgetData.weekdaysShort[today.dayOfWeek.value - 1]}., ${today.dayOfMonth}. ${WidgetData.months[today.monthValue - 1]}")
        views.setInt(R.id.month_title, "setTextColor", snap.theme)
        val svc = Intent(context, MonthWidgetService::class.java).apply {
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
        }
        views.setRemoteAdapter(R.id.month_list, svc)
        views.setPendingIntentTemplate(R.id.month_list, WidgetData.launchIntent(context, null, id * 16 + 1, mutable = true))
        views.setOnClickPendingIntent(R.id.month_title, WidgetData.launchIntent(context, "kalender://day?date=$today", id * 16 + 2))
        views.setOnClickPendingIntent(R.id.month_add, WidgetData.launchIntent(context, "kalender://new?date=$today", id * 16 + 3))
        views.setOnClickPendingIntent(R.id.month_settings, WidgetData.configIntent(context, id))
        manager.updateAppWidget(id, views)
    }
}

class MonthWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        MonthFactory(applicationContext, intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, 0))
}

private class MonthFactory(private val context: Context, private val widgetId: Int) :
    RemoteViewsService.RemoteViewsFactory {

    companion object {
        const val WEEKS = 26
        const val ROW_DP = 58f
        val dayIds = intArrayOf(R.id.d0, R.id.d1, R.id.d2, R.id.d3, R.id.d4, R.id.d5, R.id.d6)
    }

    private var snap = WidgetSnapshot(emptyList(), 0)
    private var firstWeek: LocalDate = LocalDate.now()
    private var widthPx = 600
    private var scale = 2f

    override fun onCreate() {}
    override fun onDestroy() {}

    override fun onDataSetChanged() {
        snap = WidgetData.load(context).forWidget(context, widgetId)
        val today = LocalDate.now()
        firstWeek = today.minusDays((today.dayOfWeek.value - 1).toLong())
        val opts = AppWidgetManager.getInstance(context).getAppWidgetOptions(widgetId)
        val wDp = max(opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 300), 160)
        scale = min(context.resources.displayMetrics.density, 2.5f)
        widthPx = max(((wDp - 12) * scale).toInt(), 100)
    }

    override fun getCount() = WEEKS
    override fun getViewTypeCount() = 1
    override fun getItemId(position: Int) = position.toLong()
    override fun hasStableIds() = true
    override fun getLoadingView(): RemoteViews? = null

    override fun getViewAt(position: Int): RemoteViews {
        val ws = firstWeek.plusDays(position * 7L)
        return RemoteViews(context.packageName, R.layout.widget_month_week).apply {
            setImageViewBitmap(R.id.week_img,
                WeekPainter.draw(snap, ws, LocalDate.now(), widthPx, (ROW_DP * scale).toInt(), scale))
            for (i in 0 until 7) {
                val d = ws.plusDays(i.toLong())
                setOnClickFillInIntent(dayIds[i], Intent().setData(Uri.parse("kalender://new?date=$d")))
                setContentDescription(dayIds[i],
                    "${WidgetData.weekdays[i]}, ${d.dayOfMonth}. ${WidgetData.months[d.monthValue - 1]} – Termin anlegen")
            }
        }
    }
}

/** Zeichnet eine Wochenzeile: Tageszahlen und Terminbalken (mehrtägige durchgehend). */
object WeekPainter {
    private class Item(val ev: WidgetEvent, val c0: Int, val c1: Int, val slot: Int)

    private val sunday = Color.parseColor("#D9534F")
    private val saturday = Color.parseColor("#3F7FBF")
    private val ink = Color.parseColor("#2A2724")
    private val muted = Color.parseColor("#8C857C")
    private val line = Color.parseColor("#22000000")

    fun draw(snap: WidgetSnapshot, ws: LocalDate, today: LocalDate, w: Int, h: Int, s: Float): Bitmap {
        val bmp = Bitmap.createBitmap(max(w, 50), max(h, 30), Bitmap.Config.ARGB_8888)
        val cv = Canvas(bmp)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        val text = Paint(Paint.ANTI_ALIAS_FLAG)
        val we = ws.plusDays(6)
        val cellW = w / 7f
        val numH = 17f * s
        val slotH = 13f * s
        val maxSlots = max(1, ((h - numH - 2 * s) / slotH).toInt())

        p.color = line
        p.strokeWidth = max(1f, s * 0.5f)
        cv.drawLine(0f, 0f, w.toFloat(), 0f, p)
        val holidays = snap.events.filter { it.holiday }

        // Tageszahlen (der 1. eines Monats mit Monatsnamen – beim Scrollen die Orientierung)
        text.textAlign = Paint.Align.CENTER
        text.textSize = 10.5f * s
        for (i in 0 until 7) {
            val d = ws.plusDays(i.toLong())
            val cx = cellW * i + cellW / 2
            val label = if (d.dayOfMonth == 1) "1. ${WidgetData.monthsShort[d.monthValue - 1]}" else "${d.dayOfMonth}"
            text.typeface = Typeface.create(Typeface.DEFAULT,
                if (d == today || d.dayOfMonth == 1) Typeface.BOLD else Typeface.NORMAL)
            if (d == today) {
                p.color = snap.theme
                cv.drawRoundRect(RectF(cx - 10f * s, 2f * s, cx + 10f * s, 15f * s), 7f * s, 7f * s, p)
                text.color = Color.WHITE
            } else {
                text.color = when {
                    i == 6 || holidays.any { it.covers(d) } -> sunday
                    i == 5 -> saturday
                    d.isBefore(today) -> muted
                    else -> ink
                }
            }
            cv.drawText(label, cx, 12.5f * s, text)
        }

        // Einträge auf Zeilen verteilen: Feiertage, dann mehrtägige (längste zuerst), dann der Rest
        val evs = snap.events.filter { !it.end.isBefore(ws) && !it.start.isAfter(we) }
            .sortedWith(compareBy<WidgetEvent>(
                { if (it.holiday) 0 else if (it.multiDay) 1 else if (it.allDay) 2 else 3 },
                { it.start }, { -ChronoUnit.DAYS.between(it.start, it.end) }, { it.time }))
        val used = Array(7) { HashSet<Int>() }
        val items = ArrayList<Item>()
        for (e in evs) {
            val c0 = if (e.start.isBefore(ws)) 0 else ChronoUnit.DAYS.between(ws, e.start).toInt()
            val c1 = if (e.end.isAfter(we)) 6 else ChronoUnit.DAYS.between(ws, e.end).toInt()
            var slot = 0
            while ((c0..c1).any { used[it].contains(slot) }) slot++
            for (c in c0..c1) used[c].add(slot)
            items.add(Item(e, c0, c1, slot))
        }
        val overflow = BooleanArray(7) { c -> used[c].any { it >= maxSlots } }
        val hidden = IntArray(7)
        text.typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
        text.textAlign = Paint.Align.LEFT
        text.textSize = 9.5f * s
        for (it in items) {
            var show = it.slot < maxSlots
            if (show && it.slot == maxSlots - 1 && (it.c0..it.c1).any { c -> overflow[c] }) show = false
            if (!show) {
                for (c in it.c0..it.c1) hidden[c]++
                continue
            }
            val e = it.ev
            // Balken, die in der Vor-/Folgewoche weitergehen, laufen bis an den Rand
            val contLeft = e.start.isBefore(ws)
            val contRight = e.end.isAfter(we)
            val l = if (contLeft) 0f else it.c0 * cellW + 1.5f * s
            val r = if (contRight) w.toFloat() else (it.c1 + 1) * cellW - 1.5f * s
            val t = numH + it.slot * slotH
            val rect = RectF(l, t, r, t + slotH - 1.5f * s)
            when {
                e.holiday -> { p.color = (sunday and 0x00FFFFFF) or 0x18000000; text.color = sunday }
                e.allDay || e.multiDay -> { p.color = e.color; text.color = Color.WHITE }
                else -> { p.color = (e.color and 0x00FFFFFF) or 0x2A000000; text.color = darken(e.color) }
            }
            cv.drawRoundRect(rect, 3f * s, 3f * s, p)
            if (contLeft) cv.drawRect(RectF(l, rect.top, l + 4f * s, rect.bottom), p)
            if (contRight) cv.drawRect(RectF(r - 4f * s, rect.top, r, rect.bottom), p)
            cv.save()
            cv.clipRect(rect)
            cv.drawText(e.title, max(l, 0f) + 2.5f * s, t + slotH - 4.5f * s, text)
            cv.restore()
        }
        text.color = muted
        text.textAlign = Paint.Align.CENTER
        text.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        for (c in 0 until 7) {
            if (hidden[c] > 0) {
                cv.drawText("+${hidden[c]}", c * cellW + cellW / 2, numH + (maxSlots - 1) * slotH + slotH - 4.5f * s, text)
            }
        }
        return bmp
    }

    private fun darken(c: Int): Int {
        val hsv = FloatArray(3)
        Color.colorToHSV(c, hsv)
        hsv[2] = hsv[2] * 0.62f
        return Color.HSVToColor(hsv)
    }
}

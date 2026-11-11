package de.sweber.encrypted_calendar_app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Bundle
import android.widget.RemoteViews
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import kotlin.math.max
import kotlin.math.min

/**
 * Monats-/Mehrwochen-Widget: zeigt ab der aktuellen Woche so viele Wochen,
 * wie in die Widget-Höhe passen (2–6), mit farbigen Terminbalken wie in der App.
 * Gezeichnet wird ein Bitmap in Widget-Größe.
 */
class MonthWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) update(context, manager, id)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle) {
        update(context, manager, id)
    }

    private fun update(context: Context, manager: AppWidgetManager, id: Int) {
        val opts = manager.getAppWidgetOptions(id)
        val density = context.resources.displayMetrics.density
        val wDp = max(opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 300), 160)
        val hDp = max(opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 280), 120)
        val snapshot = WidgetData.load(context)
        val today = LocalDate.now()
        val weekStart = today.minusDays((today.dayOfWeek.value - 1).toLong())

        val headerDp = 34f
        val gridHDp = hDp - headerDp - 8f
        val weeks = min(6, max(2, (gridHDp / 46f).toInt()))
        val lastDay = weekStart.plusDays(weeks * 7L - 1)

        val views = RemoteViews(context.packageName, R.layout.widget_month)
        val title = if (weekStart.month == lastDay.month) {
            "${WidgetData.months[weekStart.monthValue - 1]} ${weekStart.year}"
        } else {
            "${WidgetData.monthsShort[weekStart.monthValue - 1]} – ${WidgetData.monthsShort[lastDay.monthValue - 1]} ${lastDay.year}"
        }
        views.setTextViewText(R.id.month_title, title)
        views.setInt(R.id.month_title, "setTextColor", snapshot.theme)
        val scale = min(density, 2.5f)
        val bmp = drawGrid(snapshot, weekStart, weeks, today, (wDp - 12) * scale, gridHDp * scale, scale)
        views.setImageViewBitmap(R.id.month_grid, bmp)
        views.setOnClickPendingIntent(R.id.month_grid,
            WidgetData.launchIntent(context, "kalender://day?date=$today", 100 + id))
        views.setOnClickPendingIntent(R.id.month_title,
            WidgetData.launchIntent(context, "kalender://day?date=$today", 200 + id))
        views.setOnClickPendingIntent(R.id.month_add,
            WidgetData.launchIntent(context, "kalender://new?date=$today", 300 + id))
        manager.updateAppWidget(id, views)
    }

    private class Item(val ev: WidgetEvent, val c0: Int, val c1: Int, var slot: Int = 0)

    private fun drawGrid(
        snap: WidgetSnapshot, weekStart: LocalDate, weeks: Int, today: LocalDate,
        widthPx: Float, heightPx: Float, s: Float,
    ): Bitmap {
        val w = max(widthPx.toInt(), 50)
        val h = max(heightPx.toInt(), 50)
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val cv = Canvas(bmp)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        val text = Paint(Paint.ANTI_ALIAS_FLAG)
        val sunday = Color.parseColor("#D9534F")
        val saturday = Color.parseColor("#3F7FBF")
        val ink = Color.parseColor("#2A2724")
        val muted = Color.parseColor("#8C857C")
        val line = Color.parseColor("#22000000")

        val headH = 16f * s
        val cellW = w / 7f
        val rowH = (h - headH) / weeks
        val numH = 17f * s
        val slotH = 13f * s
        val maxSlots = max(1, ((rowH - numH - 2 * s) / slotH).toInt())

        // Wochentage
        text.textSize = 10f * s
        text.textAlign = Paint.Align.CENTER
        text.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        for (i in 0 until 7) {
            text.color = when (i) { 6 -> sunday; 5 -> saturday; else -> muted }
            cv.drawText(WidgetData.weekdaysShort[i], cellW * i + cellW / 2, 11f * s, text)
        }
        val holidays = snap.events.filter { it.holiday }

        for (wk in 0 until weeks) {
            val ws = weekStart.plusDays(wk * 7L)
            val we = ws.plusDays(6)
            val top = headH + wk * rowH
            p.color = line
            p.strokeWidth = max(1f, s * 0.5f)
            cv.drawLine(0f, top, w.toFloat(), top, p)

            // Tageszahlen
            for (i in 0 until 7) {
                val d = ws.plusDays(i.toLong())
                val cx = cellW * i + cellW / 2
                val isHoliday = holidays.any { it.covers(d) }
                val label = if (d.dayOfMonth == 1) "${d.dayOfMonth}. ${WidgetData.monthsShort[d.monthValue - 1]}" else "${d.dayOfMonth}"
                text.textSize = 10.5f * s
                text.typeface = Typeface.create(Typeface.DEFAULT, if (d == today) Typeface.BOLD else Typeface.NORMAL)
                if (d == today) {
                    p.color = snap.theme
                    val r = RectF(cx - 10f * s, top + 2f * s, cx + 10f * s, top + 15f * s)
                    cv.drawRoundRect(r, 7f * s, 7f * s, p)
                    text.color = Color.WHITE
                } else {
                    text.color = when {
                        i == 6 || isHoliday -> sunday
                        i == 5 -> saturday
                        d.isBefore(today) -> muted
                        else -> ink
                    }
                }
                cv.drawText(label, cx, top + 12.5f * s, text)
            }

            // Einträge auf Slots verteilen (mehrtägige zuerst)
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
                if (!show) { for (c in it.c0..it.c1) hidden[c]++; continue }
                val l = it.c0 * cellW + 1.5f * s
                val r = (it.c1 + 1) * cellW - 1.5f * s
                val t = top + numH + it.slot * slotH
                val rect = RectF(l, t, r, t + slotH - 1.5f * s)
                val e = it.ev
                when {
                    e.holiday -> { p.color = (sunday and 0x00FFFFFF) or 0x18000000; text.color = sunday }
                    e.allDay || e.multiDay -> { p.color = e.color; text.color = Color.WHITE }
                    else -> { p.color = (e.color and 0x00FFFFFF) or 0x2A000000; text.color = darken(e.color) }
                }
                cv.drawRoundRect(rect, 3f * s, 3f * s, p)
                cv.save()
                cv.clipRect(rect)
                cv.drawText(e.title, l + 2.5f * s, t + slotH - 4.5f * s, text)
                cv.restore()
            }
            text.color = muted
            text.textAlign = Paint.Align.CENTER
            text.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            for (c in 0 until 7) {
                if (hidden[c] > 0) {
                    cv.drawText("+${hidden[c]}", c * cellW + cellW / 2, top + numH + (maxSlots - 1) * slotH + slotH - 4.5f * s, text)
                }
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

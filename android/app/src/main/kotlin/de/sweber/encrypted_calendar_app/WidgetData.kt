package de.sweber.encrypted_calendar_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject
import java.time.LocalDate

/** Ein Termin-Vorkommen, wie es die App für die Widgets aufbereitet. */
data class WidgetEvent(
    val title: String,
    val color: Int,
    val start: LocalDate,
    val end: LocalDate,
    val time: String,
    val timeEnd: String,
    val holiday: Boolean,
    val location: String,
    val calendarKey: String,
) {
    val allDay: Boolean get() = time.isEmpty()
    val multiDay: Boolean get() = end.isAfter(start)
    fun covers(d: LocalDate) = !d.isBefore(start) && !d.isAfter(end)
}

/** Ein Kalender, wie er in der Widget-Konfiguration zur Auswahl steht. */
data class WidgetCalendar(val key: String, val name: String, val color: Int, val emoji: String, val source: String)

data class WidgetSnapshot(
    val events: List<WidgetEvent>,
    val theme: Int,
    val calendars: List<WidgetCalendar> = emptyList(),
    /** Auswahl für Widgets ohne eigene Konfiguration (null = alle). */
    val defaultKeys: Set<String>? = null,
    val defaultHolidays: Boolean = true,
) {
    /** Termine für ein bestimmtes Widget: eigene Kalenderauswahl oder der Standard. */
    fun forWidget(context: Context, id: Int): WidgetSnapshot {
        val cfg = WidgetPrefs.get(context, id)
        val keys = cfg?.keys ?: defaultKeys
        val holidays = cfg?.holidays ?: defaultHolidays
        return copy(events = events.filter { e ->
            if (e.holiday) holidays else keys == null || e.calendarKey in keys
        })
    }
}

class WidgetConfig(val keys: Set<String>, val holidays: Boolean)

/** Kalenderauswahl je Widget-Instanz (SharedPreferences der App). */
object WidgetPrefs {
    private const val FILE = "widget_config"

    fun get(context: Context, id: Int): WidgetConfig? {
        val p = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        if (!p.getBoolean("set_$id", false)) return null
        return WidgetConfig(p.getStringSet("cal_$id", emptySet())?.toSet() ?: emptySet(), p.getBoolean("hol_$id", true))
    }

    fun put(context: Context, id: Int, cfg: WidgetConfig) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
            .putBoolean("set_$id", true)
            .putStringSet("cal_$id", HashSet(cfg.keys))
            .putBoolean("hol_$id", cfg.holidays)
            .apply()
    }

    fun remove(context: Context, ids: IntArray) {
        val e = context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
        for (id in ids) e.remove("set_$id").remove("cal_$id").remove("hol_$id")
        e.apply()
    }
}

object WidgetData {
    const val LAUNCH_ACTION = "es.antonborri.home_widget.action.LAUNCH"
    private const val DEFAULT_THEME = 0xFF3F7F6E

    fun load(context: Context): WidgetSnapshot {
        val raw = HomeWidgetPlugin.getData(context).getString("calendar_data", null)
            ?: return WidgetSnapshot(emptyList(), DEFAULT_THEME.toInt())
        return try {
            val json = JSONObject(raw)
            val events = ArrayList<WidgetEvent>()
            json.optJSONArray("events")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    // Einzelne unlesbare Einträge überspringen statt das Widget zu leeren.
                    try { events.add(
                        WidgetEvent(
                            title = o.optString("t"),
                            color = o.optLong("c", DEFAULT_THEME).toInt(),
                            start = LocalDate.parse(o.getString("s")),
                            end = LocalDate.parse(o.getString("e")),
                            time = o.optString("h"),
                            timeEnd = o.optString("he"),
                            holiday = o.optBoolean("hol"),
                            location = o.optString("loc"),
                            calendarKey = o.optString("k"),
                        )
                    ) } catch (_: Exception) { }
                }
            }
            val calendars = ArrayList<WidgetCalendar>()
            json.optJSONArray("calendars")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    calendars.add(WidgetCalendar(o.optString("k"), o.optString("n"),
                        o.optLong("c", DEFAULT_THEME).toInt(), o.optString("e"), o.optString("s")))
                }
            }
            val defaults = json.optJSONArray("default_keys")?.let { arr ->
                (0 until arr.length()).mapNotNull { arr.optString(it, null) }.toSet()
            }
            WidgetSnapshot(events, json.optLong("theme", DEFAULT_THEME).toInt(), calendars, defaults,
                json.optBoolean("default_holidays", true))
        } catch (e: Exception) {
            WidgetSnapshot(emptyList(), DEFAULT_THEME.toInt())
        }
    }

    /**
     * Öffnet die App über home_widget (Flutter erhält die URI). Ohne [uri] ist es eine
     * Vorlage für Listen-Widgets: die URI kommt dann per Fill-in-Intent je Eintrag.
     */
    fun launchIntent(context: Context, uri: String?, requestCode: Int, mutable: Boolean = false): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = LAUNCH_ACTION
            if (uri != null) data = Uri.parse(uri)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (mutable) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE)
        return PendingIntent.getActivity(context, requestCode, intent, flags)
    }

    /** Öffnet die Kalenderauswahl für genau dieses Widget. */
    fun configIntent(context: Context, id: Int): PendingIntent {
        val intent = Intent(context, WidgetConfigActivity::class.java).apply {
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            data = Uri.parse("kalender-widget://config/$id") // je Widget eindeutig
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        return PendingIntent.getActivity(context, id * 16 + 9, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Ein einzelnes Widget neu zeichnen lassen (z. B. nach geänderter Auswahl). */
    fun refresh(context: Context, id: Int) {
        val manager = AppWidgetManager.getInstance(context)
        val info = manager.getAppWidgetInfo(id) ?: return
        context.sendBroadcast(Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).apply {
            component = info.provider
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, intArrayOf(id))
        })
    }

    val weekdaysShort = arrayOf("Mo", "Di", "Mi", "Do", "Fr", "Sa", "So")
    val weekdays = arrayOf("Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag")
    val months = arrayOf("Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August",
        "September", "Oktober", "November", "Dezember")
    val monthsShort = arrayOf("Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.",
        "Sep.", "Okt.", "Nov.", "Dez.")
}

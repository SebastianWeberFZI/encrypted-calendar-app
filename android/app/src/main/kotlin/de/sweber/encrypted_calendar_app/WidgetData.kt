package de.sweber.encrypted_calendar_app

import android.app.PendingIntent
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
) {
    val allDay: Boolean get() = time.isEmpty()
    val multiDay: Boolean get() = end.isAfter(start)
    fun covers(d: LocalDate) = !d.isBefore(start) && !d.isAfter(end)
}

data class WidgetSnapshot(val events: List<WidgetEvent>, val theme: Int)

object WidgetData {
    const val LAUNCH_ACTION = "es.antonborri.home_widget.action.LAUNCH"

    fun load(context: Context): WidgetSnapshot {
        val raw = HomeWidgetPlugin.getData(context).getString("calendar_data", null)
            ?: return WidgetSnapshot(emptyList(), 0xFF3F7F6E.toInt())
        return try {
            val json = JSONObject(raw)
            val arr = json.optJSONArray("events")
            val list = ArrayList<WidgetEvent>()
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    list.add(
                        WidgetEvent(
                            title = o.optString("t"),
                            color = o.optLong("c", 0xFF3F7F6E).toInt(),
                            start = LocalDate.parse(o.getString("s")),
                            end = LocalDate.parse(o.getString("e")),
                            time = o.optString("h"),
                            timeEnd = o.optString("he"),
                            holiday = o.optBoolean("hol"),
                            location = o.optString("loc"),
                        )
                    )
                }
            }
            WidgetSnapshot(list, json.optLong("theme", 0xFF3F7F6E).toInt())
        } catch (e: Exception) {
            WidgetSnapshot(emptyList(), 0xFF3F7F6E.toInt())
        }
    }

    /** Öffnet die App über home_widget (Flutter erhält die URI). */
    fun launchIntent(context: Context, uri: String, requestCode: Int, mutable: Boolean = false): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = LAUNCH_ACTION
            data = Uri.parse(uri)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (mutable) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE)
        return PendingIntent.getActivity(context, requestCode, intent, flags)
    }

    val weekdaysShort = arrayOf("Mo", "Di", "Mi", "Do", "Fr", "Sa", "So")
    val weekdays = arrayOf("Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag")
    val months = arrayOf("Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August",
        "September", "Oktober", "November", "Dezember")
    val monthsShort = arrayOf("Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.",
        "Sep.", "Okt.", "Nov.", "Dez.")
}

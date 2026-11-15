package de.sweber.encrypted_calendar_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import java.time.LocalDate
import java.time.ZoneId

/**
 * Datumswechsel für die Widgets: Überschrift („Fr., 13. Nov.“) und die Markierung
 * von heute hängen nur am Datum – ohne neue Termine würde nichts sie neu zeichnen.
 * Ein Wecker kurz nach Mitternacht zeichnet beide Widgets neu (kein exakter Alarm,
 * darf im Ruhezustand etwas später kommen); ebenso nach Neustart, App-Update und
 * nach dem Stellen von Uhr oder Zeitzone.
 */
object DayTicker {
    private const val ACTION = "de.sweber.encrypted_calendar_app.DAY_CHANGED"
    private const val REQUEST = 7101

    fun schedule(context: Context) {
        val am = context.getSystemService(AlarmManager::class.java) ?: return
        val next = LocalDate.now().plusDays(1).atStartOfDay(ZoneId.systemDefault())
            .plusMinutes(1).toInstant().toEpochMilli()
        val pi = PendingIntent.getBroadcast(
            context, REQUEST,
            Intent(context, DayChangeReceiver::class.java).setAction(ACTION),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        am.setAndAllowWhileIdle(AlarmManager.RTC, next, pi)
    }

    fun refreshWidgets(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val month = manager.getAppWidgetIds(ComponentName(context, MonthWidgetProvider::class.java))
        if (month.isNotEmpty()) MonthWidgetProvider().onUpdate(context, manager, month)
        val agenda = manager.getAppWidgetIds(ComponentName(context, AgendaWidgetProvider::class.java))
        if (agenda.isNotEmpty()) AgendaWidgetProvider().onUpdate(context, manager, agenda)
    }
}

/** Wecker nach Mitternacht sowie Neustart, App-Update, Uhr- und Zeitzonenwechsel. */
class DayChangeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        DayTicker.refreshWidgets(context)
        DayTicker.schedule(context)
    }
}

package de.sweber.system_calendar

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.Executors

/**
 * Lesen und Schreiben im Kalenderspeicher von Android (CalendarContract).
 * Läuft auch im Hintergrund-Isolate (dort ohne Activity, also ohne Rückfrage
 * nach der Berechtigung). Alle Zugriffe auf den Speicher laufen in einem
 * eigenen Thread.
 */
class SystemCalendarPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var binding: ActivityPluginBinding? = null
    private var pendingPermission: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, "de.sweber/system_calendar")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    // ------------------------------------------------------------ Activity / Berechtigung

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        binding = b
        b.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)
    override fun onDetachedFromActivity() {
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
    }

    private fun hasPermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED &&
            context.checkSelfPermission(Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray): Boolean {
        if (code != REQUEST_CODE) return false
        pendingPermission?.success(hasPermission())
        pendingPermission = null
        return true
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasPermission()) return result.success(true)
        val activity: Activity = binding?.activity ?: return result.success(false)
        if (pendingPermission != null) return result.error("busy", "Anfrage läuft bereits", null)
        pendingPermission = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR), REQUEST_CODE)
    }

    // ------------------------------------------------------------ Aufrufe

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> return result.success(hasPermission())
            "requestPermission" -> return requestPermission(result)
        }
        worker.execute {
            try {
                val value = handle(call)
                main.post { result.success(value) }
            } catch (e: NotImplementedError) {
                main.post { result.notImplemented() }
            } catch (e: SecurityException) {
                main.post { result.error("permission", e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("error", "${e.javaClass.simpleName}: ${e.message}", null) }
            }
        }
    }

    private fun handle(call: MethodCall): Any? = when (call.method) {
        "calendars" -> calendars()
        "events" -> {
            val ids = call.argument<List<Number>>("calendarIds")!!.map { it.toLong() }
            val from = call.argument<Number>("from")?.toLong()
            val sel = StringBuilder("${CalendarContract.Events.CALENDAR_ID} IN (${ids.joinToString(",")})" +
                " AND ${CalendarContract.Events.DELETED} = 0")
            val args = mutableListOf<String>()
            if (from != null) {
                sel.append(" AND (${CalendarContract.Events.LAST_DATE} IS NULL OR ${CalendarContract.Events.LAST_DATE} >= ?)")
                args.add(from.toString())
            }
            query(CalendarContract.Events.CONTENT_URI, EVENT_COLUMNS, sel.toString(), args.toTypedArray())
        }
        "eventsByIds" -> {
            val ids = call.argument<List<Number>>("ids")!!.map { it.toLong() }
            query(CalendarContract.Events.CONTENT_URI, EVENT_COLUMNS,
                "${CalendarContract.Events._ID} IN (${ids.joinToString(",")})", null)
        }
        "instances" -> {
            val id = call.argument<Number>("eventId")!!.toLong()
            val from = call.argument<Number>("from")!!.toLong()
            val to = call.argument<Number>("to")!!.toLong()
            val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
            ContentUris.appendId(uri, from)
            ContentUris.appendId(uri, to)
            query(uri.build(), arrayOf(CalendarContract.Instances.EVENT_ID, CalendarContract.Instances.BEGIN,
                CalendarContract.Instances.END), "${CalendarContract.Instances.EVENT_ID} = ?", arrayOf(id.toString()))
        }
        "insertEvent" -> {
            val uri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values(call))
            uri?.let { ContentUris.parseId(it) } ?: -1L
        }
        "updateEvent" -> {
            val id = call.argument<Number>("id")!!.toLong()
            context.contentResolver.update(
                ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id), values(call), null, null)
        }
        "deleteEvent" -> {
            val id = call.argument<Number>("id")!!.toLong()
            context.contentResolver.delete(
                ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id), null, null)
        }
        else -> throw NotImplementedError()
    }

    private fun calendars(): List<Map<String, Any?>> {
        val base = arrayOf(
            CalendarContract.Calendars._ID, CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME, CalendarContract.Calendars.ACCOUNT_TYPE,
            CalendarContract.Calendars.OWNER_ACCOUNT, CalendarContract.Calendars.CALENDAR_COLOR,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL, CalendarContract.Calendars.VISIBLE,
            CalendarContract.Calendars.SYNC_EVENTS)
        return try {
            query(CalendarContract.Calendars.CONTENT_URI, base + CalendarContract.Calendars.IS_PRIMARY, null, null)
        } catch (e: IllegalArgumentException) {
            query(CalendarContract.Calendars.CONTENT_URI, base, null, null) // ältere Geräte ohne isPrimary
        }
    }

    private fun query(uri: android.net.Uri, projection: Array<String>, sel: String?, args: Array<String>?): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        context.contentResolver.query(uri, projection, sel, args, null)?.use { c ->
            while (c.moveToNext()) {
                val row = HashMap<String, Any?>()
                for (i in 0 until c.columnCount) {
                    row[c.getColumnName(i)] = when (c.getType(i)) {
                        Cursor.FIELD_TYPE_NULL -> null
                        Cursor.FIELD_TYPE_INTEGER -> c.getLong(i)
                        Cursor.FIELD_TYPE_FLOAT -> c.getDouble(i)
                        else -> c.getString(i)
                    }
                }
                out.add(row)
            }
        }
        return out
    }

    private fun values(call: MethodCall): ContentValues {
        val v = ContentValues()
        val map = call.argument<Map<String, Any?>>("values") ?: emptyMap()
        for ((k, x) in map) {
            when (x) {
                null -> v.putNull(k)
                is Boolean -> v.put(k, if (x) 1 else 0)
                is Int -> v.put(k, x.toLong())
                is Long -> v.put(k, x)
                is Double -> v.put(k, x)
                else -> v.put(k, x.toString())
            }
        }
        return v
    }

    companion object {
        private const val REQUEST_CODE = 4712
        private val EVENT_COLUMNS = arrayOf(
            CalendarContract.Events._ID, CalendarContract.Events.CALENDAR_ID, CalendarContract.Events.TITLE,
            CalendarContract.Events.DESCRIPTION, CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.DTSTART, CalendarContract.Events.DTEND, CalendarContract.Events.DURATION,
            CalendarContract.Events.ALL_DAY, CalendarContract.Events.EVENT_TIMEZONE,
            CalendarContract.Events.RRULE, CalendarContract.Events.RDATE, CalendarContract.Events.EXDATE,
            CalendarContract.Events.ORIGINAL_ID, CalendarContract.Events.ORIGINAL_INSTANCE_TIME,
            CalendarContract.Events.ORIGINAL_ALL_DAY, CalendarContract.Events.STATUS,
            CalendarContract.Events.DELETED, CalendarContract.Events.CUSTOM_APP_PACKAGE,
            CalendarContract.Events.CUSTOM_APP_URI, CalendarContract.Events.LAST_DATE)
    }
}

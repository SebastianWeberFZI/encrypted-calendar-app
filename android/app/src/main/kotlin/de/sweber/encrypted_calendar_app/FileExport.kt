package de.sweber.encrypted_calendar_app

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Legt Dateien im öffentlichen Ordner „Download/<folder>“ ab (Protokoll-Export),
 * damit man sie per USB-Kabel auf den Rechner ziehen kann. Ab Android 10 über
 * den MediaStore, ohne Speicher-Berechtigung. Davor im App-Ordner unter
 * „Android/data/<paket>/files/<folder>“, der per USB ebenfalls sichtbar ist.
 */
object FileExport {
    const val CHANNEL = "de.sweber/files"

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveToDownloads") {
            result.notImplemented()
            return
        }
        val folder = (call.argument<String>("folder") ?: "Export").replace('/', '_')
        val files = call.argument<List<Map<String, String>>>("files") ?: emptyList()
        val app = context.applicationContext
        val main = Handler(Looper.getMainLooper())
        Thread {
            try {
                val where = save(app, folder, files)
                main.post { result.success(where) }
            } catch (e: Exception) {
                main.post { result.error("export", e.message ?: e.toString(), null) }
            }
        }.start()
    }

    private fun save(context: Context, folder: String, files: List<Map<String, String>>): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val relPath = "${Environment.DIRECTORY_DOWNLOADS}/$folder/"
            for (f in files) {
                val src = File(f["path"] ?: continue)
                val name = f["name"] ?: src.name
                // Eigene Datei gleichen Namens vom letzten Export ersetzen.
                try {
                    resolver.delete(
                        collection,
                        "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.DISPLAY_NAME}=?",
                        arrayOf(relPath, name),
                    )
                } catch (e: Exception) {
                }
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relPath)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = resolver.insert(collection, values)
                    ?: throw IllegalStateException("Download/$folder nicht beschreibbar")
                try {
                    val out = resolver.openOutputStream(uri)
                        ?: throw IllegalStateException("$name nicht beschreibbar")
                    out.use { o -> src.inputStream().use { it.copyTo(o) } }
                    values.clear()
                    values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    resolver.update(uri, values, null, null)
                } catch (e: Exception) {
                    resolver.delete(uri, null, null)
                    throw e
                }
            }
            return "Download/$folder"
        }
        val dir = File(context.getExternalFilesDir(null) ?: context.filesDir, folder)
        dir.mkdirs()
        for (f in files) {
            val src = File(f["path"] ?: continue)
            src.copyTo(File(dir, f["name"] ?: src.name), overwrite = true)
        }
        return dir.absolutePath
    }
}

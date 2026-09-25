package com.socketagent.app

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import java.util.Date
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Reads only this app's OS exit records, on demand. Never uploads anything. */
class SpeechCrashReport(private val context: Context) {
    @RequiresApi(30)
    private fun exits() = context.getSystemService(ActivityManager::class.java)
        .getHistoricalProcessExitReasons(context.packageName, 0, 12)

    fun summary(): String = buildString {
        appendLine("SocketAgent ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
        appendLine("${Build.MANUFACTURER} ${Build.MODEL}; Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        appendLine("ABI: ${Build.SUPPORTED_ABIS.joinToString()}")
        if (Build.VERSION.SDK_INT < 30) {
            appendLine("Saved crash reports require Android 11 or later.")
            return@buildString
        }
        val records = exits()
        if (records.isEmpty()) appendLine("Android has no saved app exit records.")
        for (exit in records) {
            appendLine()
            appendLine("${Date(exit.timestamp)}; PID ${exit.pid}")
            appendLine("${reason(exit.reason)} (${exit.reason}); status/signal ${exit.status}")
            appendLine("Last sampled memory: RSS ${exit.rss} KB; PSS ${exit.pss} KB")
            appendLine(exit.description ?: "No description")
        }
    }

    private fun reason(value: Int): String = when (value) {
        1 -> "App exited"
        2 -> "Signal"
        3 -> "Low memory"
        4 -> "Java crash"
        5 -> "Native crash"
        6 -> "App not responding"
        7 -> "Initialization failure"
        9 -> "Excessive resource use"
        10 -> "User requested stop"
        11 -> "User stopped app"
        16 -> "App updated"
        else -> "Other exit"
    }

    fun save(): String {
        check(Build.VERSION.SDK_INT >= 30) { "Saved crash reports require Android 11 or later." }
        val name = "socketagent-crash-${System.currentTimeMillis()}.zip"
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, "application/zip")
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }) ?: error("Could not create report in Downloads")
        try {
            ZipOutputStream(resolver.openOutputStream(uri) ?: error("Could not open report")).use { zip ->
                zip.putNextEntry(ZipEntry("summary.txt"))
                zip.write(summary().toByteArray(Charsets.UTF_8))
                zip.closeEntry()
                for (exit in exits().filter {
                    it.reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
                        it.reason == ApplicationExitInfo.REASON_ANR
                }.take(3)) {
                    try {
                        exit.traceInputStream?.use { trace ->
                            val extension = if (exit.reason == ApplicationExitInfo.REASON_CRASH_NATIVE) "pb" else "txt"
                            zip.putNextEntry(ZipEntry("exit-${exit.timestamp}-${exit.pid}.$extension"))
                            // Android stores native tombstones as protobuf, not UTF-8 text.
                            val bytes = ByteArray(8192)
                            var remaining = 4 * 1024 * 1024
                            while (remaining > 0) {
                                val count = trace.read(bytes, 0, minOf(bytes.size, remaining))
                                if (count < 0) break
                                zip.write(bytes, 0, count)
                                remaining -= count
                            }
                            zip.closeEntry()
                        }
                    } catch (error: java.io.IOException) {
                        zip.putNextEntry(ZipEntry("unavailable-${exit.timestamp}.txt"))
                        zip.write("Android could not read the saved trace: ${error.message}".toByteArray())
                        zip.closeEntry()
                    }
                }
            }
            resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
        return "Downloads/$name"
    }
}

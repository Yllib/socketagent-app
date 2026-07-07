package com.socketagent.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.io.File
import java.io.PrintStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

object LocalAdb {
    private const val TIMEOUT_SECONDS = 30L
    private const val INSTALL_TIMEOUT_SECONDS = 300L
    private const val MAX_CAPTURE_CHARS = 2 * 1024 * 1024
    private val runningStreams = ConcurrentHashMap<String, Process>()

    fun pair(context: Context, port: String, code: String, callback: (Map<String, Any?>) -> Unit) {
        Thread {
            val result = try {
                val adb = adbPath(context)
                val process = startProcess(context, listOf(adb, "pair", "localhost:$port"))
                Thread.sleep(1500)
                PrintStream(process.outputStream).use {
                    it.println(code)
                    it.flush()
                }
                waitForResult(process, "pair", "localhost:$port", TIMEOUT_SECONDS)
            } catch (e: Exception) {
                errorResult("pair", "localhost:$port", e.message ?: e.toString())
            } finally {
                runCatching { runAdb(context, listOf("kill-server"), 5) }
            }
            post(callback, result)
        }.start()
    }

    fun connect(context: Context, port: String, callback: (Map<String, Any?>) -> Unit) {
        Thread {
            val result = try {
                runAdb(context, listOf("start-server"), 10)
                runAdb(context, listOf("connect", "localhost:$port"), TIMEOUT_SECONDS)
            } catch (e: Exception) {
                errorResult("connect", "localhost:$port", e.message ?: e.toString())
            }
            post(callback, result)
        }.start()
    }

    fun shell(context: Context, command: String, callback: (Map<String, Any?>) -> Unit) {
        Thread {
            val result = try {
                runAdb(context, listOf("shell", "sh", "-c", shellQuote(command)), TIMEOUT_SECONDS)
            } catch (e: Exception) {
                errorResult("shell", command, e.message ?: e.toString())
            }
            post(callback, result)
        }.start()
    }

    fun command(
        context: Context,
        args: List<String>,
        timeoutSeconds: Long,
        callback: (Map<String, Any?>) -> Unit
    ) {
        Thread {
            val result = try {
                if (args.isEmpty()) {
                    errorResult("adb", "", "ADB arguments are required.")
                } else {
                    runAdb(context, args, timeoutSeconds.coerceIn(1, 600))
                }
            } catch (e: Exception) {
                errorResult(args.firstOrNull() ?: "adb", args.drop(1).joinToString(" "), e.message ?: e.toString())
            }
            post(callback, result)
        }.start()
    }

    fun install(
        context: Context,
        apkPath: String,
        args: List<String>,
        callback: (Map<String, Any?>) -> Unit
    ) {
        Thread {
            val result = try {
                val apk = File(apkPath)
                if (!apk.exists() || !apk.isFile) {
                    errorResult("install", apkPath, "APK file does not exist.")
                } else {
                    runAdb(context, listOf("install") + args + apk.absolutePath, INSTALL_TIMEOUT_SECONDS)
                }
            } catch (e: Exception) {
                errorResult("install", apkPath, e.message ?: e.toString())
            }
            post(callback, result)
        }.start()
    }

    fun devices(context: Context, callback: (Map<String, Any?>) -> Unit) {
        Thread {
            val result = try {
                runAdb(context, listOf("devices", "-l"), 10)
            } catch (e: Exception) {
                errorResult("devices", "", e.message ?: e.toString())
            }
            post(callback, result)
        }.start()
    }

    fun startStream(
        context: Context,
        streamId: String,
        args: List<String>,
        timeoutSeconds: Long,
        maxBytes: Long,
        onEvent: (Map<String, Any?>) -> Unit
    ) {
        Thread {
            var process: Process? = null
            val bytesSent = AtomicLong(0)
            try {
                if (streamId.isBlank() || args.isEmpty()) {
                    post(onEvent, streamFinal(streamId, args.firstOrNull() ?: "adb", false, null, "ADB stream id and arguments are required."))
                    return@Thread
                }

                process = startProcess(context, listOf(adbPath(context)) + args)
                runningStreams[streamId] = process!!
                val command = args.first()
                val endpoint = args.drop(1).joinToString(" ")
                post(onEvent, mapOf(
                    "event" to "started",
                    "streamId" to streamId,
                    "command" to command,
                    "endpoint" to endpoint,
                    "ok" to true
                ))

                val stdoutThread = Thread {
                    readStream(process!!.inputStream.bufferedReader(), streamId, "stdout", process!!, bytesSent, maxBytes, onEvent)
                }
                val stderrThread = Thread {
                    readStream(process!!.errorStream.bufferedReader(), streamId, "stderr", process!!, bytesSent, maxBytes, onEvent)
                }
                stdoutThread.start()
                stderrThread.start()

                val completed = if (timeoutSeconds > 0) {
                    process!!.waitFor(timeoutSeconds, TimeUnit.SECONDS)
                } else {
                    process!!.waitFor()
                    true
                }

                var timedOut = false
                if (!completed) {
                    timedOut = true
                    process!!.destroy()
                    if (!process!!.waitFor(2, TimeUnit.SECONDS)) {
                        process!!.destroyForcibly()
                    }
                }

                stdoutThread.join(1000)
                stderrThread.join(1000)
                val exitCode = runCatching { process!!.exitValue() }.getOrNull()
                runningStreams.remove(streamId)

                post(onEvent, mapOf(
                    "event" to "complete",
                    "streamId" to streamId,
                    "command" to command,
                    "endpoint" to endpoint,
                    "ok" to (timedOut || exitCode == 0),
                    "exitCode" to exitCode,
                    "stdout" to "",
                    "stderr" to "",
                    "message" to if (timedOut) "ADB stream stopped after ${timeoutSeconds}s." else ""
                ))
            } catch (e: Exception) {
                process?.destroyForcibly()
                runningStreams.remove(streamId)
                post(onEvent, streamFinal(streamId, args.firstOrNull() ?: "adb", false, null, e.message ?: e.toString()))
            }
        }.start()
    }

    fun stopStream(streamId: String): Boolean {
        val process = runningStreams.remove(streamId) ?: return false
        process.destroy()
        Thread {
            if (!process.waitFor(2, TimeUnit.SECONDS)) {
                process.destroyForcibly()
            }
        }.start()
        return true
    }

    private fun runAdb(context: Context, args: List<String>, timeoutSeconds: Long): Map<String, Any?> {
        val process = startProcess(context, listOf(adbPath(context)) + args)
        return waitForResult(process, args.firstOrNull() ?: "adb", args.drop(1).joinToString(" "), timeoutSeconds)
    }

    private fun startProcess(context: Context, command: List<String>): Process {
        val adbFile = File(adbPath(context))
        adbFile.setExecutable(true)
        return ProcessBuilder(command)
            .directory(context.filesDir)
            .apply {
                environment()["HOME"] = context.filesDir.absolutePath
                environment()["TMPDIR"] = context.cacheDir.absolutePath
            }
            .start()
    }

    private fun waitForResult(
        process: Process,
        command: String,
        endpoint: String,
        timeoutSeconds: Long
    ): Map<String, Any?> {
        val stdout = StringBuilder()
        val stderr = StringBuilder()
        val stdoutThread = captureThread(process.inputStream.bufferedReader(), stdout)
        val stderrThread = captureThread(process.errorStream.bufferedReader(), stderr)
        val completed = process.waitFor(timeoutSeconds, TimeUnit.SECONDS)
        if (!completed) {
            process.destroy()
            if (!process.waitFor(2, TimeUnit.SECONDS)) {
                process.destroyForcibly()
            }
            stdoutThread.join(1000)
            stderrThread.join(1000)
            return mapOf(
                "ok" to false,
                "command" to command,
                "endpoint" to endpoint,
                "exitCode" to null,
                "stdout" to synchronized(stdout) { stdout.toString() },
                "stderr" to synchronized(stderr) { stderr.toString() },
                "message" to "Timed out waiting for adb $command."
            )
        }
        stdoutThread.join(1000)
        stderrThread.join(1000)
        val exitCode = process.exitValue()
        return mapOf(
            "ok" to (exitCode == 0),
            "command" to command,
            "endpoint" to endpoint,
            "exitCode" to exitCode,
            "stdout" to synchronized(stdout) { stdout.toString() },
            "stderr" to synchronized(stderr) { stderr.toString() },
            "message" to ""
        )
    }

    private fun captureThread(
        reader: java.io.BufferedReader,
        output: StringBuilder
    ): Thread {
        return Thread {
            try {
                reader.useLines { lines ->
                    for (line in lines) {
                        appendCapped(output, "$line\n")
                    }
                }
            } catch (_: Exception) {
            }
        }.apply { start() }
    }

    private fun appendCapped(output: StringBuilder, value: String) {
        synchronized(output) {
            if (output.length >= MAX_CAPTURE_CHARS) return
            val remaining = MAX_CAPTURE_CHARS - output.length
            if (value.length <= remaining) {
                output.append(value)
            } else {
                output.append(value.take(remaining))
                output.append("\n[output truncated]\n")
            }
        }
    }

    private fun errorResult(command: String, endpoint: String, message: String): Map<String, Any?> {
        return mapOf(
            "ok" to false,
            "command" to command,
            "endpoint" to endpoint,
            "exitCode" to null,
            "stdout" to "",
            "stderr" to "",
            "message" to message
        )
    }

    private fun shellQuote(value: String): String {
        return "'" + value.replace("'", "'\\''") + "'"
    }

    private fun streamFinal(
        streamId: String,
        command: String,
        ok: Boolean,
        exitCode: Int?,
        message: String
    ): Map<String, Any?> {
        return mapOf(
            "event" to "complete",
            "streamId" to streamId,
            "command" to command,
            "endpoint" to "",
            "ok" to ok,
            "exitCode" to exitCode,
            "stdout" to "",
            "stderr" to "",
            "message" to message
        )
    }

    private fun readStream(
        reader: java.io.BufferedReader,
        streamId: String,
        streamName: String,
        process: Process,
        bytesSent: AtomicLong,
        maxBytes: Long,
        onEvent: (Map<String, Any?>) -> Unit
    ) {
        try {
            reader.useLines { lines ->
                for (line in lines) {
                    val chunk = "$line\n"
                    val total = bytesSent.addAndGet(chunk.toByteArray().size.toLong())
                    if (maxBytes > 0 && total > maxBytes) {
                        post(onEvent, mapOf(
                            "event" to "chunk",
                            "streamId" to streamId,
                            "stream" to "stderr",
                            "data" to "ADB stream stopped after ${maxBytes} bytes.\n"
                        ))
                        process.destroy()
                        break
                    }
                    post(onEvent, mapOf(
                        "event" to "chunk",
                        "streamId" to streamId,
                        "stream" to streamName,
                        "data" to chunk
                    ))
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun adbPath(context: Context): String {
        return "${context.applicationInfo.nativeLibraryDir}/libadb.so"
    }

    private fun post(callback: (Map<String, Any?>) -> Unit, result: Map<String, Any?>) {
        Handler(Looper.getMainLooper()).post { callback(result) }
    }
}

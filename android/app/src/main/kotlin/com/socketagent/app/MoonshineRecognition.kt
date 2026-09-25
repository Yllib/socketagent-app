package com.socketagent.app

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import ai.moonshine.voice.JNI
import ai.moonshine.voice.TranscriberOption
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

/** All native model operations are serialized off the Android UI thread. */
class MoonshineRecognition(messenger: BinaryMessenger, context: Context) {
    private val crashReport = SpeechCrashReport(context.applicationContext)
    private val channel = MethodChannel(messenger, "com.socketagent.app/moonshine")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var model = -1
    private var stream = -1
    private var pendingSamples = 0
    private var intervalSamples = 8000
    private val lines = linkedMapOf<Long, String>()

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "available") {
                result.success(Build.VERSION.SDK_INT >= 26 &&
                    Build.SUPPORTED_ABIS.any { it in listOf("arm64-v8a", "armeabi-v7a", "x86_64") })
            } else if (Build.VERSION.SDK_INT < 26) {
                result.error("UNSUPPORTED", "Moonshine needs Android 8 or later", null)
            } else {
                worker.execute {
                    try {
                        val response = handle(call)
                        main.post { result.success(response) }
                    } catch (error: Exception) {
                        main.post { result.error("MOONSHINE", error.message, null) }
                    } catch (error: LinkageError) {
                        main.post { result.error("MOONSHINE_RUNTIME", error.message, null) }
                    }
                }
            }
        }
    }

    private fun checked(code: Int): Int {
        check(code >= 0) { "Moonshine: ${JNI.moonshineErrorToString(code)}" }
        return code
    }

    private fun releaseStream() {
        if (stream >= 0 && model >= 0) JNI.moonshineFreeStream(model, stream)
        stream = -1
        lines.clear()
        pendingSamples = 0
    }

    private fun releaseModel() {
        releaseStream()
        if (model >= 0) JNI.moonshineFreeTranscriber(model)
        model = -1
    }

    private fun handle(call: MethodCall): Any? = when (call.method) {
        "crashReport" -> crashReport.summary()
        "saveCrashReport" -> crashReport.save()
        "initialize" -> {
            JNI.ensureLibraryLoaded()
            releaseModel()
            val interval = call.argument<Double>("updateInterval")!!.coerceIn(0.25, 1.5)
            intervalSamples = (interval * 16000).toInt()
            val options = arrayOf(
                TranscriberOption("vad_threshold", call.argument<Double>("vadThreshold")!!.coerceIn(0.2, 0.8).toString()),
                TranscriberOption("transcription_interval", interval.toString()),
                TranscriberOption("return_audio_data", "false")
            )
            model = checked(JNI.moonshineLoadTranscriberFromFiles(
                call.argument<String>("path")!!, call.argument<Int>("architecture")!!, options))
            true
        }
        "reset" -> {
            check(model >= 0) { "Speech model is not loaded" }
            releaseStream()
            stream = checked(JNI.moonshineCreateStream(model, 0))
            checked(JNI.moonshineStartStream(model, stream))
            null
        }
        "audio" -> {
            check(stream >= 0) { "Recognition is not started" }
            val bytes = call.arguments as ByteArray
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val samples = FloatArray(bytes.size / 2) { buffer.short / 32768.0f }
            checked(JNI.moonshineAddAudioToStream(model, stream, samples, 16000, 0))
            pendingSamples += samples.size
            if (pendingSamples >= intervalSamples) {
                pendingSamples = 0
                transcript(0)
            } else null
        }
        "finalize" -> {
            if (stream < 0) null else {
                checked(JNI.moonshineStopStream(model, stream))
                transcript(JNI.MOONSHINE_FLAG_FORCE_UPDATE)
            }
        }
        "close" -> { releaseModel(); null }
        else -> throw IllegalArgumentException("Unknown recognition operation")
    }

    private fun transcript(flags: Int): Map<String, Any> {
        val result = JNI.moonshineTranscribeStream(model, stream, flags)
            ?: error("Moonshine returned no transcript")
        var speaking = false
        for (line in result.lines) {
            lines[line.id] = line.text.trim()
            if (!line.isComplete) speaking = true
        }
        return mapOf("text" to lines.values.filter { it.isNotEmpty() }.joinToString(" "), "speaking" to speaking)
    }

    fun close() {
        channel.setMethodCallHandler(null)
        worker.execute { releaseModel() }
        worker.shutdown()
    }
}

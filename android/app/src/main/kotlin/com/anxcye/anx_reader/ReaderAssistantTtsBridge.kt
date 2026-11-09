package com.anxcye.anx_reader

import android.app.Activity
import android.media.AudioAttributes
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Own TTS engine: book-reading FlutterTts callbacks and queue remain untouched. */
class ReaderAssistantTtsBridge(activity: Activity, flutterEngine: FlutterEngine) {
    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.anxcye.anx_reader/assistant_tts")
    private var engine: TextToSpeech? = null
    private var initialized = false
    private var initializationFailed = false
    private var foreground = true
    private var closed = false
    private var activeId: String? = null
    private var chunks = emptyList<String>()
    private var chunkIndex = 0
    private var language = "ru-RU"
    private var initTimeout: Runnable? = null
    private var utteranceTimeout: Runnable? = null

    init {
        engine = TextToSpeech(activity.applicationContext) { result -> handler.post {
            if (!closed) {
                initialized = result == TextToSpeech.SUCCESS
                initializationFailed = !initialized
                if (initialized) {
                    try { configureEngine() } catch (_: Exception) { initialized = false; initializationFailed = true }
                }
                activeId?.let { if (initialized) speakNext(it) else fail(it, "tts_unavailable") }
            }
        } }
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "speak" -> {
                        val id = requireNotNull(call.argument<String>("id"))
                        require(id.length in 1..120 && id.all { it.isLetterOrDigit() || it in "_-" })
                        val text = requireNotNull(call.argument<String>("text"))
                        require(text.isNotBlank() && text.length <= 32000)
                        stopCurrent(notify = true)
                        activeId = id
                        language = call.argument<String>("language")?.takeIf { it in listOf("ru-RU", "es-ES", "en-US") } ?: "ru-RU"
                        chunks = splitText(text, minOf(3500, TextToSpeech.getMaxSpeechInputLength()))
                        chunkIndex = 0
                        if (!foreground || initializationFailed) fail(id, "tts_unavailable")
                        else if (initialized) speakNext(id)
                        else {
                            initTimeout = Runnable { if (activeId == id && !initialized) fail(id, "tts_unavailable") }
                                .also { handler.postDelayed(it, 15000) }
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        if (call.argument<String>("id") == activeId) stopCurrent(notify = true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                activeId?.let { fail(it, "tts_failed") }
                result.error("ASSISTANT_TTS_FAILED", "Android speech synthesis could not start.", null)
            }
        }
    }
    private fun configureEngine() {
        val tts = engine ?: return
        runCatching { tts.setAudioAttributes(AudioAttributes.Builder()
            .setUsage(if (Build.VERSION.SDK_INT >= 26) AudioAttributes.USAGE_ASSISTANT else AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()) }
        val listenerStatus = tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) { handler.post {
                val id = activeId ?: return@post
                if (utteranceId == "$id:$chunkIndex" && chunkIndex == 0) emit(id, "started")
            } }
            override fun onDone(utteranceId: String?) { handler.post {
                val id = activeId ?: return@post
                if (utteranceId != "$id:$chunkIndex") return@post
                utteranceTimeout?.let(handler::removeCallbacks); utteranceTimeout = null
                chunkIndex++
                if (chunkIndex >= chunks.size) {
                    activeId = null; chunks = emptyList(); emit(id, "completed")
                } else speakNext(id)
            } }
            @Deprecated("Android compatibility callback")
            override fun onError(utteranceId: String?) { reportError(utteranceId) }
            override fun onError(utteranceId: String?, errorCode: Int) { reportError(utteranceId) }
            override fun onStop(utteranceId: String?, interrupted: Boolean) { handler.post {
                val id = activeId ?: return@post
                if (utteranceId == "$id:$chunkIndex") stopCurrent(notify = true)
            } }
        })
        check(listenerStatus != TextToSpeech.ERROR)
    }
    private fun reportError(utteranceId: String?) { handler.post {
        val id = activeId ?: return@post
        if (utteranceId == "$id:$chunkIndex") fail(id, "tts_failed")
    } }
    private fun speakNext(id: String) {
        if (closed || !foreground || activeId != id) return
        initTimeout?.let(handler::removeCallbacks); initTimeout = null
        try {
            val tts = engine ?: return fail(id, "tts_unavailable")
            val support = tts.setLanguage(Locale.forLanguageTag(language))
            if (support == TextToSpeech.LANG_MISSING_DATA || support == TextToSpeech.LANG_NOT_SUPPORTED) {
                fail(id, "language_unavailable"); return
            }
            if (chunkIndex !in chunks.indices) { fail(id, "tts_failed"); return }
            val queued = tts.speak(chunks[chunkIndex], if (chunkIndex == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD,
                null, "$id:$chunkIndex")
            if (queued == TextToSpeech.ERROR) fail(id, "tts_failed")
            else {
                val index = chunkIndex
                utteranceTimeout?.let(handler::removeCallbacks)
                utteranceTimeout = Runnable {
                    if (activeId == id && chunkIndex == index) fail(id, "tts_timeout")
                }.also { handler.postDelayed(it, minOf(480000L, 30000L + chunks[index].length * 200L)) }
            }
        } catch (_: Exception) { fail(id, "tts_failed") }
    }
    private fun fail(id: String, code: String) {
        if (activeId != id) return
        stopCurrent(notify = false); emit(id, "error", code)
    }
    private fun emit(id: String, type: String, code: String? = null) {
        if (!closed) runCatching { channel.invokeMethod("ttsEvent", mapOf("id" to id, "type" to type, "code" to code)) }
    }
    private fun stopCurrent(notify: Boolean) {
        val id = activeId
        activeId = null; chunks = emptyList(); chunkIndex = 0
        initTimeout?.let(handler::removeCallbacks); initTimeout = null
        utteranceTimeout?.let(handler::removeCallbacks); utteranceTimeout = null
        runCatching { engine?.stop() }
        if (notify && id != null) emit(id, "cancelled")
    }
    fun onForeground() { foreground = true }
    fun onBackground() { foreground = false; stopCurrent(notify = true) }
    fun close() {
        closed = true; stopCurrent(notify = false)
        runCatching { engine?.shutdown() }; engine = null
        channel.setMethodCallHandler(null)
    }
    companion object {
        /** Split on UTF-16-safe word/sentence boundaries under the engine limit. */
        internal fun splitText(text: String, maximum: Int): List<String> {
            require(maximum >= 2)
            val result = mutableListOf<String>()
            var offset = 0
            while (offset < text.length) {
                var end = minOf(text.length, offset + maximum)
                if (end < text.length) {
                    if (Character.isHighSurrogate(text[end - 1])) end--
                    val whitespace = text.lastIndexOf(' ', end - 1)
                    if (whitespace > offset + maximum / 2) end = whitespace + 1
                }
                result += text.substring(offset, end)
                offset = end
            }
            return result
        }
    }
}

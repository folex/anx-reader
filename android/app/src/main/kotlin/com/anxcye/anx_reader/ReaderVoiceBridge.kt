package com.anxcye.anx_reader

import android.Manifest
import android.app.Activity
import android.app.VoiceInteractor
import android.app.assist.AssistContent
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Short, explicitly initiated voice actions on the existing reader Activity. */
class ReaderVoiceBridge(private val activity: Activity, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.anxcye.anx_reader/voice")
    private val handler = Handler(Looper.getMainLooper())
    private var speech: SpeechRecognizer? = null
    private var audioPipe: AssistantAudioPipe? = null
    private var activeId: String? = null
    private var mode: String? = null
    private var language = "ru-RU"
    private var pickRequest: VoiceInteractor.PickOptionRequest? = null
    private var context: Bundle? = null
    private var timeout: Runnable? = null
    private var contextTimeout: Runnable? = null
    private var closed = false
    private var foreground = true
    private var permissionPending = false
    private var permissionOwner: String? = null
    private var fallbackOwner: String? = null
    companion object { const val AUDIO_PERMISSION_REQUEST = 41273 }

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "startDictation", "startAssistantListening" -> {
                        val id = safeId(call.argument<String>("id"))
                        begin(id, if (call.method == "startAssistantListening") "continuous" else "dictation")
                        language = call.argument<String>("language")?.takeIf { it in listOf("ru-RU", "es-ES", "en-US") } ?: "ru-RU"
                        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            if (permissionOwner != null) {
                                finish(id, "error", mapOf("code" to "permission_pending"))
                                result.success(null)
                                return@setMethodCallHandler
                            }
                            permissionPending = true
                            permissionOwner = id
                            emit(id, "permission")
                            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), AUDIO_PERMISSION_REQUEST)
                        } else startSpeech(id)
                        result.success(null)
                    }
                    "stopDictation" -> {
                        if (call.argument<String>("id") == activeId && mode == "dictation" && !permissionPending && speech != null) {
                            speech?.stopListening()
                            emit(activeId!!, "processing")
                        }
                        result.success(null)
                    }
                    "startAssistant" -> {
                        val id = safeId(call.argument<String>("id"))
                        begin(id, "assistant")
                        context = Bundle().apply {
                            putString("anx.book.title", bounded(call.argument<String>("title"), 200))
                            putString("anx.book.chapter", bounded(call.argument<String>("chapter"), 200))
                            putString("anx.selection", bounded(call.argument<String>("selection"), 2000))
                            putString("anx.question", bounded(call.argument<String>("question"), 1000))
                        }
                        startAssistant(id)
                        result.success(null)
                    }
                    "cancel" -> {
                        // Stale panels must not cancel a newer panel's session.
                        if (call.argument<String>("id") == activeId || call.argument<String>("id") == fallbackOwner) cancel()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                if (permissionPending && permissionOwner == activeId) permissionOwner = null
                activeId?.let { finish(it, "error", mapOf("code" to "voice_unavailable")) }
                result.error("VOICE_UNAVAILABLE", "Android voice action could not be started.", null)
            }
        }
    }

    private fun safeId(value: String?): String {
        require(value != null && value.length in 1..120 && value.all { it.isLetterOrDigit() || it in "_-" })
        return value
    }
    private fun bounded(value: String?, length: Int) = (value ?: "").take(length)
    private fun begin(id: String, kind: String) {
        require(!closed)
        cancel()
        activeId = id; mode = kind
    }
    private fun emit(id: String, type: String, fields: Map<String, Any?> = emptyMap()) {
        if (!closed) runCatching { channel.invokeMethod("voiceEvent", mapOf("id" to id, "type" to type) + fields) }
    }
    private fun armTimeout(id: String, millis: Long, action: () -> Unit) {
        timeout?.let(handler::removeCallbacks)
        timeout = Runnable { if (activeId == id) { try { action() } catch (_: Exception) { finish(id, "error", mapOf("code" to "voice_unavailable")) } } }.also { handler.postDelayed(it, millis) }
    }
    private fun startSpeech(id: String) {
        if (activeId != id || mode !in listOf("dictation", "continuous")) return
        val continuous = mode == "continuous"
        if (continuous && Build.VERSION.SDK_INT < 33) {
            finish(id, "error", mapOf("code" to "continuous_unsupported")); return
        }
        permissionPending = false
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            finish(id, "error", mapOf("code" to "recognizer_unavailable")); return
        }
        val recognizer = SpeechRecognizer.createSpeechRecognizer(activity)
        speech = recognizer
        val startedAt = SystemClock.elapsedRealtime()
        fun phase(name: String) {
            if (continuous) Log.i("AnxVoiceTiming", "phase=$name elapsedMs=${SystemClock.elapsedRealtime() - startedAt}")
        }
        recognizer.setRecognitionListener(object : RecognitionListener {
            private fun current() = activeId == id && speech === recognizer && mode == (if (continuous) "continuous" else "dictation")
            override fun onReadyForSpeech(params: Bundle?) { if (current()) { phase("ready"); emit(id, "listening") } }
            override fun onBeginningOfSpeech() { if (current()) { phase("speech"); emit(id, "listening") } }
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() { if (current() && !continuous) emit(id, "processing") }
            override fun onError(error: Int) { if (current()) finish(id, "error", mapOf("code" to speechError(error))) }
            override fun onSegmentResults(segmentResults: Bundle) {
                if (continuous) complete(segmentResults, terminal = false)
            }
            override fun onEndOfSegmentedSession() {
                if (current() && continuous) finish(id, "error", mapOf("code" to "continuous_ended"))
            }
            override fun onResults(results: Bundle?) { complete(results) }
            private fun complete(results: Bundle?, terminal: Boolean = true) {
                if (!current()) return
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.take(4000) ?: ""
                if (text.isBlank()) {
                    if (terminal) finish(id, "error", mapOf("code" to if (continuous) "continuous_ended" else "no_match"))
                }
                else { phase("final"); finish(id, "transcript", mapOf("text" to text)) }
            }
            override fun onPartialResults(partialResults: Bundle?) {
                if (current()) emit(id, "partial", mapOf("text" to (partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.take(4000) ?: "")))
            }
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        if (!continuous) armTimeout(id, 60000) { finish(id, "error", mapOf("code" to "timeout")) }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
        if (continuous) {
            audioPipe = AssistantAudioPipe(handler) {
                if (activeId == id) finish(id, "error", mapOf("code" to "audio_source_failed"))
            }.also { it.configure(intent) }
        }
        recognizer.startListening(intent)
        audioPipe?.start()
        emit(id, "starting")
    }
    private fun speechError(code: Int): String = when (code) {
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permission_denied"
        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "network"
        SpeechRecognizer.ERROR_NO_MATCH -> "no_match"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "no_speech"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "busy"
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "language_unavailable"
        else -> "recognition_failed"
    }
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != AUDIO_PERMISSION_REQUEST) return
        val owner = permissionOwner
        permissionOwner = null
        if (!permissionPending || owner != activeId) return
        permissionPending = false
        val id = activeId ?: return
        if (mode !in listOf("dictation", "continuous")) return
        if (!foreground) { finish(id, "cancelled"); return }
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            try { startSpeech(id) } catch (_: Exception) { finish(id, "error", mapOf("code" to "recognizer_unavailable")) }
        }
        else finish(id, "error", mapOf("code" to "permission_denied"))
    }

    private fun startAssistant(id: String) {
        try {
            if (Build.VERSION.SDK_INT >= 24 && activity.isLocalVoiceInteractionSupported) {
                emit(id, "assistantStarting")
                armTimeout(id, 8000) { fallbackAssistant(id, "local_session_timeout") }
                activity.startLocalVoiceInteraction(Bundle(context))
            } else fallbackAssistant(id, "local_session_unsupported")
        } catch (_: Exception) { fallbackAssistant(id, "local_session_rejected") }
    }
    fun onLocalStarted() {
        val id = activeId ?: return
        if (mode != "assistant") return
        try { submitPickRequest(id) } catch (_: Exception) { fallbackAssistant(id, "local_request_rejected") }
    }
    private fun submitPickRequest(id: String) {
        timeout?.let(handler::removeCallbacks)
        val interactor = activity.voiceInteractor
        if (interactor == null) { fallbackAssistant(id, "local_interactor_unavailable"); return }
        val options = arrayOf(
            VoiceInteractor.PickOptionRequest.Option("Meaning and translation", 0).addSynonym("перевод").addSynonym("значение"),
            VoiceInteractor.PickOptionRequest.Option("Grammar", 1).addSynonym("грамматику"),
            VoiceInteractor.PickOptionRequest.Option("Words and phrases", 2).addSynonym("слова").addSynonym("выражения")
        )
        val request = object : VoiceInteractor.PickOptionRequest(
            VoiceInteractor.Prompt("What would you like explained in this selection?"), options, Bundle(context)
        ) {
            override fun onPickOptionResult(finished: Boolean, selections: Array<out VoiceInteractor.PickOptionRequest.Option>?, result: Bundle?) {
                if (activeId != id || pickRequest !== this) return
                if (!finished) { emit(id, "assistantChoosing"); return }
                val index = selections?.singleOrNull()?.index
                val choice = when (index) { 0 -> "meaning"; 1 -> "grammar"; 2 -> "idioms"; else -> null }
                if (choice == null) finish(id, "error", mapOf("code" to "ambiguous_choice"))
                else finish(id, "assistantChoice", mapOf("choice" to choice))
            }
            override fun onCancel() { if (activeId == id && pickRequest === this) finish(id, "cancelled") }
        }
        pickRequest = request
        if (interactor.submitRequest(request, "anx_reading_help")) {
            emit(id, "assistantLocal")
            armTimeout(id, 90000) { finish(id, "error", mapOf("code" to "timeout")) }
        } else { pickRequest = null; fallbackAssistant(id, "pick_option_rejected") }
    }
    fun onLocalStopped() {
        if (mode == "assistant") activeId?.let { finish(it, "cancelled", stopLocal = false) }
    }
    private fun fallbackAssistant(id: String, reason: String) {
        if (activeId != id) return
        timeout?.let(handler::removeCallbacks); timeout = null
        val oldRequest = pickRequest
        pickRequest = null
        mode = "assistantFallback"
        runCatching { oldRequest?.cancel() }
        if (activeId != id) return
        // Stop only our local session before asking the configured assistant to
        // display its own UI. There is no generic free-text response callback.
        if (Build.VERSION.SDK_INT >= 24) runCatching { activity.stopLocalVoiceInteraction() }
        if (activeId != id) return
        val shown = try { activity.showAssist(Bundle(context)) } catch (_: Exception) { false }
        if (activeId != id) return
        if (!shown) {
            finish(id, "error", mapOf("code" to "assistant_unavailable")); return
        }
        emit(id, "assistantExternal", mapOf("reason" to reason))
        activeId = null; mode = null; fallbackOwner = id
        contextTimeout?.let(handler::removeCallbacks)
        contextTimeout = Runnable { if (fallbackOwner == id) { context = null; fallbackOwner = null } }.also { handler.postDelayed(it, 30000) }
    }
    fun provideAssistData(data: Bundle) {
        context?.let { data.putAll(it) }
    }
    fun provideAssistContent(content: AssistContent) {
        val snapshot = context ?: return
        val selection = snapshot.getString("anx.selection").orEmpty()
        val question = snapshot.getString("anx.question").orEmpty()
        val text = listOf(selection, question).filter { it.isNotBlank() }.joinToString("\n\n").take(3000)
        if (text.isNotBlank()) content.clipData = ClipData.newPlainText("Book excerpt", text)
        content.structuredData = JSONObject().apply {
            put("@type", "Book")
            put("name", snapshot.getString("anx.book.title"))
            put("chapter", snapshot.getString("anx.book.chapter"))
            put("text", text)
        }.toString()
    }
    fun onForeground() { foreground = true }
    fun onBackground() {
        foreground = false
        // Assistant UI may legitimately pause Anx; preserve that local session.
        if (mode in listOf("dictation", "continuous") && !permissionPending) cancel()
    }
    private fun finish(id: String, type: String, fields: Map<String, Any?> = emptyMap(), stopLocal: Boolean = true) {
        if (activeId != id) return
        val wasAssistant = mode == "assistant"
        activeId = null; mode = null; permissionPending = false
        timeout?.let(handler::removeCallbacks); timeout = null
        val pipe = audioPipe; audioPipe = null
        runCatching { pipe?.close() }
        val recognizer = speech; speech = null
        runCatching { recognizer?.cancel() }; runCatching { recognizer?.destroy() }
        val request = pickRequest; pickRequest = null; runCatching { request?.cancel() }
        context = null
        if (wasAssistant && stopLocal && Build.VERSION.SDK_INT >= 24) runCatching { activity.stopLocalVoiceInteraction() }
        emit(id, type, fields)
    }
    private fun cancel() {
        activeId?.let { finish(it, "cancelled") }
        contextTimeout?.let(handler::removeCallbacks); contextTimeout = null; context = null; fallbackOwner = null
    }
    fun close() { cancel(); closed = true; channel.setMethodCallHandler(null) }
}

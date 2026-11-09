package com.anxcye.anx_reader

import android.app.Activity
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Per-reader window brightness. Never changes system settings or requests WRITE_SETTINGS. */
class ReaderBrightnessBridge(
    private val activity: Activity,
    engine: FlutterEngine,
) : AutoCloseable {
    private var activeOwner: String? = null
    private var foreground = false
    private var originalWindowBrightness: Float? = null
    private var readerBrightness: Float? = null
    private val channel = MethodChannel(
        engine.dartExecutor.binaryMessenger,
        "com.anxcye.anx_reader/reader_brightness",
    )

    init {
        channel.setMethodCallHandler { call, result ->
          try {
            val owner = call.argument<String>("owner")
            if (owner.isNullOrBlank()) {
                result.error("INVALID_OWNER", "A reader session owner is required", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "enterReader" -> {
                    if (activeOwner != owner) {
                        leaveReader()
                        originalWindowBrightness = activity.window.attributes.screenBrightness
                        activeOwner = owner
                    }
                    result.success(state())
                }
                "exitReader" -> {
                    if (activeOwner == owner) leaveReader()
                    result.success(null)
                }
                "getBrightness" -> {
                    if (activeOwner == owner) result.success(state())
                    else result.error("STALE_READER", "The reader session is no longer current", null)
                }
                "setBrightness" -> {
                    val value = call.argument<Number>("value")?.toDouble()
                    when {
                        value == null || !value.isFinite() ->
                            result.error("INVALID_BRIGHTNESS", "Expected a finite brightness value", null)
                        activeOwner != owner ->
                            result.error("STALE_READER", "The reader session is no longer current", null)
                        !foreground ->
                            result.error("INACTIVE_READER", "The reader is not in the foreground", null)
                        else -> {
                            val next = value.coerceIn(0.0, 1.0).toFloat()
                            if (apply(next)) {
                                readerBrightness = next
                                result.success(state())
                            } else {
                                result.error("BRIGHTNESS_UNAVAILABLE", "The reader window is unavailable", null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
          } catch (_: RuntimeException) {
            result.error("BRIGHTNESS_UNAVAILABLE", "The reader window is unavailable", null)
          }
        }
    }

    fun onForeground() {
        foreground = true
        if (activeOwner != null) readerBrightness?.let(::apply)
    }

    fun onBackground() {
        foreground = false
        restoreOriginal()
    }

    private fun currentBrightness(): Float {
        readerBrightness?.let { return it }
        val windowValue = activity.window.attributes.screenBrightness
        if (windowValue.isFinite() && windowValue >= 0f) return windowValue.coerceIn(0f, 1f)
        return try {
            (Settings.System.getInt(
                activity.contentResolver,
                Settings.System.SCREEN_BRIGHTNESS,
                128,
            ) / 255f).coerceIn(0f, 1f)
        } catch (_: SecurityException) {
            0.5f
        }
    }

    private fun state(): Map<String, Any> = mapOf(
        "active" to (activeOwner != null && foreground),
        "brightness" to currentBrightness().toDouble(),
    )

    private fun apply(value: Float): Boolean {
        return try {
            if (activity.isDestroyed) return false
            val attributes = activity.window.attributes
            attributes.screenBrightness = value
            activity.window.attributes = attributes
            true
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun restoreOriginal() {
        originalWindowBrightness?.let(::apply)
    }

    private fun leaveReader() {
        restoreOriginal()
        activeOwner = null
        originalWindowBrightness = null
        readerBrightness = null
    }

    override fun close() {
        leaveReader()
        channel.setMethodCallHandler(null)
    }
}

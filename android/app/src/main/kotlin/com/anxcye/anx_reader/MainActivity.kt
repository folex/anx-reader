package com.anxcye.anx_reader

import android.content.pm.PackageManager
import android.content.Intent
import android.app.assist.AssistContent
import android.os.Bundle
import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var readerExtensionBridge: ReaderExtensionBridge? = null
    private var readerAssistantTtsBridge: ReaderAssistantTtsBridge? = null
    private var readerVoiceBridge: ReaderVoiceBridge? = null
    private var readerBrightnessBridge: ReaderBrightnessBridge? = null
    private var readerNetworkDiagnosticsBridge: ReaderNetworkDiagnosticsBridge? = null
    private var personalUpdateBridge: PersonalUpdateBridge? = null

    override fun onDestroy() {
        readerExtensionBridge?.close()
        readerAssistantTtsBridge?.close()
        readerVoiceBridge?.close()
        readerBrightnessBridge?.close()
        personalUpdateBridge?.close()
        readerNetworkDiagnosticsBridge?.close()
        super.onDestroy()
    }


    override fun onStart() {
        super.onStart()
        readerVoiceBridge?.onForeground()
        readerAssistantTtsBridge?.onForeground()
        readerBrightnessBridge?.onForeground()
    }

    override fun onStop() {
        readerVoiceBridge?.onBackground()
        readerAssistantTtsBridge?.onBackground()
        readerBrightnessBridge?.onBackground()
        super.onStop()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        readerVoiceBridge?.onPermissionResult(requestCode, grantResults)
    }

    override fun onLocalVoiceInteractionStarted() {
        super.onLocalVoiceInteractionStarted()
        readerVoiceBridge?.onLocalStarted()
    }

    override fun onLocalVoiceInteractionStopped() {
        super.onLocalVoiceInteractionStopped()
        readerVoiceBridge?.onLocalStopped()
    }

    override fun onProvideAssistData(data: Bundle) {
        super.onProvideAssistData(data)
        readerVoiceBridge?.provideAssistData(data)
    }

    override fun onProvideAssistContent(content: AssistContent) {
        super.onProvideAssistContent(content)
        readerVoiceBridge?.provideAssistContent(content)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Ensure the latest intent is stored so plugins relying on Activity#getIntent can read it.
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        readerExtensionBridge = ReaderExtensionBridge(this, flutterEngine)
        personalUpdateBridge = PersonalUpdateBridge(this, flutterEngine)
        readerNetworkDiagnosticsBridge = ReaderNetworkDiagnosticsBridge(this, flutterEngine)
        ChatGptBridge(this, flutterEngine)
        ReaderImageConfigBridge(this, flutterEngine)
        readerVoiceBridge = ReaderVoiceBridge(this, flutterEngine)
        readerAssistantTtsBridge = ReaderAssistantTtsBridge(this, flutterEngine)
        readerBrightnessBridge = ReaderBrightnessBridge(this, flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INSTALL_INFO_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstallInfo" -> {
                    try {
                        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            packageManager.getPackageInfo(
                                packageName,
                                PackageManager.PackageInfoFlags.of(0),
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getPackageInfo(packageName, 0)
                        }
                        result.success(
                            hashMapOf(
                                "firstInstallTime" to packageInfo.firstInstallTime,
                                "lastUpdateTime" to packageInfo.lastUpdateTime,
                            ),
                        )
                    } catch (e: Exception) {
                        result.error("PACKAGE_INFO_ERROR", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    companion object {
        private const val INSTALL_INFO_CHANNEL = "com.anxcye.anx_reader/install_info"
    }
}

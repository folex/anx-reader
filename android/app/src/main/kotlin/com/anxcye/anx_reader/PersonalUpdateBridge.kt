package com.anxcye.anx_reader

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class PersonalUpdateFileProvider : FileProvider()

/** Installs only a newer release signed by our existing personal APK key. */
class PersonalUpdateBridge(private val activity: Activity, engine: FlutterEngine) {
    private val executor = Executors.newSingleThreadExecutor()
    private val installing = AtomicBoolean(false)
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
    private val directory: File get() {
        val path = File(activity.cacheDir, "personal-updates").canonicalFile
        require(path.parentFile == activity.cacheDir.canonicalFile) { "Invalid update directory" }
        return path
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "installedInfo" -> try {
                    val info = installedInfo()
                    result.success(mapOf("versionCode" to version(info),
                        "versionName" to info.versionName,
                        "directory" to directory.canonicalPath))
                } catch (error: Exception) {
                    result.error("UPDATE_INFO", error.message, null)
                }
                "installUpdate" -> {
                    if (!installing.compareAndSet(false, true)) {
                        result.error("UPDATE_BUSY", "An update is already being checked", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            val digest = call.argument<String>("sha256") ?: ""
                            val expectedCode = call.argument<Number>("versionCode")?.toLong() ?: 0
                            val apk = verify(digest, expectedCode)
                            activity.runOnUiThread {
                                try {
                                    if (Build.VERSION.SDK_INT >= 26 &&
                                        !activity.packageManager.canRequestPackageInstalls()) {
                                        if (call.argument<Boolean>("openPermissionSettings") == true) {
                                            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                                Uri.parse("package:${activity.packageName}")))
                                        }
                                        result.success("permission_required")
                                    } else {
                                        val uri = FileProvider.getUriForFile(activity,
                                            "${activity.packageName}.personal_updates", apk)
                                        @Suppress("DEPRECATION")
                                        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).setData(uri)
                                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                        activity.startActivity(intent)
                                        result.success("installer_started")
                                    }
                                } catch (error: Exception) {
                                    result.error("UPDATE_INSTALL", error.message, null)
                                } finally { installing.set(false) }
                            }
                        } catch (error: Exception) {
                            activity.runOnUiThread {
                                installing.set(false)
                                result.error("UPDATE_VALIDATION", error.message, null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun installedInfo(): PackageInfo {
        require(activity.packageName == PACKAGE) { "Unexpected application package" }
        val info = activity.packageManager.getPackageInfo(PACKAGE, flags())
        require(signers(info) == setOf(CERTIFICATE)) { "Unexpected installed signing key" }
        return info
    }

    @Suppress("DEPRECATION")
    private fun verify(digest: String, expectedCode: Long): File {
        require(digest.matches(Regex("[a-f0-9]{64}"))) { "Invalid APK digest" }
        val installed = installedInfo()
        require(expectedCode > version(installed) && expectedCode <= Int.MAX_VALUE) {
            "Update version must be newer than the installed application"
        }
        val apk = File(directory, "update.apk").canonicalFile
        require(apk.parentFile == directory.canonicalFile && apk.isFile &&
            apk.length() in 1..MAX_APK_BYTES) { "Invalid update file" }
        val hash = MessageDigest.getInstance("SHA-256")
        apk.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { val count = input.read(buffer); if (count < 0) break
                hash.update(buffer, 0, count) }
        }
        require(hex(hash.digest()) == digest) { "APK checksum does not match the release" }
        val archive = activity.packageManager.getPackageArchiveInfo(apk.path, flags())
            ?: throw IllegalArgumentException("Invalid APK archive")
        require(archive.packageName == PACKAGE) { "APK package does not match this application" }
        require(version(archive) == expectedCode) { "APK version does not match the release" }
        require(signers(archive) == setOf(CERTIFICATE)) { "APK signing key does not match" }
        return apk
    }

    @Suppress("DEPRECATION")
    private fun flags() = if (Build.VERSION.SDK_INT >= 28)
        PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo) = if (Build.VERSION.SDK_INT >= 28)
        info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners
            else info.signatures
        return signatures?.map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }
            ?.toSet() ?: emptySet()
    }
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
    fun close() { channel.setMethodCallHandler(null); executor.shutdown() }
    companion object {
        const val CHANNEL = "com.anxcye.anx_reader.folex/personal_updates"
        const val PACKAGE = "com.anxcye.anx_reader.folex"
        const val CERTIFICATE = "b6c259cad8a3082aeb1d91c47edb5466dd6c46275e6d1ad2475651c68c41a439"
        const val MAX_APK_BYTES = 128L * 1024 * 1024
    }
}

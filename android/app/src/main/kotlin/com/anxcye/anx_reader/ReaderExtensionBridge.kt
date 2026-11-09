package com.anxcye.anx_reader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.webkit.CookieManager
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID
import java.util.concurrent.Executors

class ReaderExtensionBridge(private val activity: Activity, engine: FlutterEngine) {
    private val connections = java.util.concurrent.ConcurrentHashMap.newKeySet<HttpURLConnection>()
    private val workers = Executors.newFixedThreadPool(2)
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.anxcye.anx_reader/extensions")
    init {
        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
            if (call.method == "signIn") {
                try {
                    val url = args["url"] as String
                    val origins = (args["origins"] as List<*>).map { it as String }
                    validate(url, origins)
                    activity.startActivity(Intent(activity, ReaderExtensionAuthActivity::class.java)
                        .putExtra("url", url).putExtra("origins", origins.toTypedArray()))
                    result.success(null)
                } catch (_: Exception) { result.error("AUTH", "Could not open extension sign-in", null) }
            } else if (call.method == "openArtifact") {
                try {
                    val dir = artifactDirectory(args)
                    val file = File(dir, args["id"] as String)
                    require(file.canonicalFile.parentFile == dir.canonicalFile && file.isFile)
                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.extensionfiles", file)
                    activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "audio/*")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                    result.success(null)
                } catch (_: Exception) { result.error("OPEN_AUDIO", "No audio player is available or the file is missing", null) }
            } else {
                workers.execute {
                    try {
                        val value = when (call.method) {
                            "request", "download" -> request(args, call.method == "download")
                            "artifacts" -> artifactDirectory(args).listFiles()?.filter { it.isFile && !it.name.endsWith(".part") }
                                ?.map { mapOf("id" to it.name, "name" to it.name.substringAfter("__")) } ?: emptyList<Any>()
                            else -> throw IllegalArgumentException()
                        }
                        activity.runOnUiThread { result.success(value) }
                    } catch (_: Exception) {
                        // Never surface cookies, request bodies, session URLs or response HTML.
                        activity.runOnUiThread { result.error("EXTENSION_NETWORK", "Extension request failed. Check connection or sign in again.", null) }
                    }
                }
            }
        }
    }
    private fun artifactDirectory(args: Map<*, *>): File {
        val id = args["extensionId"] as String
        require(Regex("[a-z][a-z0-9-]{0,23}").matches(id))
        return File(activity.filesDir, "extension-artifacts/$id").also { it.mkdirs() }
    }
    private fun validate(url: String, origins: List<String>) {
        val uri = URI(url)
        require(uri.scheme == "https" && uri.rawUserInfo == null && uri.host != null)
        val origin = "https://${uri.host}" + if (uri.port != -1 && uri.port != 443) ":${uri.port}" else ""
        require(origins.contains(origin))
    }
    private fun scope(cookies: String?): String {
        val values = cookies.orEmpty().split(";").map { it.trim() }
        val identity = values.firstOrNull { it.startsWith("__Secure-1PSID=") }
            ?: values.firstOrNull { it.startsWith("SID=") } ?: "anonymous"
        return MessageDigest.getInstance("SHA-256").digest(identity.toByteArray())
            .joinToString("") { "%02x".format(it) }
    }
    private fun request(args: Map<*, *>, download: Boolean): Any {
        val origins = (args["origins"] as List<*>).map { it as String }
        var target = args["url"] as String
        val method = args["method"] as? String ?: "GET"
        require(method == "GET" || method == "POST")
        val body = (args["body"] as? String)?.toByteArray(Charsets.UTF_8) ?: byteArrayOf()
        require(body.size <= 8 * 1024 * 1024)
        repeat(5) {
            validate(target, origins)
            val connection = URL(target).openConnection() as HttpURLConnection
            connections.add(connection)
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 30000
                connection.readTimeout = 120000
                connection.requestMethod = method
                connection.setRequestProperty("User-Agent", ReaderExtensionAuthActivity.USER_AGENT)
                connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded;charset=UTF-8")
                connection.setRequestProperty("Origin", URI(target).let { "https://${it.host}" })
                connection.setRequestProperty("Referer", URI(target).let { "https://${it.host}/" })
                val cookies = CookieManager.getInstance().getCookie(target)
                val expected = args["sessionScope"] as? String
                if (expected != null && URI(target).host in listOf("notebook.google.com", "notebooklm.google.com")) {
                    require(scope(cookies) == expected)
                }
                if (!cookies.isNullOrBlank()) connection.setRequestProperty("Cookie", cookies)
                if (method == "POST") { connection.doOutput = true; connection.outputStream.use { it.write(body) } }
                val status = connection.responseCode
                connection.headerFields.entries.filter { it.key?.equals("Set-Cookie", true) == true }
                    .flatMap { it.value }.forEach { CookieManager.getInstance().setCookie(target, it) }
                CookieManager.getInstance().flush()
                if (status in 300..399) {
                    require(method == "GET") // Never replay a mutation on redirect.
                    target = URL(URL(target), connection.getHeaderField("Location")).toString()
                } else {
                    require(status in 200..299)
                    if (download) {
                        require(connection.contentType?.startsWith("audio/") == true || connection.contentType?.contains("octet-stream") == true)
                        val filename = ((args["filename"] as? String) ?: "audio.m4a")
                            .replace(Regex("[^A-Za-z0-9._-]"), "_").take(70)
                        val file = File(artifactDirectory(args), "${UUID.randomUUID()}__$filename")
                        val part = File(file.path + ".part")
                        try {
                            connection.inputStream.use { input -> part.outputStream().use { output ->
                                val buffer = ByteArray(64 * 1024); var total = 0L
                                while (true) { val count = input.read(buffer); if (count < 0) break
                                    total += count; require(total <= 150L * 1024 * 1024); output.write(buffer, 0, count) }
                            } }
                            require(part.renameTo(file))
                            return mapOf("id" to file.name, "name" to filename, "bytes" to file.length())
                        } finally { part.delete() }
                    }
                    val bytes = connection.inputStream.use { input ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(16384)
                        while (true) {
                            val count = input.read(buffer); if (count < 0) break
                            require(output.size() + count <= 8 * 1024 * 1024)
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    }
                    return mapOf("status" to status, "body" to String(bytes, Charsets.UTF_8),
                        "url" to target, "sessionScope" to scope(cookies))
                }
            } finally { connections.remove(connection); connection.disconnect() }
        }
        throw IllegalStateException("Too many redirects")
    }
    fun close() { channel.setMethodCallHandler(null); connections.forEach { it.disconnect() }; workers.shutdownNow() }
}

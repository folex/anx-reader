package com.anxcye.anx_reader

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyStore
import java.security.Signature
import java.security.spec.RSAPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Native-only credentials: no WebView/EPUB channel exposes this bridge. */
class ChatGptBridge(context: Context, engine: FlutterEngine) {
    private val store = AtomicFile(File(context.noBackupFilesDir, "chatgpt-session.enc"))
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.anxcye.anx_reader/chatgpt")

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "read" -> result.success(read())
                    "clear" -> {
                        store.delete()
                        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("anx_chatgpt_v1") }
                        result.success(null)
                    }
                    "write" -> {
                        val value = requireNotNull(call.argument<String>("value"))
                        require(value.toByteArray(Charsets.UTF_8).size <= 1024 * 1024)
                        write(value)
                        result.success(null)
                    }
                    "verifyRs256" -> {
                        val input = requireNotNull(call.argument<String>("input"))
                        val signature = decode(requireNotNull(call.argument<String>("signature")))
                        val modulus = BigInteger(1, decode(requireNotNull(call.argument<String>("n"))))
                        val exponent = BigInteger(1, decode(requireNotNull(call.argument<String>("e"))))
                        require(modulus.bitLength() >= 2048)
                        val key = KeyFactory.getInstance("RSA").generatePublic(RSAPublicKeySpec(modulus, exponent))
                        val verifier = Signature.getInstance("SHA256withRSA")
                        verifier.initVerify(key)
                        verifier.update(input.toByteArray(Charsets.US_ASCII))
                        result.success(verifier.verify(signature))
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                // Never include token-bearing values or crypto details in logs/errors.
                result.error("CHATGPT_SECURE_STORAGE", "Protected ChatGPT credentials could not be processed.", null)
            }
        }
    }

    private fun decode(value: String) = Base64.decode(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private fun key(): SecretKey {
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keys.getKey("anx_chatgpt_v1", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("anx_chatgpt_v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }

    private fun read(): String? {
        val bytes = try { store.readFully() } catch (_: java.io.FileNotFoundException) { return null }
        require(bytes.size > 29 && bytes[0] == 1.toByte())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
        return String(cipher.doFinal(bytes.copyOfRange(13, bytes.size)), Charsets.UTF_8)
    }

    private fun write(value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        require(cipher.iv.size == 12)
        val bytes = byteArrayOf(1) + cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val output = store.startWrite()
        try { output.write(bytes); store.finishWrite(output) }
        catch (error: Exception) { store.failWrite(output); throw error }
    }
}

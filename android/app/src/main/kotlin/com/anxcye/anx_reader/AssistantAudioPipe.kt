package com.anxcye.anx_reader

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.ParcelFileDescriptor
import android.speech.RecognizerIntent
import android.content.Intent
import java.util.concurrent.atomic.AtomicBoolean

/** One live PCM stream. No audio is stored, buffered unboundedly or logged. API33+. */
class AssistantAudioPipe(
    private val handler: Handler,
    private val threadFactory: (Runnable) -> Thread = { Thread(it, "anx-assistant-pcm") },
    private val failed: () -> Unit,
) : AutoCloseable {
    private val lifecycle = Any()
    private val closed = AtomicBoolean(false)
    private val descriptors = ParcelFileDescriptor.createPipe()
    private val output = ParcelFileDescriptor.AutoCloseOutputStream(descriptors[1])
    private val recorder: AudioRecord
    private var worker: Thread? = null
    private var echo: AcousticEchoCanceler? = null
    private var noise: NoiseSuppressor? = null
    val echoCancellation: Boolean get() = echo?.enabled == true
    init {
        try {
            val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            require(minimum > 0)
            recorder = AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(16000).setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(minimum * 2, 6400)).build()
            if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                recorder.release()
                error("AudioRecord initialization failed")
            }
            echo = runCatching {
                if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(recorder.audioSessionId)?.apply { enabled = true } else null
            }.getOrNull()
            noise = runCatching {
                if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(recorder.audioSessionId)?.apply { enabled = true } else null
            }.getOrNull()
        } catch (error: Exception) {
            runCatching { output.close() }; runCatching { descriptors[0].close() }
            throw error
        }
    }
    fun configure(intent: Intent) {
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, descriptors[0])
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
        intent.putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
    }
    fun start(): Unit = synchronized(lifecycle) {
        check(worker == null && !closed.get())
        worker = threadFactory(Runnable {
            try {
                synchronized(lifecycle) {
                    if (!closed.get()) {
                        recorder.startRecording()
                        check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING)
                    }
                }
                val buffer = ByteArray(3200) // 100 ms, fixed memory; pipe applies backpressure.
                while (!closed.get()) {
                    val count = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                    if (count <= 0) error("AudioRecord read failed")
                    if (!closed.get()) output.write(buffer, 0, count)
                }
            } catch (_: Exception) {
                if (!closed.get()) handler.post { if (!closed.get()) failed() }
            } finally {
                synchronized(lifecycle) {
                    runCatching { recorder.stop() }; runCatching { recorder.release() }
                    runCatching { echo?.release() }; runCatching { noise?.release() }
                }
                runCatching { output.close() }
            }
        }).apply { isDaemon = true }
        worker!!.start()
    }
    override fun close() {
        synchronized(lifecycle) {
            if (!closed.compareAndSet(false, true)) return
            // Serialized with startRecording: capture cannot begin after cancel.
            runCatching { recorder.stop() }
            if (worker == null) {
                runCatching { recorder.release() }
                runCatching { echo?.release() }; runCatching { noise?.release() }
            }
        }
        // Unblock a read AND a backpressured write; never join an audio thread on UI.
        runCatching { output.close() }; runCatching { descriptors[0].close() }
    }
}

package com.voicerecorder.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.voicerecorder.MainActivity
import com.voicerecorder.R
import com.voicerecorder.network.WebSocketClient
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.*
import timber.log.Timber
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.inject.Inject

/**
 * Foreground Service for continuous audio recording
 *
 * Key Features:
 * - Runs as foreground service (prevents Android from killing it)
 * - Uses AudioRecord API for low-level PCM audio capture
 * - Chunks audio into 3-second segments
 * - Streams chunks to backend via WebSocket
 * - Implements Voice Activity Detection (VAD) to skip silent periods
 *
 * Audio Format:
 * - Sample Rate: 16kHz (balance of quality vs. bandwidth)
 * - Channel: Mono (single mic)
 * - Encoding: PCM 16-bit
 */
@AndroidEntryPoint
class AudioRecordingService : Service() {

    @Inject
    lateinit var webSocketClient: WebSocketClient

    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private var audioRecord: AudioRecord? = null
    private var recordingJob: Job? = null

    // Audio configuration
    private val sampleRate = 16000  // 16kHz
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT
    private val chunkDurationMs = 3000  // 3 seconds per chunk
    private val bufferSizeBytes = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat) * 4

    private var sessionId: String = ""
    private var chunkCounter = 0

    companion object {
        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"
        const val NOTIFICATION_CHANNEL_ID = "voice_recording_channel"
        const val NOTIFICATION_ID = 1001
    }

    override fun onCreate() {
        super.onCreate()
        Timber.d("AudioRecordingService created")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startRecording()
            ACTION_STOP -> stopRecording()
        }
        return START_STICKY  // Restart service if killed by system
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Start audio recording and streaming
     */
    private fun startRecording() {
        if (recordingJob?.isActive == true) {
            Timber.w("Recording already in progress")
            return
        }

        Timber.d("Starting audio recording")

        // Generate unique session ID
        sessionId = "session_${System.currentTimeMillis()}"
        chunkCounter = 0

        // Create notification and start foreground
        val notification = createNotification()
        startForeground(NOTIFICATION_ID, notification)

        // Initialize AudioRecord
        try {
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                channelConfig,
                audioFormat,
                bufferSizeBytes
            ).apply {
                if (state != AudioRecord.STATE_INITIALIZED) {
                    throw IllegalStateException("AudioRecord initialization failed")
                }
            }

            // Start recording in background
            recordingJob = serviceScope.launch {
                captureAndStreamAudio()
            }

            Timber.d("Audio recording started successfully")
        } catch (e: Exception) {
            Timber.e(e, "Failed to start audio recording")
            stopSelf()
        }
    }

    /**
     * Core audio capture loop
     *
     * Continuously reads audio samples from microphone and sends chunks to server
     */
    private suspend fun captureAndStreamAudio() = withContext(Dispatchers.IO) {
        audioRecord?.startRecording()

        val chunkSizeBytes = (sampleRate * chunkDurationMs / 1000) * 2  // 2 bytes per sample (16-bit)
        val audioBuffer = ByteArray(chunkSizeBytes)
        var bytesRead = 0

        Timber.d("Starting audio capture loop (chunk size: $chunkSizeBytes bytes)")

        try {
            while (isActive) {
                // Read audio samples from microphone
                val readResult = audioRecord?.read(audioBuffer, bytesRead, chunkSizeBytes - bytesRead)

                if (readResult == null || readResult < 0) {
                    Timber.e("AudioRecord.read() failed with error: $readResult")
                    break
                }

                bytesRead += readResult

                // Once we have a complete chunk, process and send it
                if (bytesRead >= chunkSizeBytes) {
                    processAndSendChunk(audioBuffer.copyOf(chunkSizeBytes))
                    bytesRead = 0  // Reset for next chunk
                    chunkCounter++
                }
            }
        } catch (e: Exception) {
            Timber.e(e, "Error in audio capture loop")
        } finally {
            audioRecord?.stop()
            Timber.d("Audio capture loop stopped")
        }
    }

    /**
     * Process audio chunk and send to backend
     *
     * Steps:
     * 1. Apply Voice Activity Detection (VAD) to skip silent chunks
     * 2. Compress audio (Opus codec) - TODO: requires native library
     * 3. Send via WebSocket with metadata
     */
    private suspend fun processAndSendChunk(audioData: ByteArray) {
        // Calculate audio level for VAD (Voice Activity Detection)
        val audioLevel = calculateAudioLevel(audioData)
        val threshold = 500  // Adjust based on environment noise

        if (audioLevel < threshold) {
            Timber.d("Chunk $chunkCounter: Silent (level: $audioLevel), skipping")
            return
        }

        Timber.d("Chunk $chunkCounter: Active speech detected (level: $audioLevel)")

        // TODO: Compress audio with Opus codec here
        // val compressedData = opusEncoder.encode(audioData)

        // For now, send raw PCM (we'll add compression later)
        val compressedData = audioData

        // Send to backend via WebSocket
        webSocketClient.sendAudioChunk(
            sessionId = sessionId,
            chunkId = chunkCounter,
            audioData = compressedData,
            timestamp = System.currentTimeMillis()
        )
    }

    /**
     * Calculate RMS (Root Mean Square) audio level for VAD
     *
     * Returns a value representing the "loudness" of the audio chunk
     */
    private fun calculateAudioLevel(audioData: ByteArray): Double {
        val buffer = ByteBuffer.wrap(audioData).order(ByteOrder.LITTLE_ENDIAN)
        var sum = 0.0
        var count = 0

        while (buffer.hasRemaining()) {
            val sample = buffer.short.toDouble()
            sum += sample * sample
            count++
        }

        return if (count > 0) {
            kotlin.math.sqrt(sum / count)
        } else {
            0.0
        }
    }

    /**
     * Stop audio recording
     */
    private fun stopRecording() {
        Timber.d("Stopping audio recording")

        recordingJob?.cancel()
        recordingJob = null

        audioRecord?.apply {
            if (state == AudioRecord.STATE_INITIALIZED) {
                stop()
                release()
            }
        }
        audioRecord = null

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Create notification channel (required for Android 8.0+)
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Voice Recording",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Ongoing voice recording service"
                setShowBadge(false)
            }

            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    /**
     * Create foreground service notification
     */
    private fun createNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Voice Recording Active")
            .setContentText("Recording and transcribing audio...")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)  // Replace with your icon
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    override fun onDestroy() {
        super.onDestroy()
        Timber.d("AudioRecordingService destroyed")
        stopRecording()
        serviceScope.cancel()
    }
}

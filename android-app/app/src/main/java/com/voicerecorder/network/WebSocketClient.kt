package com.voicerecorder.network

import com.voicerecorder.BuildConfig
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.*
import okio.ByteString
import timber.log.Timber
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * WebSocket client for real-time audio streaming and transcript reception
 *
 * Features:
 * - Automatic reconnection with exponential backoff
 * - Connection state management
 * - Audio chunk upload
 * - Real-time transcript streaming
 * - JWT authentication
 */
@Singleton
class WebSocketClient @Inject constructor() {

    private val json = Json { ignoreUnknownKeys = true }

    private val okHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)  // No timeout for WebSocket
        .pingInterval(30, TimeUnit.SECONDS)  // Keep-alive ping
        .build()

    private var webSocket: WebSocket? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // Connection state
    private val _connectionState = MutableStateFlow(ConnectionState(isConnected = false))
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    // Incoming transcripts
    private val _transcriptFlow = MutableSharedFlow<TranscriptMessage>()
    val transcriptFlow: SharedFlow<TranscriptMessage> = _transcriptFlow.asSharedFlow()

    // Reconnection parameters
    private var reconnectAttempts = 0
    private val maxReconnectAttempts = 10
    private val baseReconnectDelay = 1000L  // 1 second

    // Authentication token (set before connecting)
    var authToken: String? = null

    /**
     * Connect to WebSocket server
     */
    suspend fun connect() {
        if (_connectionState.value.isConnected) {
            Timber.d("Already connected to WebSocket")
            return
        }

        Timber.d("Connecting to WebSocket: ${BuildConfig.SERVER_URL}")

        val request = Request.Builder()
            .url(BuildConfig.SERVER_URL + "/ws")
            .apply {
                if (authToken != null) {
                    addHeader("Authorization", "Bearer $authToken")
                }
            }
            .build()

        webSocket = okHttpClient.newWebSocket(request, webSocketListener)
    }

    /**
     * Disconnect from WebSocket server
     */
    suspend fun disconnect() {
        Timber.d("Disconnecting from WebSocket")
        webSocket?.close(1000, "Client disconnect")
        webSocket = null
        _connectionState.value = ConnectionState(isConnected = false)
    }

    /**
     * Send audio chunk to server
     */
    suspend fun sendAudioChunk(
        sessionId: String,
        chunkId: Int,
        audioData: ByteArray,
        timestamp: Long
    ) {
        if (!_connectionState.value.isConnected) {
            Timber.w("Cannot send audio chunk: not connected")
            // TODO: Queue chunks locally in Room database for later upload
            return
        }

        // Create message envelope
        val message = AudioChunkMessage(
            type = "audio_chunk",
            sessionId = sessionId,
            chunkId = chunkId,
            timestamp = timestamp,
            audioData = audioData.toBase64()  // or send as binary
        )

        val jsonMessage = json.encodeToString(message)

        // Send as binary for efficiency
        val byteString = ByteString.of(*jsonMessage.toByteArray())
        val sent = webSocket?.send(byteString) ?: false

        if (sent) {
            Timber.d("Sent audio chunk $chunkId (${audioData.size} bytes)")
        } else {
            Timber.e("Failed to send audio chunk $chunkId")
        }
    }

    /**
     * WebSocket event listener
     */
    private val webSocketListener = object : WebSocketListener() {

        override fun onOpen(webSocket: WebSocket, response: Response) {
            Timber.d("WebSocket opened: ${response.message}")
            _connectionState.value = ConnectionState(isConnected = true)
            reconnectAttempts = 0  // Reset reconnect counter
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            Timber.d("Received text message: $text")

            try {
                // Parse incoming transcript
                val transcript = json.decodeFromString<TranscriptMessage>(text)
                scope.launch {
                    _transcriptFlow.emit(transcript)
                }
            } catch (e: Exception) {
                Timber.e(e, "Failed to parse transcript message")
            }
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            Timber.d("Received binary message: ${bytes.size()} bytes")
            // Handle binary messages if needed
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            Timber.d("WebSocket closing: $code - $reason")
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            Timber.d("WebSocket closed: $code - $reason")
            _connectionState.value = ConnectionState(isConnected = false)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            Timber.e(t, "WebSocket failure: ${response?.message}")
            _connectionState.value = ConnectionState(isConnected = false)

            // Attempt reconnection with exponential backoff
            scope.launch {
                attemptReconnection()
            }
        }
    }

    /**
     * Attempt to reconnect with exponential backoff
     */
    private suspend fun attemptReconnection() {
        if (reconnectAttempts >= maxReconnectAttempts) {
            Timber.e("Max reconnection attempts reached, giving up")
            return
        }

        reconnectAttempts++
        val delay = baseReconnectDelay * (1 shl (reconnectAttempts - 1))  // Exponential backoff

        Timber.d("Reconnecting in ${delay}ms (attempt $reconnectAttempts/$maxReconnectAttempts)")

        delay(delay)
        connect()
    }

    fun cleanup() {
        scope.cancel()
        okHttpClient.dispatcher.executorService.shutdown()
    }
}

/**
 * Connection state
 */
data class ConnectionState(
    val isConnected: Boolean,
    val error: String? = null
)

/**
 * Audio chunk message sent to server
 */
@Serializable
data class AudioChunkMessage(
    val type: String,
    val sessionId: String,
    val chunkId: Int,
    val timestamp: Long,
    val audioData: String  // Base64 encoded audio
)

/**
 * Transcript message received from server
 */
@Serializable
data class TranscriptMessage(
    val id: String,
    val sessionId: String,
    val text: String,
    val timestamp: Long,
    val confidence: Float? = null,
    val language: String? = null
) {
    val formattedTimestamp: String
        get() {
            val date = java.util.Date(timestamp)
            return java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault()).format(date)
        }
}

/**
 * Extension function to convert ByteArray to Base64
 */
private fun ByteArray.toBase64(): String {
    return android.util.Base64.encodeToString(this, android.util.Base64.NO_WRAP)
}

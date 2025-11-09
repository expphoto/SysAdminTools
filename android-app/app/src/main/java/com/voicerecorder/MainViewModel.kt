package com.voicerecorder

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.voicerecorder.data.TranscriptRepository
import com.voicerecorder.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import timber.log.Timber
import javax.inject.Inject

/**
 * ViewModel for the main screen
 *
 * Manages:
 * - Recording state
 * - Live transcript stream from WebSocket
 * - Connection status
 * - Recording duration timer
 */
@HiltViewModel
class MainViewModel @Inject constructor(
    private val webSocketClient: WebSocketClient,
    private val transcriptRepository: TranscriptRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(MainUiState())
    val uiState: StateFlow<MainUiState> = _uiState.asStateFlow()

    private var timerJob: Job? = null

    init {
        // Observe connection status
        viewModelScope.launch {
            webSocketClient.connectionState.collect { connectionState ->
                _uiState.update { it.copy(isConnectedToServer = connectionState.isConnected) }
                Timber.d("Connection state: $connectionState")
            }
        }

        // Observe incoming transcripts from WebSocket
        viewModelScope.launch {
            webSocketClient.transcriptFlow.collect { transcript ->
                Timber.d("Received transcript: ${transcript.text}")

                // Add to UI state
                _uiState.update { state ->
                    state.copy(
                        transcripts = state.transcripts + Transcript(
                            id = transcript.id,
                            text = transcript.text,
                            timestamp = transcript.formattedTimestamp,
                            confidence = transcript.confidence
                        )
                    )
                }

                // Save to local database
                transcriptRepository.insertTranscript(transcript)
            }
        }
    }

    fun startRecording() {
        Timber.d("Starting recording")
        _uiState.update { it.copy(isRecording = true, recordingDurationSeconds = 0) }

        // Start duration timer
        timerJob = viewModelScope.launch {
            while (true) {
                delay(1000)
                _uiState.update { it.copy(recordingDurationSeconds = it.recordingDurationSeconds + 1) }
            }
        }

        // Connect to WebSocket server
        viewModelScope.launch {
            webSocketClient.connect()
        }
    }

    fun stopRecording() {
        Timber.d("Stopping recording")
        _uiState.update { it.copy(isRecording = false) }

        // Stop timer
        timerJob?.cancel()
        timerJob = null

        // Disconnect from server
        viewModelScope.launch {
            webSocketClient.disconnect()
        }
    }

    override fun onCleared() {
        super.onCleared()
        timerJob?.cancel()
        viewModelScope.launch {
            webSocketClient.disconnect()
        }
    }
}

/**
 * UI state for the main screen
 */
data class MainUiState(
    val isRecording: Boolean = false,
    val isConnectedToServer: Boolean = false,
    val transcripts: List<Transcript> = emptyList(),
    val recordingDurationSeconds: Int = 0,
    val errorMessage: String? = null
)

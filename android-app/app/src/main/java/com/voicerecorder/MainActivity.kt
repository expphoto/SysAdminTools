package com.voicerecorder

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.voicerecorder.service.AudioRecordingService
import com.voicerecorder.ui.theme.VoiceRecorderTheme
import dagger.hilt.android.AndroidEntryPoint
import timber.log.Timber

/**
 * Main Activity for the Voice Recorder app
 *
 * Responsibilities:
 * - Request necessary permissions (RECORD_AUDIO, POST_NOTIFICATIONS)
 * - Start/stop the audio recording foreground service
 * - Display live transcripts in real-time
 * - Provide UI controls for recording
 */
@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    private val requestPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        val allGranted = permissions.entries.all { it.value }
        if (allGranted) {
            Timber.d("All permissions granted")
        } else {
            Timber.w("Some permissions denied: ${permissions.filter { !it.value }}")
            // Show explanation dialog
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Request runtime permissions
        checkAndRequestPermissions()

        setContent {
            VoiceRecorderTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    MainScreen(
                        onStartRecording = { startRecordingService() },
                        onStopRecording = { stopRecordingService() }
                    )
                }
            }
        }
    }

    private fun checkAndRequestPermissions() {
        val permissions = mutableListOf(Manifest.permission.RECORD_AUDIO)

        // POST_NOTIFICATIONS permission required for Android 13+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        val permissionsToRequest = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (permissionsToRequest.isNotEmpty()) {
            requestPermissionLauncher.launch(permissionsToRequest.toTypedArray())
        }
    }

    private fun startRecordingService() {
        val intent = Intent(this, AudioRecordingService::class.java).apply {
            action = AudioRecordingService.ACTION_START
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }

        Timber.d("Started AudioRecordingService")
    }

    private fun stopRecordingService() {
        val intent = Intent(this, AudioRecordingService::class.java).apply {
            action = AudioRecordingService.ACTION_STOP
        }
        startService(intent)
        Timber.d("Stopped AudioRecordingService")
    }
}

/**
 * Main UI screen showing live transcripts and recording controls
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    viewModel: MainViewModel = hiltViewModel(),
    onStartRecording: () -> Unit,
    onStopRecording: () -> Unit
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()

    // Auto-scroll to bottom when new transcript arrives
    LaunchedEffect(uiState.transcripts.size) {
        if (uiState.transcripts.isNotEmpty()) {
            listState.animateScrollToItem(uiState.transcripts.size - 1)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Voice Recorder") },
                actions = {
                    IconButton(onClick = { /* TODO: Open settings */ }) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings")
                    }
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = {
                    if (uiState.isRecording) {
                        onStopRecording()
                        viewModel.stopRecording()
                    } else {
                        onStartRecording()
                        viewModel.startRecording()
                    }
                },
                containerColor = if (uiState.isRecording) {
                    MaterialTheme.colorScheme.error
                } else {
                    MaterialTheme.colorScheme.primary
                }
            ) {
                Icon(
                    imageVector = if (uiState.isRecording) Icons.Default.Stop else Icons.Default.Mic,
                    contentDescription = if (uiState.isRecording) "Stop Recording" else "Start Recording"
                )
            }
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            // Status bar
            RecordingStatusBar(
                isRecording = uiState.isRecording,
                isConnected = uiState.isConnectedToServer,
                recordingDuration = uiState.recordingDurationSeconds
            )

            Divider()

            // Transcripts list
            if (uiState.transcripts.isEmpty()) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                            imageVector = Icons.Default.Mic,
                            contentDescription = null,
                            modifier = Modifier.size(64.dp),
                            tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.3f)
                        )
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(
                            text = "Tap the mic to start recording",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                        )
                    }
                }
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(uiState.transcripts, key = { it.id }) { transcript ->
                        TranscriptItem(transcript = transcript)
                    }
                }
            }
        }
    }
}

/**
 * Recording status bar showing connection state and duration
 */
@Composable
fun RecordingStatusBar(
    isRecording: Boolean,
    isConnected: Boolean,
    recordingDuration: Int
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = when {
            !isConnected && isRecording -> MaterialTheme.colorScheme.errorContainer
            isRecording -> MaterialTheme.colorScheme.primaryContainer
            else -> MaterialTheme.colorScheme.surfaceVariant
        }
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = if (isRecording) Icons.Default.FiberManualRecord else Icons.Default.MicOff,
                    contentDescription = null,
                    tint = if (isRecording) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = if (isRecording) "Recording" else "Stopped",
                    style = MaterialTheme.typography.bodyMedium
                )
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = if (isConnected) Icons.Default.CloudDone else Icons.Default.CloudOff,
                    contentDescription = null,
                    tint = if (isConnected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = if (isRecording) formatDuration(recordingDuration) else "--:--",
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }
    }
}

/**
 * Single transcript item card
 */
@Composable
fun TranscriptItem(transcript: Transcript) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = transcript.timestamp,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (transcript.confidence != null) {
                    Text(
                        text = "${(transcript.confidence * 100).toInt()}%",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = transcript.text,
                style = MaterialTheme.typography.bodyMedium
            )
        }
    }
}

/**
 * Format seconds to MM:SS
 */
private fun formatDuration(seconds: Int): String {
    val minutes = seconds / 60
    val secs = seconds % 60
    return "%02d:%02d".format(minutes, secs)
}

/**
 * Data class representing a transcript segment
 */
data class Transcript(
    val id: String,
    val text: String,
    val timestamp: String,
    val confidence: Float? = null
)

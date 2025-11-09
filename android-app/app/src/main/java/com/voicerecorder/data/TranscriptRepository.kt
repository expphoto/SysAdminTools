package com.voicerecorder.data

import com.voicerecorder.network.TranscriptMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Repository for managing transcript data
 *
 * Handles:
 * - Local caching of transcripts in Room database
 * - Syncing with backend server
 * - Searching transcripts
 */
@Singleton
class TranscriptRepository @Inject constructor(
    private val transcriptDao: TranscriptDao
) {

    /**
     * Insert a new transcript from WebSocket
     */
    suspend fun insertTranscript(transcript: TranscriptMessage) = withContext(Dispatchers.IO) {
        val entity = TranscriptEntity(
            id = transcript.id,
            sessionId = transcript.sessionId,
            text = transcript.text,
            timestamp = transcript.timestamp,
            confidence = transcript.confidence,
            language = transcript.language
        )
        transcriptDao.insert(entity)
    }

    /**
     * Get all transcripts for a session
     */
    suspend fun getTranscriptsBySession(sessionId: String): List<TranscriptEntity> =
        withContext(Dispatchers.IO) {
            transcriptDao.getTranscriptsBySession(sessionId)
        }

    /**
     * Search transcripts by text
     */
    suspend fun searchTranscripts(query: String): List<TranscriptEntity> =
        withContext(Dispatchers.IO) {
            transcriptDao.searchTranscripts("%$query%")
        }

    /**
     * Delete old transcripts
     */
    suspend fun deleteOldTranscripts(beforeTimestamp: Long) = withContext(Dispatchers.IO) {
        transcriptDao.deleteOldTranscripts(beforeTimestamp)
    }
}

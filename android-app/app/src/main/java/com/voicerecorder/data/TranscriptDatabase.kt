package com.voicerecorder.data

import androidx.room.*
import kotlinx.coroutines.flow.Flow

/**
 * Room database for local transcript storage
 */
@Database(
    entities = [TranscriptEntity::class, AudioChunkEntity::class],
    version = 1,
    exportSchema = false
)
abstract class TranscriptDatabase : RoomDatabase() {
    abstract fun transcriptDao(): TranscriptDao
    abstract fun audioChunkDao(): AudioChunkDao
}

/**
 * Entity representing a transcript segment
 */
@Entity(tableName = "transcripts")
data class TranscriptEntity(
    @PrimaryKey val id: String,
    val sessionId: String,
    val text: String,
    val timestamp: Long,
    val confidence: Float?,
    val language: String?,
    val createdAt: Long = System.currentTimeMillis()
)

/**
 * Entity for caching unsent audio chunks (for offline mode)
 */
@Entity(tableName = "audio_chunks")
data class AudioChunkEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val sessionId: String,
    val chunkId: Int,
    val audioData: ByteArray,
    val timestamp: Long,
    val uploaded: Boolean = false
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as AudioChunkEntity

        if (id != other.id) return false
        if (sessionId != other.sessionId) return false
        if (chunkId != other.chunkId) return false
        if (!audioData.contentEquals(other.audioData)) return false
        if (timestamp != other.timestamp) return false
        if (uploaded != other.uploaded) return false

        return true
    }

    override fun hashCode(): Int {
        var result = id.hashCode()
        result = 31 * result + sessionId.hashCode()
        result = 31 * result + chunkId
        result = 31 * result + audioData.contentHashCode()
        result = 31 * result + timestamp.hashCode()
        result = 31 * result + uploaded.hashCode()
        return result
    }
}

/**
 * DAO for transcript operations
 */
@Dao
interface TranscriptDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(transcript: TranscriptEntity)

    @Query("SELECT * FROM transcripts WHERE sessionId = :sessionId ORDER BY timestamp ASC")
    suspend fun getTranscriptsBySession(sessionId: String): List<TranscriptEntity>

    @Query("SELECT * FROM transcripts WHERE text LIKE :query ORDER BY timestamp DESC")
    suspend fun searchTranscripts(query: String): List<TranscriptEntity>

    @Query("SELECT * FROM transcripts ORDER BY timestamp DESC LIMIT :limit")
    suspend fun getRecentTranscripts(limit: Int = 100): List<TranscriptEntity>

    @Query("DELETE FROM transcripts WHERE timestamp < :beforeTimestamp")
    suspend fun deleteOldTranscripts(beforeTimestamp: Long)

    @Query("DELETE FROM transcripts")
    suspend fun deleteAll()
}

/**
 * DAO for audio chunk cache operations
 */
@Dao
interface AudioChunkDao {

    @Insert
    suspend fun insert(chunk: AudioChunkEntity)

    @Query("SELECT * FROM audio_chunks WHERE uploaded = 0 ORDER BY timestamp ASC LIMIT :limit")
    suspend fun getUnuploadedChunks(limit: Int = 100): List<AudioChunkEntity>

    @Query("UPDATE audio_chunks SET uploaded = 1 WHERE id = :chunkId")
    suspend fun markAsUploaded(chunkId: Long)

    @Query("DELETE FROM audio_chunks WHERE uploaded = 1 AND timestamp < :beforeTimestamp")
    suspend fun deleteOldUploadedChunks(beforeTimestamp: Long)

    @Query("SELECT COUNT(*) FROM audio_chunks WHERE uploaded = 0")
    fun getUnuploadedCount(): Flow<Int>
}

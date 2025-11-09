"""
Transcription Service using Whisper

Handles:
- Loading Whisper model
- Converting audio bytes to transcribed text
- Confidence scoring
- Multi-language support
"""

import io
import tempfile
from typing import Tuple
from loguru import logger
import numpy as np
import soundfile as sf

from app.config import settings


class TranscriptionService:
    """
    Service for transcribing audio using faster-whisper

    faster-whisper is a reimplementation of OpenAI Whisper using CTranslate2,
    which is 4x faster than the original implementation.
    """

    def __init__(self):
        self.model = None
        self.initialized = False

    async def initialize(self):
        """
        Load the Whisper model

        This can take 10-30 seconds depending on model size and device
        """
        from faster_whisper import WhisperModel

        try:
            logger.info(f"Loading Whisper model: {settings.WHISPER_MODEL} on {settings.WHISPER_DEVICE}")

            self.model = WhisperModel(
                settings.WHISPER_MODEL,
                device=settings.WHISPER_DEVICE,
                compute_type=settings.WHISPER_COMPUTE_TYPE,
                cpu_threads=4,
                num_workers=1
            )

            self.initialized = True
            logger.info("Whisper model loaded successfully")

        except Exception as e:
            logger.error(f"Failed to load Whisper model: {e}")
            logger.warning("Falling back to CPU mode")

            # Fallback to CPU
            try:
                self.model = WhisperModel(
                    settings.WHISPER_MODEL,
                    device="cpu",
                    compute_type="int8",
                )
                self.initialized = True
                logger.info("Whisper model loaded on CPU")
            except Exception as e2:
                logger.error(f"Failed to load Whisper model on CPU: {e2}")
                raise

    def is_initialized(self) -> bool:
        """
        Check if model is loaded
        """
        return self.initialized

    async def transcribe_chunk(self, audio_bytes: bytes) -> Tuple[str, float]:
        """
        Transcribe an audio chunk

        Args:
            audio_bytes: Raw PCM audio data (16-bit, 16kHz, mono)

        Returns:
            (transcript_text, confidence_score)
        """
        if not self.initialized:
            raise RuntimeError("Transcription service not initialized")

        try:
            # Convert bytes to numpy array
            audio_array = self._bytes_to_audio_array(audio_bytes)

            # Transcribe using Whisper
            segments, info = self.model.transcribe(
                audio_array,
                language="en",  # Can be auto-detected or specified
                beam_size=5,
                best_of=5,
                temperature=0.0,
                vad_filter=True,  # Voice Activity Detection
                vad_parameters=dict(
                    min_silence_duration_ms=500
                )
            )

            # Combine all segments
            transcript_text = ""
            total_confidence = 0.0
            segment_count = 0

            for segment in segments:
                transcript_text += segment.text + " "
                total_confidence += segment.avg_logprob
                segment_count += 1

            transcript_text = transcript_text.strip()

            # Calculate average confidence
            # avg_logprob is typically -0.1 to -1.0, convert to 0.0-1.0 scale
            if segment_count > 0:
                avg_confidence = total_confidence / segment_count
                # Convert log probability to probability (approximate)
                confidence = max(0.0, min(1.0, np.exp(avg_confidence)))
            else:
                confidence = 0.0

            logger.debug(f"Transcribed: '{transcript_text}' (confidence: {confidence:.2f})")

            return transcript_text, confidence

        except Exception as e:
            logger.error(f"Transcription error: {e}")
            return "", 0.0

    def _bytes_to_audio_array(self, audio_bytes: bytes) -> np.ndarray:
        """
        Convert raw PCM bytes to numpy array for Whisper

        Assumes:
        - 16-bit PCM
        - 16kHz sample rate
        - Mono channel
        """
        # Convert bytes to numpy array
        audio_array = np.frombuffer(audio_bytes, dtype=np.int16)

        # Convert to float32 in range [-1.0, 1.0]
        audio_array = audio_array.astype(np.float32) / 32768.0

        return audio_array

    async def transcribe_file(self, file_path: str) -> Tuple[str, float]:
        """
        Transcribe an audio file

        Useful for batch processing or testing
        """
        if not self.initialized:
            raise RuntimeError("Transcription service not initialized")

        segments, info = self.model.transcribe(file_path, language="en")

        transcript_text = ""
        total_confidence = 0.0
        segment_count = 0

        for segment in segments:
            transcript_text += segment.text + " "
            total_confidence += segment.avg_logprob
            segment_count += 1

        transcript_text = transcript_text.strip()

        if segment_count > 0:
            avg_confidence = total_confidence / segment_count
            confidence = max(0.0, min(1.0, np.exp(avg_confidence)))
        else:
            confidence = 0.0

        return transcript_text, confidence


# Singleton instance
_transcription_service: TranscriptionService | None = None


def get_transcription_service() -> TranscriptionService:
    """
    Get singleton transcription service instance
    """
    global _transcription_service

    if _transcription_service is None:
        _transcription_service = TranscriptionService()

    return _transcription_service

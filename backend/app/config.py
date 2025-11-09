"""
Configuration settings for the backend server

Uses pydantic-settings to load from environment variables or .env file
"""

from pydantic_settings import BaseSettings
from typing import List


class Settings(BaseSettings):
    """
    Application settings

    Override via environment variables or .env file
    """

    # Server
    HOST: str = "0.0.0.0"
    PORT: int = 8000
    DEBUG: bool = True

    # Database
    DATABASE_URL: str = "postgresql+asyncpg://voiceapp:password@localhost/transcripts"

    # Redis
    REDIS_URL: str = "redis://localhost:6379"

    # JWT Authentication
    JWT_SECRET: str = "your-secret-key-change-this-in-production"
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRATION_DAYS: int = 7

    # CORS
    CORS_ORIGINS: List[str] = ["*"]  # Change to specific origins in production

    # Whisper Configuration
    WHISPER_MODEL: str = "medium.en"  # Options: tiny, base, small, medium, large
    WHISPER_DEVICE: str = "cuda"  # Options: cuda, cpu
    WHISPER_COMPUTE_TYPE: str = "float16"  # Options: float16, int8, float32

    # Audio Processing
    SAMPLE_RATE: int = 16000
    CHUNK_DURATION_MS: int = 3000

    # Storage
    AUDIO_ARCHIVE_ENABLED: bool = False  # Whether to save raw audio chunks
    AUDIO_ARCHIVE_PATH: str = "/data/audio_archive"

    # Rate Limiting
    RATE_LIMIT_PER_MINUTE: int = 100

    class Config:
        env_file = ".env"
        case_sensitive = True


settings = Settings()

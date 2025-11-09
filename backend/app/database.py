"""
Database models and operations

Uses SQLAlchemy with async PostgreSQL driver (asyncpg)
"""

from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import declarative_base
from sqlalchemy import Column, String, Integer, Float, DateTime, Boolean, Text, select
from datetime import datetime
from typing import List, Optional
from loguru import logger

from app.config import settings

# Create async engine
engine = create_async_engine(
    settings.DATABASE_URL,
    echo=settings.DEBUG,
    future=True
)

# Create session factory
AsyncSessionLocal = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False
)

# Base class for models
Base = declarative_base()


# ============================================================================
# Database Models
# ============================================================================

class User(Base):
    """User account model"""
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    email = Column(String(255), unique=True, index=True, nullable=False)
    password_hash = Column(String(255), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    is_active = Column(Boolean, default=True)


class Session(Base):
    """Recording session model"""
    __tablename__ = "sessions"

    id = Column(String(255), primary_key=True, index=True)
    user_id = Column(Integer, nullable=True)  # Foreign key to users
    started_at = Column(DateTime, nullable=False)
    ended_at = Column(DateTime, nullable=True)
    device_info = Column(Text, nullable=True)  # JSON string
    status = Column(String(50), default="active")  # active, paused, completed


class Transcript(Base):
    """Transcript segment model"""
    __tablename__ = "transcripts"

    id = Column(String(255), primary_key=True, index=True)
    session_id = Column(String(255), index=True, nullable=False)
    audio_chunk_id = Column(Integer, nullable=True)
    text = Column(Text, nullable=False)
    confidence = Column(Float, nullable=True)
    timestamp = Column(DateTime, nullable=False)
    language = Column(String(10), default="en")
    created_at = Column(DateTime, default=datetime.utcnow)


# ============================================================================
# Database Operations
# ============================================================================

async def init_db():
    """
    Initialize database (create tables)

    In production, use Alembic migrations instead
    """
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        logger.info("Database initialized successfully")
    except Exception as e:
        logger.error(f"Failed to initialize database: {e}")
        raise


async def close_db():
    """
    Close database connections
    """
    await engine.dispose()
    logger.info("Database connections closed")


async def check_db_health() -> bool:
    """
    Check if database connection is healthy
    """
    try:
        async with AsyncSessionLocal() as session:
            await session.execute(select(1))
        return True
    except Exception as e:
        logger.error(f"Database health check failed: {e}")
        return False


# ============================================================================
# Transcript Operations
# ============================================================================

async def save_transcript(transcript_data: dict) -> Transcript:
    """
    Save a transcript to the database
    """
    async with AsyncSessionLocal() as session:
        transcript = Transcript(
            id=transcript_data["id"],
            session_id=transcript_data["sessionId"],
            text=transcript_data["text"],
            confidence=transcript_data.get("confidence"),
            timestamp=datetime.fromtimestamp(transcript_data["timestamp"] / 1000),
            language=transcript_data.get("language", "en")
        )

        session.add(transcript)
        await session.commit()
        await session.refresh(transcript)

        return transcript


async def get_transcripts(
    session_id: Optional[str] = None,
    limit: int = 100,
    offset: int = 0
) -> List[dict]:
    """
    Retrieve transcripts with optional filtering
    """
    async with AsyncSessionLocal() as session:
        query = select(Transcript)

        if session_id:
            query = query.where(Transcript.session_id == session_id)

        query = query.order_by(Transcript.timestamp.desc())
        query = query.limit(limit).offset(offset)

        result = await session.execute(query)
        transcripts = result.scalars().all()

        return [
            {
                "id": t.id,
                "sessionId": t.session_id,
                "text": t.text,
                "confidence": t.confidence,
                "timestamp": t.timestamp.isoformat(),
                "language": t.language
            }
            for t in transcripts
        ]


async def search_transcripts(query: str, limit: int = 50) -> List[dict]:
    """
    Full-text search across transcripts

    Uses PostgreSQL full-text search
    """
    async with AsyncSessionLocal() as session:
        # Simple LIKE search (upgrade to PostgreSQL full-text search for production)
        stmt = select(Transcript).where(
            Transcript.text.ilike(f"%{query}%")
        ).limit(limit)

        result = await session.execute(stmt)
        transcripts = result.scalars().all()

        return [
            {
                "id": t.id,
                "sessionId": t.session_id,
                "text": t.text,
                "confidence": t.confidence,
                "timestamp": t.timestamp.isoformat(),
                "language": t.language
            }
            for t in transcripts
        ]


async def delete_transcript(transcript_id: str) -> bool:
    """
    Delete a transcript
    """
    async with AsyncSessionLocal() as session:
        stmt = select(Transcript).where(Transcript.id == transcript_id)
        result = await session.execute(stmt)
        transcript = result.scalar_one_or_none()

        if transcript:
            await session.delete(transcript)
            await session.commit()
            return True

        return False


# ============================================================================
# Dependency Injection
# ============================================================================

async def get_db() -> AsyncSession:
    """
    Get database session for dependency injection
    """
    async with AsyncSessionLocal() as session:
        yield session

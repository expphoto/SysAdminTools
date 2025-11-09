"""
Main FastAPI Application for Voice Recording Backend

Provides:
- WebSocket endpoint for real-time audio streaming
- REST API for transcript management
- Authentication system
- Health checks
"""

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Depends, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from contextlib import asynccontextmanager
from loguru import logger
import sys
from typing import List

from app.config import settings
from app.websocket_manager import WebSocketManager
from app.auth import get_current_user
from app.database import init_db, close_db
from app.models import Transcript, User, TranscriptResponse
from app.transcription import TranscriptionService

# Configure logging
logger.remove()
logger.add(sys.stdout, level="INFO", format="<green>{time:YYYY-MM-DD HH:mm:ss}</green> | <level>{level: <8}</level> | <cyan>{name}</cyan>:<cyan>{function}</cyan> - <level>{message}</level>")


# Lifespan event handler for startup/shutdown
@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Startup and shutdown events
    """
    # Startup
    logger.info("Starting Voice Recording Backend...")
    await init_db()

    # Initialize Whisper model (can take 10-30 seconds)
    logger.info("Loading Whisper transcription model...")
    transcription_service = TranscriptionService()
    await transcription_service.initialize()
    app.state.transcription_service = transcription_service

    logger.info("Backend server started successfully")

    yield

    # Shutdown
    logger.info("Shutting down backend server...")
    await close_db()
    logger.info("Shutdown complete")


# Create FastAPI app
app = FastAPI(
    title="Voice Recording Backend API",
    description="Real-time voice recording and transcription system",
    version="1.0.0",
    lifespan=lifespan
)

# CORS middleware (adjust origins for production)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# WebSocket connection manager
ws_manager = WebSocketManager()


# ============================================================================
# WebSocket Endpoints
# ============================================================================

@app.websocket("/ws")
async def websocket_endpoint(
    websocket: WebSocket,
    # token: str = Depends(get_current_user_ws)  # TODO: Add WebSocket auth
):
    """
    WebSocket endpoint for real-time audio streaming

    Flow:
    1. Client connects and sends auth token
    2. Server validates token and adds connection to manager
    3. Client streams audio chunks
    4. Server queues chunks for transcription
    5. Server sends back transcripts in real-time
    """
    client_id = f"client_{id(websocket)}"

    try:
        await ws_manager.connect(websocket, client_id)
        logger.info(f"Client {client_id} connected via WebSocket")

        while True:
            # Receive message from client
            data = await websocket.receive_json()

            message_type = data.get("type")

            if message_type == "audio_chunk":
                # Handle audio chunk
                await handle_audio_chunk(websocket, client_id, data)

            elif message_type == "ping":
                # Respond to ping
                await websocket.send_json({"type": "pong"})

            else:
                logger.warning(f"Unknown message type: {message_type}")

    except WebSocketDisconnect:
        logger.info(f"Client {client_id} disconnected")
        ws_manager.disconnect(client_id)

    except Exception as e:
        logger.error(f"WebSocket error for client {client_id}: {e}")
        ws_manager.disconnect(client_id)


async def handle_audio_chunk(websocket: WebSocket, client_id: str, data: dict):
    """
    Process incoming audio chunk

    Steps:
    1. Decode audio data
    2. Add to transcription queue (Redis)
    3. Process with Whisper
    4. Save to database
    5. Send transcript back to client
    """
    import base64
    from app.queue import add_to_transcription_queue

    session_id = data.get("sessionId")
    chunk_id = data.get("chunkId")
    audio_data_b64 = data.get("audioData")
    timestamp = data.get("timestamp")

    # Decode audio data
    audio_bytes = base64.b64decode(audio_data_b64)

    logger.debug(f"Received audio chunk {chunk_id} from {client_id}: {len(audio_bytes)} bytes")

    # Send ACK to client
    await websocket.send_json({
        "type": "ack",
        "chunkId": chunk_id
    })

    # Add to transcription queue
    # In a real system, this would push to Redis queue and a worker would process it
    # For this scaffold, we'll process synchronously (not ideal for production)

    try:
        # Get transcription service
        transcription_service: TranscriptionService = app.state.transcription_service

        # Transcribe audio
        transcript_text, confidence = await transcription_service.transcribe_chunk(audio_bytes)

        if transcript_text:
            # Create transcript response
            transcript_response = {
                "type": "transcript",
                "id": f"{session_id}_{chunk_id}",
                "sessionId": session_id,
                "text": transcript_text,
                "timestamp": timestamp,
                "confidence": confidence,
                "language": "en"
            }

            # Send transcript back to client
            await websocket.send_json(transcript_response)

            logger.info(f"Transcribed chunk {chunk_id}: '{transcript_text}' (confidence: {confidence:.2f})")

            # TODO: Save to database
            # await save_transcript_to_db(transcript_response)

    except Exception as e:
        logger.error(f"Error transcribing chunk {chunk_id}: {e}")
        await websocket.send_json({
            "type": "error",
            "chunkId": chunk_id,
            "error": str(e)
        })


# ============================================================================
# REST API Endpoints
# ============================================================================

@app.get("/")
async def root():
    """
    Root endpoint
    """
    return {
        "message": "Voice Recording Backend API",
        "version": "1.0.0",
        "docs": "/docs"
    }


@app.get("/health")
async def health_check():
    """
    Health check endpoint for monitoring

    Checks:
    - Database connection
    - Redis connection
    - Whisper model loaded
    - Disk space
    """
    from app.database import check_db_health

    checks = {
        "status": "healthy",
        "database": await check_db_health(),
        "whisper_model": app.state.transcription_service.is_initialized(),
        # "redis": await check_redis_health(),
        # "disk_space": check_disk_space() > 10_000_000_000  # 10GB
    }

    if all(checks.values()):
        return JSONResponse(content=checks, status_code=200)
    else:
        return JSONResponse(content=checks, status_code=503)


@app.get("/api/transcripts", response_model=List[TranscriptResponse])
async def get_transcripts(
    session_id: str | None = None,
    limit: int = 100,
    offset: int = 0,
    # current_user: User = Depends(get_current_user)
):
    """
    Get transcripts with optional filtering

    Query Parameters:
    - session_id: Filter by recording session
    - limit: Max number of results
    - offset: Pagination offset
    """
    from app.database import get_transcripts

    transcripts = await get_transcripts(
        session_id=session_id,
        limit=limit,
        offset=offset
    )

    return transcripts


@app.get("/api/transcripts/search")
async def search_transcripts(
    q: str,
    limit: int = 50,
    # current_user: User = Depends(get_current_user)
):
    """
    Full-text search across all transcripts

    Query Parameters:
    - q: Search query
    - limit: Max results
    """
    from app.database import search_transcripts

    results = await search_transcripts(query=q, limit=limit)

    return {
        "query": q,
        "count": len(results),
        "results": results
    }


@app.delete("/api/transcripts/{transcript_id}")
async def delete_transcript(
    transcript_id: str,
    # current_user: User = Depends(get_current_user)
):
    """
    Delete a specific transcript
    """
    from app.database import delete_transcript

    success = await delete_transcript(transcript_id)

    if success:
        return {"message": "Transcript deleted successfully"}
    else:
        raise HTTPException(status_code=404, detail="Transcript not found")


@app.get("/api/sessions")
async def get_sessions(
    limit: int = 50,
    # current_user: User = Depends(get_current_user)
):
    """
    Get all recording sessions
    """
    # TODO: Implement session retrieval
    return {
        "sessions": [],
        "count": 0
    }


@app.post("/api/auth/register")
async def register(email: str, password: str):
    """
    Register a new user account
    """
    # TODO: Implement user registration
    return {"message": "User registered successfully"}


@app.post("/api/auth/login")
async def login(email: str, password: str):
    """
    Login and get JWT token

    Returns:
    - access_token: JWT token for API authentication
    - token_type: "bearer"
    - expires_in: Token expiry in seconds
    """
    from app.auth import create_access_token

    # TODO: Validate credentials against database
    # For now, return mock token

    access_token = create_access_token(data={"sub": email})

    return {
        "access_token": access_token,
        "token_type": "bearer",
        "expires_in": 604800  # 7 days
    }


# ============================================================================
# Development Utilities
# ============================================================================

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,  # Auto-reload on code changes
        log_level="info"
    )

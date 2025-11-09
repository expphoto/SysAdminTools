# Always-On Voice Recording & Transcription System
## Technical Design Document

---

## 1. System Overview

### Vision
A Limitless-style always-on voice recording system that continuously captures audio from your Android phone, streams it to your own backend server for real-time transcription, and displays live transcripts with searchable history.

### Core Objectives
- **Continuous Recording**: 24/7 audio capture with minimal battery impact
- **Real-Time Streaming**: Low-latency audio transmission to backend
- **Live Transcription**: Real-time speech-to-text processing
- **Privacy First**: All data on your infrastructure, no third-party cloud
- **Reliable**: Handles network interruptions, reconnection logic
- **Searchable**: Full-text search across all transcripts

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     ANDROID APP                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   Audio      │─▶│   Audio      │─▶│   Network    │      │
│  │  Capture     │  │   Buffer     │  │   Client     │      │
│  │ (Foreground  │  │  (Chunking)  │  │ (WebSocket)  │      │
│  │   Service)   │  │              │  │              │      │
│  └──────────────┘  └──────────────┘  └──────┬───────┘      │
│         │                                     │              │
│         │                                     │ Audio Stream │
│  ┌──────▼──────────────────────────────┐     │              │
│  │      UI Layer (Jetpack Compose)      │     │              │
│  │  - Live Transcript Display           │     │              │
│  │  - Recording Status                  │     │              │
│  │  - Search & History                  │     │              │
│  └──────────────────────────────────────┘     │              │
└────────────────────────────────────────────────┼──────────────┘
                                                 │
                                                 │ HTTPS/WSS
                                                 │
┌────────────────────────────────────────────────▼──────────────┐
│                    BACKEND SERVER                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │
│  │   WebSocket  │─▶│   Audio      │─▶│ Transcription│        │
│  │   Handler    │  │   Queue      │  │   Engine     │        │
│  │              │  │   (Redis)    │  │  (Whisper)   │        │
│  └──────────────┘  └──────────────┘  └──────┬───────┘        │
│                                               │                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────▼───────┐        │
│  │   REST API   │◀─│   Database   │◀─│ Transcript   │        │
│  │  (FastAPI)   │  │  (Postgres)  │  │  Processor   │        │
│  │              │  │              │  │              │        │
│  └──────────────┘  └──────────────┘  └──────────────┘        │
│                                                                │
│  ┌──────────────────────────────────────────────────┐        │
│  │        Authentication & Security Layer           │        │
│  │     (JWT tokens, API keys, TLS/SSL)              │        │
│  └──────────────────────────────────────────────────┘        │
└────────────────────────────────────────────────────────────────┘
```

---

## 3. Component Breakdown

### 3.1 Android App Components

#### A. Audio Capture Service (Foreground Service)
**Purpose**: Continuously capture audio from device microphone
**Technology**:
- `AudioRecord` API (low-level access for streaming)
- Foreground Service with notification (prevents system kill)
- `WorkManager` for reliability and restart logic

**Rationale**:
- `AudioRecord` over `MediaRecorder` for real-time streaming (MediaRecorder writes to file)
- Foreground service ensures Android won't kill the process
- PCM 16-bit, 16kHz mono format (balance between quality and bandwidth)

**Key Responsibilities**:
- Initialize audio recording session
- Capture audio in continuous loop
- Write to circular buffer
- Handle audio focus and interruptions (calls, notifications)
- Battery optimization (reduce sample rate when idle)

#### B. Audio Buffer & Chunking
**Purpose**: Segment continuous audio into transmittable chunks
**Technology**: Kotlin coroutines with Flow/Channel

**Rationale**:
- Chunks of 3-5 seconds balance latency vs. transcription accuracy
- Overlapping chunks (500ms overlap) prevent word cutoff at boundaries
- VAD (Voice Activity Detection) to skip silent periods (battery/bandwidth)

**Key Responsibilities**:
- Buffer audio samples into fixed-size chunks
- Compress audio (Opus codec via libopus) before transmission
- Implement VAD to detect speech vs. silence
- Queue management (drop old chunks if network slow)

#### C. Network Client
**Purpose**: Stream audio chunks to backend reliably
**Technology**:
- OkHttp WebSocket for bi-directional streaming
- Retrofit for REST API calls (auth, history fetch)
- Protobuf or MessagePack for efficient binary serialization

**Rationale**:
- WebSocket for persistent connection (lower latency than HTTP polling)
- Automatic reconnection with exponential backoff
- Binary protocol reduces overhead vs. JSON

**Key Responsibilities**:
- Establish and maintain WebSocket connection
- Send audio chunks with metadata (timestamp, sequence number)
- Receive live transcripts from server
- Handle reconnection logic
- Queue chunks locally when offline (SQLite cache)

#### D. UI Layer
**Purpose**: Display live transcripts and provide user controls
**Technology**: Jetpack Compose + ViewModel + Room Database

**Rationale**:
- Compose for modern, reactive UI
- ViewModel for lifecycle-aware state management
- Room for local transcript caching (offline access)

**Key Responsibilities**:
- Display real-time transcript stream
- Show recording status and network health
- Search historical transcripts
- Settings (recording quality, server config)
- Export transcripts (PDF, TXT, JSON)

---

### 3.2 Backend Server Components

#### A. WebSocket Handler
**Purpose**: Accept audio streams from multiple clients
**Technology**: FastAPI with WebSocket support, or Node.js with ws library

**Rationale**:
- FastAPI for Python ecosystem (easy Whisper integration)
- Async/await for handling concurrent connections
- Can scale to multiple clients simultaneously

**Key Responsibilities**:
- Authenticate client connections (JWT validation)
- Receive audio chunks via WebSocket
- Assign session ID and manage connection state
- Push chunks to transcription queue
- Send transcripts back to client in real-time

#### B. Audio Queue
**Purpose**: Decouple audio ingestion from transcription processing
**Technology**: Redis with Streams or RabbitMQ

**Rationale**:
- Transcription is CPU-intensive and slow
- Queue prevents backpressure from blocking WebSocket
- Enables horizontal scaling (multiple transcription workers)

**Key Responsibilities**:
- Buffer incoming audio chunks
- Implement priority queue (real-time vs. batch)
- Handle retries for failed transcriptions
- Track processing metrics

#### C. Transcription Engine
**Purpose**: Convert audio to text
**Technology**:
- Primary: OpenAI Whisper (whisper.cpp or faster-whisper)
- Alternative: Google Cloud Speech-to-Text, Assembly.AI
- GPU: CUDA-enabled PyTorch for Whisper (5-10x faster)

**Rationale**:
- Whisper is state-of-the-art, open-source, runs locally
- faster-whisper (CTranslate2) is 4x faster than base Whisper
- Supports multiple languages out of the box
- No per-minute API costs

**Key Responsibilities**:
- Load Whisper model (recommend `medium.en` for English)
- Process audio chunks to text
- Handle chunking artifacts (context carry-over)
- Timestamp alignment
- Speaker diarization (optional, with pyannote.audio)

#### D. REST API
**Purpose**: Provide CRUD operations for transcripts
**Technology**: FastAPI with Pydantic models

**Endpoints**:
```
POST   /auth/register          - Create user account
POST   /auth/login             - Get JWT token
GET    /transcripts            - List all transcripts (paginated)
GET    /transcripts/:id        - Get specific transcript
GET    /transcripts/search?q=  - Full-text search
DELETE /transcripts/:id        - Delete transcript
GET    /export/pdf/:id         - Export as PDF
```

**Key Responsibilities**:
- Authentication and authorization
- Transcript CRUD operations
- Search implementation (PostgreSQL full-text or Elasticsearch)
- Rate limiting
- API documentation (auto-generated by FastAPI)

#### E. Database
**Purpose**: Persistent storage for transcripts and metadata
**Technology**:
- Primary: PostgreSQL with full-text search
- Alternative: MongoDB (if unstructured data preferred)
- Cache: Redis for session state

**Schema Design**:
```sql
-- Users
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Recording Sessions
CREATE TABLE sessions (
    id UUID PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    started_at TIMESTAMP NOT NULL,
    ended_at TIMESTAMP,
    device_info JSONB,
    status VARCHAR(50) -- active, paused, completed
);

-- Transcripts
CREATE TABLE transcripts (
    id SERIAL PRIMARY KEY,
    session_id UUID REFERENCES sessions(id),
    audio_chunk_id INTEGER,
    text TEXT NOT NULL,
    confidence FLOAT,
    start_time TIMESTAMP NOT NULL,
    end_time TIMESTAMP NOT NULL,
    speaker_id INTEGER,
    language VARCHAR(10),
    created_at TIMESTAMP DEFAULT NOW()
);

-- Full-text search index
CREATE INDEX transcripts_text_idx ON transcripts USING GIN(to_tsvector('english', text));

-- Audio archive (optional)
CREATE TABLE audio_chunks (
    id SERIAL PRIMARY KEY,
    session_id UUID REFERENCES sessions(id),
    chunk_data BYTEA, -- or S3/MinIO reference
    duration_ms INTEGER,
    recorded_at TIMESTAMP NOT NULL
);
```

**Rationale**:
- PostgreSQL for ACID guarantees and powerful full-text search
- JSONB for flexible metadata storage
- Separate tables for sessions and transcripts (one session = many transcripts)
- Optional audio_chunks table for archival (can be offloaded to S3/MinIO)

---

## 4. Data Flow

### Real-Time Transcription Flow

```
1. Android App
   ├─▶ AudioRecord captures PCM samples (16kHz, 16-bit)
   ├─▶ Buffer accumulates 3-second chunks
   ├─▶ Opus compression (20KB → 6KB per chunk)
   └─▶ WebSocket.send(audio_chunk + metadata)

2. Backend Receives
   ├─▶ WebSocket handler validates JWT
   ├─▶ Extract audio chunk and metadata
   ├─▶ Push to Redis queue: {session_id, chunk_id, audio_data, timestamp}
   └─▶ Immediately return ACK to client

3. Transcription Worker
   ├─▶ Poll Redis queue for new chunks
   ├─▶ Decode Opus to PCM
   ├─▶ Whisper.transcribe(audio, language="en")
   ├─▶ Post-process: punctuation, capitalization
   └─▶ Insert into Postgres: INSERT INTO transcripts (...)

4. Backend Sends Back
   ├─▶ Retrieve transcript from database
   ├─▶ WebSocket.send({transcript_id, text, timestamp, confidence})
   └─▶ Client updates UI in real-time

5. Android App Displays
   ├─▶ Receive transcript via WebSocket
   ├─▶ Update Compose UI state
   ├─▶ Cache locally in Room database
   └─▶ Show in scrolling transcript view
```

**Latency Budget**:
- Audio capture: 0ms (continuous)
- Network transmission: 100-500ms (depends on connection)
- Queue processing: 50-200ms
- Whisper transcription: 1-3 seconds (for 3-sec chunk with GPU)
- Database write: 50ms
- UI update: 16ms (60fps)
- **Total**: ~2-5 seconds from speech to displayed text

---

## 5. Technology Stack Recommendations

### Android App

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| Language | Kotlin | Modern, concise, Android-native |
| UI | Jetpack Compose | Declarative, reactive, less boilerplate |
| Architecture | MVVM + Clean Architecture | Separation of concerns, testability |
| Audio | AudioRecord API | Low-level streaming access |
| Foreground Service | Android Service + Notification | Prevents process kill |
| Networking | OkHttp + WebSocket | Industry standard, reliable |
| HTTP Client | Retrofit | Type-safe REST API calls |
| Serialization | Kotlinx Serialization or Protobuf | Efficient binary format |
| Local DB | Room (SQLite wrapper) | Offline caching, type-safe queries |
| Dependency Injection | Hilt (Dagger) | Compile-time DI, Android-optimized |
| Async | Kotlin Coroutines + Flow | Structured concurrency, reactive streams |
| Audio Compression | Opus codec (via jni-opus) | Best quality/size ratio for voice |
| Voice Activity Detection | WebRTC VAD (via JNI) | Reduce silent period transmission |

**Key Libraries**:
```gradle
// build.gradle.kts
dependencies {
    // Compose
    implementation("androidx.compose.ui:ui:1.5.4")
    implementation("androidx.compose.material3:material3:1.1.2")

    // Networking
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.retrofit2:retrofit:2.9.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // Room
    implementation("androidx.room:room-runtime:2.6.0")
    kapt("androidx.room:room-compiler:2.6.0")

    // Hilt
    implementation("com.google.dagger:hilt-android:2.48")
    kapt("com.google.dagger:hilt-compiler:2.48")

    // WorkManager
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // Opus audio codec
    implementation("com.github.theeasiestway:opus-android:1.0.1")
}
```

### Backend Server

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| Language | Python 3.11+ | Best ecosystem for ML/AI |
| Framework | FastAPI | Async, fast, auto-documentation |
| WebSocket | FastAPI WebSocket or websockets lib | Native async support |
| Transcription | faster-whisper (CTranslate2) | 4x faster than base Whisper |
| Queue | Redis with Streams | Low latency, simple, persistent |
| Database | PostgreSQL 15+ | Full-text search, JSONB, reliability |
| ORM | SQLAlchemy 2.0 | Type hints, async support |
| Migrations | Alembic | Schema version control |
| Authentication | python-jose (JWT) | Stateless auth |
| Audio Processing | librosa, pydub | Audio manipulation |
| Deployment | Docker + Docker Compose | Reproducible, portable |
| Process Manager | Supervisor or systemd | Auto-restart workers |
| Reverse Proxy | Nginx or Caddy | TLS termination, load balancing |

**Key Python Packages**:
```python
# requirements.txt
fastapi==0.104.1
uvicorn[standard]==0.24.0
websockets==12.0
faster-whisper==0.10.0  # or openai-whisper==20231117
sqlalchemy==2.0.23
asyncpg==0.29.0  # PostgreSQL async driver
redis==5.0.1
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
pydantic==2.5.0
pydantic-settings==2.1.0
python-multipart==0.0.6
librosa==0.10.1
pydub==0.25.1
numpy==1.26.2
```

**Alternative: Node.js Backend** (if you prefer JavaScript)
```json
{
  "dependencies": {
    "fastify": "^4.25.1",
    "fastify-websocket": "^4.3.0",
    "@fastify/jwt": "^7.2.3",
    "pg": "^8.11.3",
    "ioredis": "^5.3.2",
    "whisper-node": "^1.0.0",  // Whisper.cpp bindings
    "prisma": "^5.7.0"  // ORM alternative
  }
}
```

---

## 6. Deployment Options

### Option A: Local Mini-PC / Home Server (Recommended for Privacy)

**Hardware Requirements**:
- CPU: 6+ cores (Intel i5/i7 or AMD Ryzen 5/7)
- RAM: 16GB minimum (32GB recommended)
- GPU: NVIDIA GPU with 6GB+ VRAM (e.g., RTX 3060) for fast Whisper
- Storage: 256GB SSD for OS + app, 1TB HDD for audio archive
- Network: Gigabit Ethernet, static IP or DDNS

**Setup**:
```bash
# Ubuntu 22.04 LTS
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Install NVIDIA Docker (for GPU acceleration)
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-docker.list
sudo apt-get update && sudo apt-get install -y nvidia-docker2
sudo systemctl restart docker

# Clone and run
git clone <your-repo>
cd voice-transcription-backend
docker-compose up -d
```

**Pros**:
- Complete data privacy (no third-party access)
- No recurring cloud costs
- Low latency (local network)
- One-time hardware investment

**Cons**:
- Upfront hardware cost ($800-$1500)
- Power consumption (~100-200W continuous)
- Need to manage network access (port forwarding, DDNS)
- No built-in redundancy

**Network Access**:
- Use Tailscale or WireGuard VPN for secure remote access
- Alternative: Cloudflare Tunnel (no port forwarding needed)

---

### Option B: Cloud VPS (e.g., DigitalOcean, Linode, Hetzner)

**Recommended Specs**:
- **CPU-Only**: 8 vCPU, 16GB RAM (~$80-120/month)
  - Hetzner CPX41: 8 vCPU, 16GB RAM, €34/month (~$37/month)
- **GPU-Enabled**:
  - Lambda Labs: 1x RTX A6000, $1.29/hour ($950/month if 24/7)
  - Vast.ai: Spot instances from $0.20/hour (~$150/month if on-demand)

**Setup**:
```bash
# One-click Docker droplet or manual setup
ssh root@your-vps-ip

# Same Docker setup as local
git clone <your-repo>
cd voice-transcription-backend

# Use docker-compose with environment variables
cp .env.example .env
nano .env  # Configure DB passwords, JWT secret, etc.

docker-compose -f docker-compose.prod.yml up -d
```

**Pros**:
- No hardware maintenance
- Built-in redundancy and backups
- Scalable on-demand
- Global accessibility

**Cons**:
- Monthly recurring costs
- Data leaves your premises (privacy concern)
- Higher latency vs. local
- GPU instances are expensive

**Cost Optimization**:
- Use CPU-only instance + faster-whisper (still ~2-3x real-time transcription)
- Batch transcription (delay non-critical transcripts to reduce GPU hours)
- Spot instances for 70% cost savings (with auto-restart logic)

---

### Option C: Hybrid (Local Primary + Cloud Backup)

**Architecture**:
- Primary: Local mini-PC for real-time transcription
- Backup: Cloud VPS with read-only replica (disaster recovery)
- Use PostgreSQL streaming replication

**Benefits**:
- Privacy of local + reliability of cloud
- Automatic failover if local server down
- Cloud instance can be smaller (no GPU needed)

---

### Docker Compose Example

```yaml
# docker-compose.yml
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_USER: voiceapp
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: transcripts
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    restart: unless-stopped

  backend:
    build: ./backend
    depends_on:
      - postgres
      - redis
    environment:
      DATABASE_URL: postgresql+asyncpg://voiceapp:${DB_PASSWORD}@postgres/transcripts
      REDIS_URL: redis://redis:6379
      JWT_SECRET: ${JWT_SECRET}
    ports:
      - "8000:8000"
    volumes:
      - ./backend:/app
      - whisper_models:/root/.cache/whisper
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    restart: unless-stopped

  transcription_worker:
    build: ./backend
    command: python worker.py
    depends_on:
      - postgres
      - redis
    environment:
      DATABASE_URL: postgresql+asyncpg://voiceapp:${DB_PASSWORD}@postgres/transcripts
      REDIS_URL: redis://redis:6379
      WHISPER_MODEL: medium.en
    volumes:
      - whisper_models:/root/.cache/whisper
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    restart: unless-stopped

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/ssl:/etc/nginx/ssl:ro
    depends_on:
      - backend
    restart: unless-stopped

volumes:
  postgres_data:
  redis_data:
  whisper_models:
```

---

## 7. Security & Privacy Considerations

### 7.1 Data Privacy

**Principles**:
- **Data Ownership**: User owns all audio and transcripts
- **No Third-Party**: No data sent to external APIs (self-hosted Whisper)
- **Encryption at Rest**: AES-256 encryption for database
- **Encryption in Transit**: TLS 1.3 for all client-server communication
- **Right to Delete**: Complete data deletion API

**Implementation**:
```python
# Encrypt transcripts at rest
from cryptography.fernet import Fernet

class EncryptedTranscript:
    def __init__(self, key: bytes):
        self.cipher = Fernet(key)

    def encrypt(self, text: str) -> bytes:
        return self.cipher.encrypt(text.encode())

    def decrypt(self, encrypted: bytes) -> str:
        return self.cipher.decrypt(encrypted).decode()
```

**Audio Retention Policy**:
- Option 1: Delete audio after transcription (save storage)
- Option 2: Keep audio for 30 days (re-transcription if model improves)
- Option 3: Encrypted archive to cold storage (compliance)

---

### 7.2 Authentication & Authorization

**JWT Token Flow**:
```
1. Client: POST /auth/login {email, password}
2. Server: Validate credentials → Generate JWT with 7-day expiry
3. Client: Store JWT in Android EncryptedSharedPreferences
4. Subsequent requests: Header "Authorization: Bearer <JWT>"
5. WebSocket: Send JWT in initial handshake message
6. Server: Validate JWT signature and expiry on every request
```

**Token Structure**:
```json
{
  "user_id": 123,
  "email": "user@example.com",
  "device_id": "android-abc123",
  "exp": 1704067200,
  "iat": 1703462400
}
```

**Best Practices**:
- Use RS256 (asymmetric) instead of HS256 for JWT signing
- Implement refresh tokens for long-lived sessions
- Rate limiting: 100 requests/min per user (FastAPI-Limiter)
- API key rotation every 90 days

---

### 7.3 Network Security

**TLS/SSL Configuration**:
```nginx
# nginx.conf
ssl_protocols TLSv1.3 TLSv1.2;
ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
ssl_prefer_server_ciphers on;
ssl_certificate /etc/nginx/ssl/fullchain.pem;
ssl_certificate_key /etc/nginx/ssl/privkey.pem;

# Use Let's Encrypt for free certificates
```

**Android Network Security Config**:
```xml
<!-- res/xml/network_security_config.xml -->
<network-security-config>
    <domain-config cleartextTrafficPermitted="false">
        <domain includeSubdomains="true">yourdomain.com</domain>
        <pin-set>
            <!-- Certificate pinning to prevent MITM -->
            <pin digest="SHA-256">base64-encoded-pin</pin>
        </pin-set>
    </domain-config>
</network-security-config>
```

---

### 7.4 Input Validation & Sanitization

**Server-Side Validation**:
```python
from pydantic import BaseModel, validator

class AudioChunk(BaseModel):
    session_id: str
    chunk_id: int
    audio_data: bytes
    timestamp: datetime

    @validator('audio_data')
    def validate_audio_size(cls, v):
        max_size = 1_000_000  # 1MB max per chunk
        if len(v) > max_size:
            raise ValueError(f"Audio chunk exceeds {max_size} bytes")
        return v

    @validator('chunk_id')
    def validate_sequence(cls, v):
        if v < 0 or v > 1_000_000:
            raise ValueError("Invalid chunk_id")
        return v
```

**SQL Injection Prevention**:
- Use SQLAlchemy ORM (parameterized queries)
- Never concatenate user input into raw SQL

---

## 8. Reliability & Reconnection Logic

### 8.1 Network Interruption Handling

**Android Client Strategy**:
```kotlin
class WebSocketManager {
    private var reconnectAttempts = 0
    private val maxReconnectAttempts = 10
    private val baseDelay = 1000L // 1 second

    fun handleDisconnection() {
        if (reconnectAttempts < maxReconnectAttempts) {
            val delay = baseDelay * (2.0.pow(reconnectAttempts)).toLong()
            delay(delay) // Exponential backoff
            reconnect()
            reconnectAttempts++
        } else {
            // Store chunks locally until manual reconnect
            switchToOfflineMode()
        }
    }

    private fun switchToOfflineMode() {
        // Queue audio chunks in Room database
        // Retry connection every 5 minutes in background
        // Notify user via notification
    }
}
```

**Offline Queue**:
- Store up to 1000 chunks (≈50 minutes of audio) in local SQLite
- When connection restored, batch upload queued chunks
- Server processes in order by timestamp

---

### 8.2 Server-Side Reliability

**Health Checks**:
```python
@app.get("/health")
async def health_check():
    checks = {
        "database": await check_db_connection(),
        "redis": await check_redis_connection(),
        "disk_space": check_disk_space() > 10_000_000_000,  # 10GB minimum
        "whisper_model": whisper_model is not None
    }

    if all(checks.values()):
        return {"status": "healthy", "checks": checks}
    else:
        raise HTTPException(status_code=503, detail=checks)
```

**Graceful Degradation**:
- If Whisper service down → queue chunks for later processing
- If database down → cache transcripts in Redis temporarily
- If Redis down → direct synchronous processing (slower)

**Circuit Breaker Pattern**:
```python
from circuitbreaker import circuit

@circuit(failure_threshold=5, recovery_timeout=60)
async def transcribe_audio(audio_data: bytes) -> str:
    # If fails 5 times in a row, circuit opens
    # Requests fail fast for 60 seconds (no retries)
    # After 60s, allows one test request to check if recovered
    result = await whisper_service.transcribe(audio_data)
    return result
```

---

### 8.3 Data Consistency

**Idempotency**:
```python
# Use chunk_id as idempotency key
async def process_audio_chunk(chunk: AudioChunk):
    existing = await db.get_transcript_by_chunk_id(chunk.chunk_id)
    if existing:
        return existing  # Already processed, return cached result

    # Process and store
    transcript = await transcribe(chunk.audio_data)
    await db.insert_transcript(chunk_id=chunk.chunk_id, text=transcript)
    return transcript
```

**Session Recovery**:
- Client sends session_id with every chunk
- If client crashes and restarts, resume same session
- Server tracks last received chunk_id per session
- Client can query: "What's the last chunk you received?" before sending new ones

---

## 9. Battery Optimization (Android)

### Strategies

1. **Adaptive Sample Rate**:
```kotlin
fun adjustSampleRate(voiceActivityLevel: Float): Int {
    return when {
        voiceActivityLevel > 0.8 -> 16000  // Active conversation
        voiceActivityLevel > 0.3 -> 8000   // Intermittent speech
        else -> 4000                        // Background/idle
    }
}
```

2. **Voice Activity Detection (VAD)**:
```kotlin
// Only transmit chunks with speech detected
val hasVoiceActivity = vadDetector.detect(audioBuffer)
if (hasVoiceActivity) {
    networkClient.send(audioBuffer)
} else {
    // Skip silent chunks (save 70% bandwidth + battery)
}
```

3. **Doze Mode Exemption** (Use sparingly):
```xml
<!-- Request permission in manifest -->
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
```

**Ask user explicitly**:
```kotlin
val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
    data = Uri.parse("package:$packageName")
}
startActivity(intent)
```

4. **Wi-Fi vs. Cellular**:
```kotlin
if (connectivityManager.isWifiConnected()) {
    uploadQuality = AudioQuality.HIGH  // 16kHz
} else {
    uploadQuality = AudioQuality.MEDIUM // 8kHz, save mobile data
}
```

---

## 10. Testing Strategy

### Android App Tests

```kotlin
// Unit Tests
class AudioChunkerTest {
    @Test
    fun `chunks audio into 3-second segments`() {
        val chunker = AudioChunker(chunkDurationMs = 3000)
        val input = generatePCMSamples(duration = 10_000) // 10 seconds
        val chunks = chunker.process(input)
        assertEquals(4, chunks.size) // 3s, 3s, 3s, 1s
    }
}

// Integration Tests
@HiltAndroidTest
class WebSocketClientTest {
    @Test
    fun `reconnects on network failure`() = runTest {
        val client = WebSocketClient(...)
        client.connect()
        simulateNetworkInterruption()
        delay(2000)
        assertTrue(client.isConnected())
    }
}

// UI Tests
@Test
fun testTranscriptDisplay() {
    composeTestRule.setContent {
        TranscriptScreen(viewModel = mockViewModel)
    }
    composeTestRule.onNodeWithText("Hello world").assertIsDisplayed()
}
```

### Backend Tests

```python
# Unit Tests
def test_transcription_accuracy():
    audio = load_test_audio("samples/hello.wav")
    result = transcribe(audio)
    assert "hello" in result.lower()
    assert result.confidence > 0.9

# Integration Tests
@pytest.mark.asyncio
async def test_websocket_audio_flow():
    async with AsyncClient(app=app, base_url="http://test") as ac:
        async with connect("ws://test/ws") as ws:
            await ws.send_bytes(test_audio_chunk)
            response = await ws.receive_json()
            assert "text" in response

# Load Tests
from locust import HttpUser, task, between

class TranscriptionUser(HttpUser):
    wait_time = between(1, 3)

    @task
    def upload_audio(self):
        self.client.post("/transcribe", files={"audio": test_file})
```

---

## 11. Monitoring & Observability

### Metrics to Track

**Application Metrics**:
- Transcription latency (p50, p95, p99)
- WebSocket connection count
- Audio chunk queue depth
- Transcription error rate
- API endpoint response times

**Infrastructure Metrics**:
- CPU usage (especially GPU utilization)
- Memory usage
- Disk I/O (database writes)
- Network bandwidth

**Tools**:
```yaml
# docker-compose.monitoring.yml
services:
  prometheus:
    image: prom/prometheus
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin

  node-exporter:
    image: prom/node-exporter
    ports:
      - "9100:9100"
```

**FastAPI Integration**:
```python
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI()
Instrumentator().instrument(app).expose(app)  # Exposes /metrics endpoint
```

---

## 12. Cost Estimates

### Local Deployment (One-Time)

| Item | Cost |
|------|------|
| Mini PC (Intel NUC 12 Pro) | $600 |
| RAM Upgrade (32GB) | $80 |
| SSD (1TB NVMe) | $60 |
| GPU (RTX 3060 12GB, used) | $250 |
| **Total Hardware** | **$990** |
| Electricity (200W @ $0.12/kWh, 24/7) | $17/month |

### Cloud Deployment (Monthly)

| Provider | Instance Type | Cost/Month |
|----------|---------------|------------|
| Hetzner | CPX41 (8 vCPU, 16GB) | $37 |
| DigitalOcean | 8 vCPU, 16GB RAM | $96 |
| Lambda Labs | 1x RTX A6000 (24/7) | $950 |
| Vast.ai | RTX 3090 (on-demand) | ~$200 |

**Break-Even**: Local setup pays for itself in ~11 months vs. basic cloud VPS

---

## 13. Development Roadmap

### Phase 1: MVP (4-6 weeks)
- [ ] Android app with basic audio recording
- [ ] Backend WebSocket server
- [ ] Whisper integration (CPU-only, slow)
- [ ] Basic transcript display
- [ ] Local SQLite storage (no user accounts)

### Phase 2: Core Features (4 weeks)
- [ ] User authentication (JWT)
- [ ] PostgreSQL database with full-text search
- [ ] Real-time WebSocket transcript streaming
- [ ] Offline mode and reconnection logic
- [ ] Background foreground service with notification

### Phase 3: Performance (3 weeks)
- [ ] GPU acceleration for Whisper
- [ ] Audio compression (Opus codec)
- [ ] Voice Activity Detection (VAD)
- [ ] Redis queue for horizontal scaling
- [ ] Chunking overlap and context carry-over

### Phase 4: Polish (3 weeks)
- [ ] Speaker diarization ("Speaker 1", "Speaker 2")
- [ ] Export features (PDF, TXT, JSON)
- [ ] Advanced search (date range, speaker filter)
- [ ] Settings UI (quality, language, server config)
- [ ] Battery optimization modes

### Phase 5: Production (2 weeks)
- [ ] Docker deployment
- [ ] TLS/SSL setup
- [ ] Monitoring and logging
- [ ] Backup and restore
- [ ] Documentation

**Total: ~16-18 weeks for full system**

---

## 14. Alternative Approaches

### Alternative 1: Use Existing Services

**Pros**: Faster development
**Cons**: Recurring costs, privacy concerns

| Service | Cost | Features |
|---------|------|----------|
| Assembly.AI | $0.65/hour | Real-time, speaker diarization |
| Deepgram | $0.0125/min ($0.75/hour) | Lowest latency |
| Google Cloud Speech | $0.024/min ($1.44/hour) | Multi-language |

**When to use**: Prototyping or if transcription volume < 50 hours/month

---

### Alternative 2: On-Device Transcription

**Technology**: Android Speech Recognizer or Mozilla DeepSpeech Lite

**Pros**:
- No network required
- Zero latency
- Complete privacy

**Cons**:
- Lower accuracy than Whisper
- Limited language support
- High battery drain (running ML on phone)

**When to use**: Offline-first use cases, extremely sensitive data

---

### Alternative 3: Hybrid Cloud

**Architecture**:
- Use cloud transcription API during beta/low usage
- Migrate to self-hosted once usage scales up
- Keep same API interface (easy swap)

```python
# Abstract interface
class TranscriptionService(Protocol):
    async def transcribe(self, audio: bytes) -> str: ...

class WhisperService(TranscriptionService):
    async def transcribe(self, audio: bytes) -> str:
        # Self-hosted Whisper
        ...

class AssemblyAIService(TranscriptionService):
    async def transcribe(self, audio: bytes) -> str:
        # Cloud API call
        ...

# Switch via config
transcription_service: TranscriptionService = (
    WhisperService() if config.USE_SELF_HOSTED else AssemblyAIService()
)
```

---

## 15. Future Enhancements

### Advanced Features (Post-MVP)

1. **Multi-Language Auto-Detection**
```python
detected_lang = whisper.detect_language(audio)
transcript = whisper.transcribe(audio, language=detected_lang)
```

2. **Sentiment Analysis**
```python
from transformers import pipeline
sentiment = pipeline("sentiment-analysis")
result = sentiment("This is terrible!") # {label: 'NEGATIVE', score: 0.98}
```

3. **Action Item Extraction**
```python
# Use GPT-4 or local Llama to extract tasks
prompt = f"Extract action items from: {transcript}"
action_items = llm.generate(prompt)
```

4. **Smart Summarization**
```python
from transformers import BartForConditionalGeneration
summarizer = BartForConditionalGeneration.from_pretrained("facebook/bart-large-cnn")
summary = summarizer.generate(long_transcript, max_length=150)
```

5. **Voice Commands**
```python
# Detect keywords to pause/resume recording
if "stop recording" in transcript.lower():
    recorder.pause()
```

6. **Integration with Calendar**
- Auto-detect meeting times from audio
- Create calendar events with transcript attached

7. **Wearable Support**
- Extend to Wear OS smartwatch
- Lower power consumption mode

---

## Conclusion

This design provides a **comprehensive, privacy-first, self-hosted voice recording and transcription system** that rivals commercial products like Limitless, but gives you complete control over your data.

**Key Decisions Summary**:
- **Android AudioRecord** for low-level streaming vs. MediaRecorder
- **WebSocket** for bi-directional real-time communication
- **faster-whisper** for optimal speed/accuracy balance
- **PostgreSQL** for full-text search and reliability
- **Docker** for portable, reproducible deployment
- **Local deployment** recommended for privacy and cost

**Next Steps**:
1. Review this design document
2. Choose deployment target (local vs. cloud)
3. Set up development environment
4. Start with Phase 1 MVP (basic recording + transcription)
5. Iterate based on real-world usage

---

**Document Version**: 1.0
**Last Updated**: 2025-11-09
**Author**: AI Architect Assistant
**License**: MIT (adapt as needed)

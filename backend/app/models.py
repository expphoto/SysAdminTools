"""
Pydantic models for request/response validation
"""

from pydantic import BaseModel, EmailStr, Field
from typing import Optional
from datetime import datetime


class UserCreate(BaseModel):
    """User registration request"""
    email: EmailStr
    password: str = Field(..., min_length=8)


class UserResponse(BaseModel):
    """User response"""
    id: int
    email: str
    created_at: datetime
    is_active: bool


class LoginRequest(BaseModel):
    """Login request"""
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    """JWT token response"""
    access_token: str
    token_type: str = "bearer"
    expires_in: int


class TranscriptResponse(BaseModel):
    """Transcript response"""
    id: str
    session_id: str
    text: str
    confidence: Optional[float]
    timestamp: str
    language: str


class SessionResponse(BaseModel):
    """Session response"""
    id: str
    started_at: datetime
    ended_at: Optional[datetime]
    status: str


class HealthResponse(BaseModel):
    """Health check response"""
    status: str
    database: bool
    whisper_model: bool

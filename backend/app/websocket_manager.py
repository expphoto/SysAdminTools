"""
WebSocket Connection Manager

Manages active WebSocket connections and message broadcasting
"""

from fastapi import WebSocket
from typing import Dict, Set
from loguru import logger


class WebSocketManager:
    """
    Manager for WebSocket connections

    Features:
    - Track active connections
    - Send messages to specific clients
    - Broadcast to all clients
    - Handle disconnections
    """

    def __init__(self):
        # Dictionary mapping client_id to WebSocket connection
        self.active_connections: Dict[str, WebSocket] = {}

        # Dictionary mapping session_id to set of client_ids
        # (for multi-device support - multiple clients in same session)
        self.session_clients: Dict[str, Set[str]] = {}

    async def connect(self, websocket: WebSocket, client_id: str):
        """
        Accept a new WebSocket connection
        """
        await websocket.accept()
        self.active_connections[client_id] = websocket
        logger.info(f"WebSocket connected: {client_id} (total: {len(self.active_connections)})")

    def disconnect(self, client_id: str):
        """
        Remove a WebSocket connection
        """
        if client_id in self.active_connections:
            del self.active_connections[client_id]
            logger.info(f"WebSocket disconnected: {client_id} (total: {len(self.active_connections)})")

        # Remove from session clients
        for session_id, clients in self.session_clients.items():
            if client_id in clients:
                clients.remove(client_id)

    async def send_to_client(self, client_id: str, message: dict):
        """
        Send a message to a specific client
        """
        if client_id in self.active_connections:
            try:
                await self.active_connections[client_id].send_json(message)
            except Exception as e:
                logger.error(f"Error sending to client {client_id}: {e}")
                self.disconnect(client_id)

    async def broadcast(self, message: dict):
        """
        Broadcast a message to all connected clients
        """
        disconnected_clients = []

        for client_id, websocket in self.active_connections.items():
            try:
                await websocket.send_json(message)
            except Exception as e:
                logger.error(f"Error broadcasting to {client_id}: {e}")
                disconnected_clients.append(client_id)

        # Clean up disconnected clients
        for client_id in disconnected_clients:
            self.disconnect(client_id)

    async def broadcast_to_session(self, session_id: str, message: dict):
        """
        Broadcast a message to all clients in a specific session
        """
        if session_id in self.session_clients:
            for client_id in self.session_clients[session_id]:
                await self.send_to_client(client_id, message)

    def register_session_client(self, session_id: str, client_id: str):
        """
        Register a client as part of a session
        """
        if session_id not in self.session_clients:
            self.session_clients[session_id] = set()

        self.session_clients[session_id].add(client_id)
        logger.debug(f"Client {client_id} registered to session {session_id}")

    def get_active_count(self) -> int:
        """
        Get number of active connections
        """
        return len(self.active_connections)

    def get_session_client_count(self, session_id: str) -> int:
        """
        Get number of clients in a session
        """
        if session_id in self.session_clients:
            return len(self.session_clients[session_id])
        return 0

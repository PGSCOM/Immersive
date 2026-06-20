#!/usr/bin/env python3
"""Immersive-2 WebSocket Signaling Server for multi-user shared VR workspaces.

Manages rooms, user presence, pose relay, screen sharing state, and
WebRTC signaling (P2P mesh for 1-2 users, SFU for 3+).
"""

from __future__ import annotations

import asyncio
import json
import logging
import secrets
import signal
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set

import websockets
from websockets.server import WebSocketServerProtocol

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 19810
MAX_USERS_PER_ROOM = 8
P2P_MAX_USERS = 2  # Threshold: <=2 = P2P mesh, >2 = SFU

# ---------------------------------------------------------------------------
# Logging setup (no PII — only user_ids, not display names or IPs)
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("signaling")


# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------

@dataclass
class User:
    ws: WebSocketServerProtocol
    user_id: int
    display_name: str
    room_id: str


@dataclass
class Room:
    room_id: str
    users: Dict[int, User] = field(default_factory=dict)
    next_user_id: int = 1

    @property
    def user_count(self) -> int:
        return len(self.users)

    @property
    def is_p2p(self) -> bool:
        return self.user_count <= P2P_MAX_USERS

    def add_user(self, ws: WebSocketServerProtocol, display_name: str) -> int:
        user_id = self.next_user_id
        self.next_user_id += 1
        self.users[user_id] = User(ws, user_id, display_name, self.room_id)
        return user_id

    def remove_user(self, user_id: int) -> Optional[User]:
        return self.users.pop(user_id, None)

    def get_user(self, user_id: int) -> Optional[User]:
        return self.users.get(user_id)

    def get_other_users(self, user_id: int) -> List[User]:
        return [u for u in self.users.values() if u.user_id != user_id]


# ---------------------------------------------------------------------------
# Server state
# ---------------------------------------------------------------------------

class SignalingServer:
    def __init__(self) -> None:
        self.rooms: Dict[str, Room] = {}
        self._shutdown_event = asyncio.Event()

    # -----------------------------------------------------------------------
    # Room management
    # -----------------------------------------------------------------------

    def get_or_create_room(self, room_id: str) -> Room:
        if room_id not in self.rooms:
            self.rooms[room_id] = Room(room_id)
            logger.info("Room created: room_id=%s", room_id)
        return self.rooms[room_id]

    def destroy_room_if_empty(self, room_id: str) -> None:
        room = self.rooms.get(room_id)
        if room and room.user_count == 0:
            del self.rooms[room_id]
            logger.info("Room destroyed: room_id=%s", room_id)

    # -----------------------------------------------------------------------
    # Message helpers
    # -----------------------------------------------------------------------

    @staticmethod
    def _build_msg(msg_type: str, **kwargs) -> str:
        return json.dumps({"type": msg_type, **kwargs})

    async def _send(self, ws: WebSocketServerProtocol, msg: str) -> None:
        try:
            await ws.send(msg)
        except websockets.exceptions.ConnectionClosed:
            pass

    async def _broadcast(self, room: Room, msg: str, exclude: Optional[int] = None) -> None:
        for user in room.users.values():
            if exclude is None or user.user_id != exclude:
                await self._send(user.ws, msg)

    # -----------------------------------------------------------------------
    # Handlers
    # -----------------------------------------------------------------------

    async def handle_room_join(self, ws: WebSocketServerProtocol, payload: dict) -> None:
        room_id = payload.get("room_id", "default")
        display_name = payload.get("display_name", "Anonymous")

        room = self.get_or_create_room(room_id)

        if room.user_count >= MAX_USERS_PER_ROOM:
            await self._send(ws, self._build_msg("error", code="ROOM_FULL"))
            return

        user_id = room.add_user(ws, display_name)
        ws.user_id = user_id  # type: ignore[attr-defined]
        ws.room_id = room_id  # type: ignore[attr-defined]

        logger.info("User joined: user_id=%d room_id=%s", user_id, room_id)

        # Build participant list
        participants = [
            {"user_id": u.user_id, "display_name": u.display_name}
            for u in room.users.values()
        ]

        # Send ROOM_JOINED to the new user
        await self._send(
            ws,
            self._build_msg(
                "room_joined",
                room_id=room_id,
                user_id=user_id,
                participants=participants,
                mode="p2p" if room.is_p2p else "sfu",
            ),
        )

        # Broadcast USER_PRESENCE to others
        await self._broadcast(
            room,
            self._build_msg(
                "user_presence",
                user_id=user_id,
                display_name=display_name,
                is_online=True,
            ),
            exclude=user_id,
        )

        # If we crossed the threshold into SFU mode, notify everyone
        if not room.is_p2p and room.user_count == P2P_MAX_USERS + 1:
            logger.info("Room transitioned to SFU mode: room_id=%s", room_id)
            await self._broadcast(
                room,
                self._build_msg("topology_changed", mode="sfu"),
            )

    async def handle_room_leave(self, ws: WebSocketServerProtocol) -> None:
        user_id = getattr(ws, "user_id", None)
        room_id = getattr(ws, "room_id", None)
        if user_id is None or room_id is None:
            return

        room = self.rooms.get(room_id)
        if not room:
            return

        user = room.remove_user(user_id)
        if not user:
            return

        logger.info("User left: user_id=%d room_id=%s", user_id, room_id)

        # Notify others
        await self._broadcast(
            room,
            self._build_msg("room_left", user_id=user_id),
            exclude=user_id,
        )

        # If we dropped back to P2P mode, notify everyone
        if room.is_p2p and room.user_count == P2P_MAX_USERS:
            logger.info("Room transitioned to P2P mode: room_id=%s", room_id)
            await self._broadcast(
                room,
                self._build_msg("topology_changed", mode="p2p"),
            )

        self.destroy_room_if_empty(room_id)

    async def handle_user_pose(self, ws: WebSocketServerProtocol, payload: dict) -> None:
        user_id = getattr(ws, "user_id", None)
        room_id = getattr(ws, "room_id", None)
        if user_id is None or room_id is None:
            return

        room = self.rooms.get(room_id)
        if not room:
            return

        # Broadcast pose to all other users in the room
        await self._broadcast(
            room,
            self._build_msg(
                "user_pose",
                user_id=user_id,
                head=payload.get("head"),
                left_hand=payload.get("left_hand"),
                right_hand=payload.get("right_hand"),
            ),
            exclude=user_id,
        )

    async def handle_screen_share_state(self, ws: WebSocketServerProtocol, payload: dict) -> None:
        user_id = getattr(ws, "user_id", None)
        room_id = getattr(ws, "room_id", None)
        if user_id is None or room_id is None:
            return

        room = self.rooms.get(room_id)
        if not room:
            return

        await self._broadcast(
            room,
            self._build_msg(
                "screen_share_state",
                user_id=user_id,
                monitor_count=payload.get("monitor_count", 0),
                monitor_ids=payload.get("monitor_ids", []),
                enabled=payload.get("enabled", False),
            ),
            exclude=user_id,
        )

    async def handle_monitor_layout_update(self, ws: WebSocketServerProtocol, payload: dict) -> None:
        user_id = getattr(ws, "user_id", None)
        room_id = getattr(ws, "room_id", None)
        if user_id is None or room_id is None:
            return

        room = self.rooms.get(room_id)
        if not room:
            return

        await self._broadcast(
            room,
            self._build_msg(
                "remote_screen_layout",
                user_id=user_id,
                monitor_count=payload.get("monitor_count", 0),
                monitors=payload.get("monitors", []),
            ),
            exclude=user_id,
        )

    async def handle_webrtc_signal(self, ws: WebSocketServerProtocol, msg_type: str, payload: dict) -> None:
        """Relay WebRTC offer/answer/ice_candidate to target user."""
        user_id = getattr(ws, "user_id", None)
        room_id = getattr(ws, "room_id", None)
        target_user_id = payload.get("target_user_id")

        if user_id is None or room_id is None or target_user_id is None:
            return

        room = self.rooms.get(room_id)
        if not room:
            return

        target_user = room.get_user(target_user_id)
        if not target_user:
            return

        msg = self._build_msg(
            msg_type,
            from_user_id=user_id,
            sdp=payload.get("sdp"),
            candidate=payload.get("candidate"),
            target_user_id=target_user_id,
        )
        await self._send(target_user.ws, msg)

    # -----------------------------------------------------------------------
    # WebSocket handler
    # -----------------------------------------------------------------------

    async def handle_client(self, ws: WebSocketServerProtocol, path: str) -> None:
        logger.info("Client connected")
        try:
            async for message in ws:
                try:
                    data = json.loads(message)
                except json.JSONDecodeError:
                    await self._send(ws, self._build_msg("error", code="INVALID_JSON"))
                    continue

                msg_type = data.get("type")
                payload = data.get("payload", {})

                if msg_type == "room_join":
                    await self.handle_room_join(ws, payload)
                elif msg_type == "user_pose":
                    await self.handle_user_pose(ws, payload)
                elif msg_type == "screen_share_state":
                    await self.handle_screen_share_state(ws, payload)
                elif msg_type == "monitor_layout_update":
                    await self.handle_monitor_layout_update(ws, payload)
                elif msg_type in ("webrtc_offer", "webrtc_answer", "ice_candidate"):
                    await self.handle_webrtc_signal(ws, msg_type, payload)
                else:
                    logger.warning("Unknown message type: %s", msg_type)

        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            await self.handle_room_leave(ws)

    # -----------------------------------------------------------------------
    # Lifecycle
    # -----------------------------------------------------------------------

    async def run(self, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT) -> None:
        stop = asyncio.Future()  # type: ignore[var-annotated]

        async with websockets.serve(self.handle_client, host, port):
            logger.info("Signaling server started on ws://%s:%d", host, port)
            await stop


def main() -> None:
    server = SignalingServer()

    # Handle graceful shutdown
    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, lambda: asyncio.create_task(server._shutdown_event.set()))

    try:
        asyncio.run(server.run())
    except KeyboardInterrupt:
        logger.info("Shutting down...")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Immersive-2 WebSocket Signaling Server.

Manages rooms, user presence, pose relay, whiteboard sync, voice relay, and
WebRTC signaling.  Network topology switches automatically:
  ≤2 users → P2P mesh (direct WebRTC data channels, server only carries signals)
  3+ users → SFU relay (server fans out pose + voice data to every participant)

Free deployment — no credit card required
=========================================
Render.com free tier (render.com):
  - 750 instance-hours/month (one always-on service fits easily)
  - Active WebSocket connections keep the instance awake; the service
    only spins down after 15 min of *complete* inactivity (no connections)
  - Bandwidth: 100 GB/month — more than enough for lightweight JSON signaling
  - Deploy: connect your GitHub repo → Build: pip install -r requirements.txt
             Start: python server.py   (Render injects PORT automatically)

Environment variables
---------------------
PORT              WebSocket port (default 19810; Render sets this automatically)
HOST              Bind address (default 0.0.0.0)
MAX_USERS_PER_ROOM  Max simultaneous users per room (default 8)
LOG_LEVEL         Logging verbosity: DEBUG | INFO | WARNING (default INFO)

Privacy
-------
Logs contain only ephemeral integer user_ids and opaque room_id strings.
No IP addresses, display names, or message contents are ever logged.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
import sys
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

import websockets

# ---------------------------------------------------------------------------
# Configuration — all tunable via environment variables
# ---------------------------------------------------------------------------

DEFAULT_HOST: str = os.environ.get("HOST", "0.0.0.0")
DEFAULT_PORT: int = int(os.environ.get("PORT", "19810"))
MAX_USERS_PER_ROOM: int = int(os.environ.get("MAX_USERS_PER_ROOM", "8"))
P2P_MAX_USERS: int = 2  # rooms with ≤ this many users use P2P WebRTC

# WebSocket keep-alive — detects and removes stale connections (e.g. headset
# powered off without a clean disconnect) within PING_INTERVAL + PING_TIMEOUT s.
PING_INTERVAL: int = 25
PING_TIMEOUT: int = 10

# ---------------------------------------------------------------------------
# Logging — no PII
# ---------------------------------------------------------------------------

_log_level = getattr(logging, os.environ.get("LOG_LEVEL", "INFO").upper(), logging.INFO)
logging.basicConfig(
	level=_log_level,
	format="%(asctime)s [%(levelname)s] %(message)s",
	datefmt="%Y-%m-%d %H:%M:%S",
	stream=sys.stdout,  # Render captures stdout for log streaming
)
logger = logging.getLogger("signaling")


# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------

@dataclass
class User:
	ws: Any
	user_id: int
	display_name: str
	room_id: str


@dataclass
class Room:
	room_id: str
	users: Dict[int, User] = field(default_factory=dict)
	next_user_id: int = 1
	## True when this room appears in the public lobby listing.
	public: bool = False

	@property
	def user_count(self) -> int:
		return len(self.users)

	@property
	def is_p2p(self) -> bool:
		return self.user_count <= P2P_MAX_USERS

	def add_user(self, ws: Any, display_name: str) -> int:
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
# Server
# ---------------------------------------------------------------------------

class SignalingServer:
	def __init__(self) -> None:
		self.rooms: Dict[str, Room] = {}
		self._active_connections: int = 0
		## All currently open WebSocket connections (used to push lobby updates).
		self._connections: set = set()

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
	def _build_msg(msg_type: str, **kwargs: Any) -> str:
		return json.dumps({"type": msg_type, **kwargs})

	async def _send(self, ws: Any, msg: str) -> None:
		try:
			await ws.send(msg)
		except (websockets.exceptions.ConnectionClosed, RuntimeError):
			pass

	async def _broadcast(self, room: Room, msg: str, exclude: Optional[int] = None) -> None:
		for user in list(room.users.values()):
			if exclude is None or user.user_id != exclude:
				await self._send(user.ws, msg)

	# -----------------------------------------------------------------------
	# Message handlers
	# -----------------------------------------------------------------------

	async def handle_lobby_list(self, ws: Any) -> None:
		"""Send the current list of public rooms to the requesting client."""
		await self._send(ws, self._build_msg("lobby_rooms", rooms=self._public_rooms_list()))

	def _public_rooms_list(self) -> List[Dict[str, Any]]:
		"""Return serialisable info for every public room that has at least one user."""
		return [
			{"room_id": r.room_id, "user_count": r.user_count}
			for r in self.rooms.values()
			if r.public and r.user_count > 0
		]

	async def _push_lobby_update(self) -> None:
		"""Push a lobby_update to every connected client that is not in any room.

		These are the 'lobby watchers' — clients that have connected to the
		signaling server but have not yet joined a room, so they are browsing
		the public lobby list."""
		msg = self._build_msg("lobby_update", rooms=self._public_rooms_list())
		for ws in list(self._connections):
			if getattr(ws, "room_id", None) is None:
				await self._send(ws, msg)

	async def handle_room_join(self, ws: Any, payload: dict) -> None:
		room_id = payload.get("room_id", "default")
		display_name = payload.get("display_name", "Anonymous")

		room = self.get_or_create_room(room_id)

		# Mark a newly created room as public only at creation time; joining an
		# existing room never changes its visibility (the creator decides).
		if room.user_count == 0:
			room.public = bool(payload.get("public", False))

		if room.user_count >= MAX_USERS_PER_ROOM:
			await self._send(ws, self._build_msg("error", code="ROOM_FULL"))
			return

		user_id = room.add_user(ws, display_name)
		ws.user_id = user_id  # type: ignore[attr-defined]
		ws.room_id = room_id  # type: ignore[attr-defined]

		logger.info("User joined: user_id=%d room_id=%s users_now=%d", user_id, room_id, room.user_count)

		participants = [
			{"user_id": u.user_id, "display_name": u.display_name}
			for u in room.users.values()
		]

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

		await self._broadcast(
			room,
			self._build_msg("user_presence", user_id=user_id, display_name=display_name, is_online=True),
			exclude=user_id,
		)

		if not room.is_p2p and room.user_count == P2P_MAX_USERS + 1:
			logger.info("Room → SFU mode: room_id=%s users=%d", room_id, room.user_count)
			await self._broadcast(room, self._build_msg("topology_changed", mode="sfu"))

		# Notify lobby watchers whenever a public room's occupancy changes.
		if room.public:
			await self._push_lobby_update()

	async def handle_room_leave(self, ws: Any) -> None:
		user_id = getattr(ws, "user_id", None)
		room_id = getattr(ws, "room_id", None)
		if user_id is None or room_id is None:
			return

		room = self.rooms.get(room_id)
		if not room:
			return

		was_public = room.public
		user = room.remove_user(user_id)
		if not user:
			return

		logger.info("User left: user_id=%d room_id=%s users_now=%d", user_id, room_id, room.user_count)

		await self._broadcast(room, self._build_msg("room_left", user_id=user_id), exclude=user_id)

		if room.is_p2p and room.user_count == P2P_MAX_USERS:
			logger.info("Room → P2P mode: room_id=%s users=%d", room_id, room.user_count)
			await self._broadcast(room, self._build_msg("topology_changed", mode="p2p"))

		self.destroy_room_if_empty(room_id)

		# Notify lobby watchers that a public room's occupancy changed (or disappeared).
		if was_public:
			await self._push_lobby_update()

	async def handle_user_pose(self, ws: Any, payload: dict) -> None:
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
				"user_pose",
				user_id=user_id,
				head=payload.get("head"),
				left_hand=payload.get("left_hand"),
				right_hand=payload.get("right_hand"),
			),
			exclude=user_id,
		)

	async def handle_screen_share_state(self, ws: Any, payload: dict) -> None:
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

	async def handle_monitor_layout_update(self, ws: Any, payload: dict) -> None:
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

	async def handle_whiteboard(self, ws: Any, msg_type: str, payload: dict) -> None:
		user_id = getattr(ws, "user_id", None)
		room_id = getattr(ws, "room_id", None)
		if user_id is None or room_id is None:
			return
		room = self.rooms.get(room_id)
		if not room:
			return
		if msg_type == "whiteboard_stroke":
			await self._broadcast(
				room,
				self._build_msg("whiteboard_stroke", user_id=user_id, stroke=payload.get("stroke")),
				exclude=user_id,
			)
		else:
			await self._broadcast(room, self._build_msg("whiteboard_clear", user_id=user_id), exclude=user_id)

	async def handle_voice_frame(self, ws: Any, payload: dict) -> None:
		"""Relay an opaque voice frame (base64 PCM) to the rest of the room.

		Used only in SFU mode (3+ users); 1-2 user rooms carry voice over the
		direct P2P WebRTC channel and never reach here. The audio payload is
		forwarded verbatim and never logged or stored (privacy: §4)."""
		user_id = getattr(ws, "user_id", None)
		room_id = getattr(ws, "room_id", None)
		if user_id is None or room_id is None:
			return
		room = self.rooms.get(room_id)
		if not room:
			return
		audio = payload.get("audio")
		if not audio:
			return
		await self._broadcast(
			room,
			self._build_msg("voice_frame", from_user_id=user_id, audio=audio),
			exclude=user_id,
		)

	async def handle_webrtc_signal(self, ws: Any, msg_type: str, payload: dict) -> None:
		user_id = getattr(ws, "user_id", None)
		room_id = getattr(ws, "room_id", None)
		target_user_id = payload.get("target_user_id")
		if user_id is None or room_id is None or target_user_id is None:
			return
		room = self.rooms.get(room_id)
		if not room:
			return
		target = room.get_user(target_user_id)
		if not target:
			return
		await self._send(
			target.ws,
			self._build_msg(
				msg_type,
				from_user_id=user_id,
				sdp=payload.get("sdp"),
				candidate=payload.get("candidate"),
				target_user_id=target_user_id,
			),
		)

	# -----------------------------------------------------------------------
	# Connection handler
	# -----------------------------------------------------------------------

	async def handle_client(self, ws: Any) -> None:
		self._active_connections += 1
		self._connections.add(ws)
		logger.debug("Client connected (active=%d)", self._active_connections)
		try:
			async for message in ws:
				try:
					data = json.loads(message)
				except json.JSONDecodeError:
					await self._send(ws, self._build_msg("error", code="INVALID_JSON"))
					continue

				msg_type: str = data.get("type", "")
				payload: dict = data.get("payload", {})

				if msg_type == "room_join":
					await self.handle_room_join(ws, payload)
				elif msg_type == "lobby_list":
					await self.handle_lobby_list(ws)
				elif msg_type == "user_pose":
					await self.handle_user_pose(ws, payload)
				elif msg_type == "screen_share_state":
					await self.handle_screen_share_state(ws, payload)
				elif msg_type == "monitor_layout_update":
					await self.handle_monitor_layout_update(ws, payload)
				elif msg_type in ("whiteboard_stroke", "whiteboard_clear"):
					await self.handle_whiteboard(ws, msg_type, payload)
				elif msg_type == "voice_frame":
					await self.handle_voice_frame(ws, payload)
				elif msg_type in ("webrtc_offer", "webrtc_answer", "ice_candidate"):
					await self.handle_webrtc_signal(ws, msg_type, payload)
				else:
					logger.warning("Unknown message type: %s", msg_type)

		except websockets.exceptions.ConnectionClosed:
			pass
		finally:
			await self.handle_room_leave(ws)
			self._connections.discard(ws)
			self._active_connections -= 1
			logger.debug("Client disconnected (active=%d)", self._active_connections)

	# -----------------------------------------------------------------------
	# Lifecycle
	# -----------------------------------------------------------------------

	async def run(self, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT) -> None:
		loop = asyncio.get_running_loop()
		stop: asyncio.Future = loop.create_future()

		def _set_stop() -> None:
			if not stop.done():
				stop.set_result(None)

		# Graceful shutdown on SIGINT (Ctrl-C) and SIGTERM (Render stop signal).
		# add_signal_handler is Unix-only; on Windows we fall back to signal.signal()
		# which is safe to call from the main thread (tests run everything in-process).
		try:
			for sig in (signal.SIGINT, signal.SIGTERM):
				loop.add_signal_handler(sig, _set_stop)
		except NotImplementedError:
			for sig in (signal.SIGINT, signal.SIGTERM):
				signal.signal(sig, lambda *_: loop.call_soon_threadsafe(_set_stop))

		async with websockets.serve(
			self.handle_client,
			host,
			port,
			ping_interval=PING_INTERVAL,
			ping_timeout=PING_TIMEOUT,
		):
			logger.info(
				"Signaling server ready  ws://%s:%d  (P2P <= %d users, SFU > %d, max %d/room)",
				host, port, P2P_MAX_USERS, P2P_MAX_USERS, MAX_USERS_PER_ROOM,
			)
			await stop

		logger.info("Signaling server stopped cleanly")


def main() -> None:
	server = SignalingServer()
	try:
		asyncio.run(server.run())
	except KeyboardInterrupt:
		pass


if __name__ == "__main__":
	main()

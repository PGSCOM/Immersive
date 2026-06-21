#!/usr/bin/env python3
"""Integration tests for the Immersive-2 signaling server.

Tests room join/leave, presence broadcast, pose relay, screen sharing,
and topology transitions (P2P <-> SFU).
"""

import asyncio
import json
import sys
import unittest
from typing import Any, Dict, List, Optional

import websockets

# Ensure the server module is importable
sys.path.insert(0, "..")
from server import SignalingServer, DEFAULT_HOST, DEFAULT_PORT, P2P_MAX_USERS


TEST_PORT = DEFAULT_PORT + 1000  # Avoid conflicts with a running server


class SignalingTestCase(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.server = SignalingServer()
        self.server_task = asyncio.create_task(self.server.run(DEFAULT_HOST, TEST_PORT))
        # Give the server a moment to start
        await asyncio.sleep(0.1)

    async def asyncTearDown(self) -> None:
        self.server_task.cancel()
        try:
            await self.server_task
        except asyncio.CancelledError:
            pass

    async def _connect(self) -> websockets.WebSocketClientProtocol:
        uri = f"ws://127.0.0.1:{TEST_PORT}"
        return await websockets.connect(uri)

    async def _send(self, ws: websockets.WebSocketClientProtocol, msg_type: str, payload: Dict[str, Any]) -> None:
        await ws.send(json.dumps({"type": msg_type, "payload": payload}))

    async def _recv(self, ws: websockets.WebSocketClientProtocol, timeout: float = 2.0) -> Dict[str, Any]:
        raw = await asyncio.wait_for(ws.recv(), timeout=timeout)
        return json.loads(raw)  # type: ignore[no-any-return]

    async def _recv_until(self, ws: websockets.WebSocketClientProtocol, msg_type: str,
                          timeout: float = 2.0) -> Dict[str, Any]:
        """Read (and discard) messages until one of `msg_type` arrives."""
        while True:
            msg = await self._recv(ws, timeout)
            if msg.get("type") == msg_type:
                return msg

    # -----------------------------------------------------------------------
    # Tests
    # -----------------------------------------------------------------------

    async def test_room_join_and_presence(self) -> None:
        """Two peers join a room; verify room_joined and user_presence."""
        ws1 = await self._connect()
        ws2 = await self._connect()

        # Peer 1 joins
        await self._send(ws1, "room_join", {"room_id": "test-room", "display_name": "Alice"})
        msg1 = await self._recv(ws1)
        self.assertEqual(msg1["type"], "room_joined")
        self.assertEqual(msg1["room_id"], "test-room")
        self.assertEqual(msg1["mode"], "p2p")
        user_id_1 = msg1["user_id"]

        # Peer 2 joins
        await self._send(ws2, "room_join", {"room_id": "test-room", "display_name": "Bob"})
        msg2 = await self._recv(ws2)
        self.assertEqual(msg2["type"], "room_joined")
        self.assertEqual(msg2["mode"], "p2p")
        user_id_2 = msg2["user_id"]

        # Peer 1 should receive user_presence for Peer 2
        presence = await self._recv(ws1)
        self.assertEqual(presence["type"], "user_presence")
        self.assertEqual(presence["user_id"], user_id_2)
        self.assertEqual(presence["display_name"], "Bob")
        self.assertTrue(presence["is_online"])

        await ws1.close()
        await ws2.close()

    async def test_room_leave(self) -> None:
        """Peer leaves; verify room_left broadcast."""
        ws1 = await self._connect()
        ws2 = await self._connect()

        await self._send(ws1, "room_join", {"room_id": "leave-room", "display_name": "Alice"})
        await self._recv(ws1)

        await self._send(ws2, "room_join", {"room_id": "leave-room", "display_name": "Bob"})
        await self._recv(ws2)
        await self._recv(ws1)  # consume presence

        # Peer 2 leaves
        await ws2.close()

        # Peer 1 should receive room_left
        msg = await self._recv(ws1)
        self.assertEqual(msg["type"], "room_left")

        await ws1.close()

    async def test_topology_transition_to_sfu(self) -> None:
        """3 peers join; verify transition to SFU mode."""
        ws1 = await self._connect()
        ws2 = await self._connect()
        ws3 = await self._connect()

        await self._send(ws1, "room_join", {"room_id": "sfu-room", "display_name": "Alice"})
        await self._recv(ws1)

        await self._send(ws2, "room_join", {"room_id": "sfu-room", "display_name": "Bob"})
        await self._recv(ws2)
        await self._recv(ws1)

        # Third peer triggers SFU
        await self._send(ws3, "room_join", {"room_id": "sfu-room", "display_name": "Carol"})
        await self._recv(ws3)

        # ws1 and ws2 receive user_presence for Carol first
        await self._recv(ws1)
        await self._recv(ws2)

        # Everyone should get topology_changed
        for ws in (ws1, ws2, ws3):
            msg = await self._recv(ws)
            self.assertEqual(msg["type"], "topology_changed")
            self.assertEqual(msg["mode"], "sfu")

        await ws1.close()
        await ws2.close()
        await ws3.close()

    async def test_topology_transition_back_to_p2p(self) -> None:
        """3 peers (SFU) drop to 2; verify seamless migration back to P2P."""
        ws1 = await self._connect()
        ws2 = await self._connect()
        ws3 = await self._connect()

        await self._send(ws1, "room_join", {"room_id": "p2p-back", "display_name": "Alice"})
        await self._recv(ws1)
        await self._send(ws2, "room_join", {"room_id": "p2p-back", "display_name": "Bob"})
        await self._recv(ws2)
        await self._send(ws3, "room_join", {"room_id": "p2p-back", "display_name": "Carol"})
        await self._recv(ws3)

        # Drain until both remaining peers have seen the SFU transition.
        sfu1 = await self._recv_until(ws1, "topology_changed")
        sfu2 = await self._recv_until(ws2, "topology_changed")
        self.assertEqual(sfu1["mode"], "sfu")
        self.assertEqual(sfu2["mode"], "sfu")

        # Carol leaves → room drops to 2 → back to P2P for everyone remaining.
        await ws3.close()
        p2p1 = await self._recv_until(ws1, "topology_changed")
        p2p2 = await self._recv_until(ws2, "topology_changed")
        self.assertEqual(p2p1["mode"], "p2p")
        self.assertEqual(p2p2["mode"], "p2p")

        await ws1.close()
        await ws2.close()

    async def test_pose_relay(self) -> None:
        """Peer sends pose; verify relay to others."""
        ws1 = await self._connect()
        ws2 = await self._connect()

        await self._send(ws1, "room_join", {"room_id": "pose-room", "display_name": "Alice"})
        await self._recv(ws1)

        await self._send(ws2, "room_join", {"room_id": "pose-room", "display_name": "Bob"})
        await self._recv(ws2)
        await self._recv(ws1)

        # Peer 1 sends pose
        pose = {
            "head": {"pos": [0, 1.6, 0], "rot": [1, 0, 0, 0]},
            "left_hand": {"pos": [-0.3, 1.2, 0.5], "rot": [1, 0, 0, 0]},
            "right_hand": {"pos": [0.3, 1.2, 0.5], "rot": [1, 0, 0, 0]},
        }
        await self._send(ws1, "user_pose", pose)

        # Peer 2 should receive the pose
        msg = await self._recv(ws2)
        self.assertEqual(msg["type"], "user_pose")
        self.assertEqual(msg["user_id"], 1)
        self.assertIn("head", msg)

        await ws1.close()
        await ws2.close()

    async def test_screen_share_state(self) -> None:
        """Peer updates screen share state; verify broadcast."""
        ws1 = await self._connect()
        ws2 = await self._connect()

        await self._send(ws1, "room_join", {"room_id": "share-room", "display_name": "Alice"})
        await self._recv(ws1)

        await self._send(ws2, "room_join", {"room_id": "share-room", "display_name": "Bob"})
        await self._recv(ws2)
        await self._recv(ws1)

        await self._send(ws1, "screen_share_state", {
            "monitor_count": 2,
            "monitor_ids": [1, 2],
            "enabled": True,
        })

        msg = await self._recv(ws2)
        self.assertEqual(msg["type"], "screen_share_state")
        self.assertEqual(msg["user_id"], 1)
        self.assertEqual(msg["monitor_count"], 2)
        self.assertTrue(msg["enabled"])

        await ws1.close()
        await ws2.close()

    async def test_whiteboard_relay(self) -> None:
        """A user draws / clears the whiteboard; verify relay to others in the room."""
        ws1 = await self._connect()
        ws2 = await self._connect()
        await self._send(ws1, "room_join", {"room_id": "wb", "display_name": "A"})
        await self._recv(ws1)
        await self._send(ws2, "room_join", {"room_id": "wb", "display_name": "B"})
        await self._recv(ws2)
        await self._recv(ws1)  # presence for B

        stroke = {"user_id": 1, "color": [0.0, 0.0, 0.0], "points": [0.1, 0.1, 0.9, 0.9]}
        await self._send(ws1, "whiteboard_stroke", {"stroke": stroke})
        msg = await self._recv_until(ws2, "whiteboard_stroke")
        self.assertEqual(msg["user_id"], 1)
        self.assertEqual(msg["stroke"]["points"], [0.1, 0.1, 0.9, 0.9])

        await self._send(ws1, "whiteboard_clear", {})
        msg2 = await self._recv_until(ws2, "whiteboard_clear")
        self.assertEqual(msg2["user_id"], 1)

        await ws1.close()
        await ws2.close()

    async def test_voice_relay(self) -> None:
        """A user sends a voice frame; verify it is relayed to others in the room."""
        ws1 = await self._connect()
        ws2 = await self._connect()
        await self._send(ws1, "room_join", {"room_id": "voice", "display_name": "A"})
        await self._recv(ws1)
        await self._send(ws2, "room_join", {"room_id": "voice", "display_name": "B"})
        await self._recv(ws2)
        await self._recv(ws1)  # presence for B

        await self._send(ws1, "voice_frame", {"audio": "QUJDRA=="})  # opaque base64
        msg = await self._recv_until(ws2, "voice_frame")
        self.assertEqual(msg["from_user_id"], 1)
        self.assertEqual(msg["audio"], "QUJDRA==")

        # The sender must not receive its own voice back.
        await self._send(ws2, "voice_frame", {"audio": "WFlaWg=="})
        echo = await self._recv_until(ws1, "voice_frame")
        self.assertEqual(echo["from_user_id"], 2)

        await ws1.close()
        await ws2.close()

    async def test_voice_frame_without_audio_is_ignored(self) -> None:
        """A voice_frame with no audio payload must not be relayed."""
        ws1 = await self._connect()
        ws2 = await self._connect()
        await self._send(ws1, "room_join", {"room_id": "voice-empty", "display_name": "A"})
        await self._recv(ws1)
        await self._send(ws2, "room_join", {"room_id": "voice-empty", "display_name": "B"})
        await self._recv(ws2)
        await self._recv(ws1)  # presence for B

        await self._send(ws1, "voice_frame", {})  # no audio key → dropped
        # Followed by a real pose, which should be the next thing ws2 sees.
        await self._send(ws1, "user_pose", {"head": {}, "left_hand": {}, "right_hand": {}})
        msg = await self._recv(ws2)
        self.assertEqual(msg["type"], "user_pose")

        await ws1.close()
        await ws2.close()

    async def test_webrtc_signal_relay(self) -> None:
        """Peer sends WebRTC offer; verify relay to target."""
        ws1 = await self._connect()
        ws2 = await self._connect()

        await self._send(ws1, "room_join", {"room_id": "webrtc-room", "display_name": "Alice"})
        msg1 = await self._recv(ws1)

        await self._send(ws2, "room_join", {"room_id": "webrtc-room", "display_name": "Bob"})
        await self._recv(ws2)
        await self._recv(ws1)

        # Peer 1 sends offer to Peer 2
        await self._send(ws1, "webrtc_offer", {
            "target_user_id": msg1["user_id"] + 1,
            "sdp": "v=0\n...",
        })

        msg = await self._recv(ws2)
        self.assertEqual(msg["type"], "webrtc_offer")
        self.assertEqual(msg["from_user_id"], msg1["user_id"])

        await ws1.close()
        await ws2.close()

    # -----------------------------------------------------------------------
    # Lobby tests
    # -----------------------------------------------------------------------

    async def test_lobby_list_empty(self) -> None:
        """lobby_list with no public rooms returns an empty list."""
        ws = await self._connect()
        await self._send(ws, "lobby_list", {})
        msg = await self._recv(ws)
        self.assertEqual(msg["type"], "lobby_rooms")
        self.assertEqual(msg["rooms"], [])
        await ws.close()

    async def test_public_room_appears_in_lobby(self) -> None:
        """A room created with public=True shows up in lobby_rooms."""
        ws1 = await self._connect()
        ws2 = await self._connect()

        await self._send(ws1, "room_join", {"room_id": "pub-alpha", "display_name": "Alice", "public": True})
        await self._recv(ws1)  # room_joined

        # ws2 may have already received a lobby_update push when ws1 joined;
        # use _recv_until so that push doesn't shadow the lobby_rooms response.
        await self._send(ws2, "lobby_list", {})
        msg = await self._recv_until(ws2, "lobby_rooms")
        self.assertEqual(msg["type"], "lobby_rooms")
        rooms = msg["rooms"]
        self.assertEqual(len(rooms), 1)
        self.assertEqual(rooms[0]["room_id"], "pub-alpha")
        self.assertEqual(rooms[0]["user_count"], 1)

        await ws1.close()
        await ws2.close()

    async def test_private_room_not_in_lobby(self) -> None:
        """A room created without public=True does not appear in lobby_rooms."""
        ws1 = await self._connect()
        ws2 = await self._connect()

        await self._send(ws1, "room_join", {"room_id": "priv-beta", "display_name": "Alice"})
        await self._recv(ws1)

        await self._send(ws2, "lobby_list", {})
        msg = await self._recv(ws2)
        self.assertEqual(msg["type"], "lobby_rooms")
        self.assertEqual(msg["rooms"], [])

        await ws1.close()
        await ws2.close()

    async def test_lobby_update_pushed_to_watcher(self) -> None:
        """Creating a public room pushes lobby_update to clients not yet in a room."""
        ws_watcher = await self._connect()   # never joins a room
        ws_joiner  = await self._connect()

        await self._send(ws_joiner, "room_join",
                         {"room_id": "pub-watch", "display_name": "Alice", "public": True})
        await self._recv(ws_joiner)  # room_joined

        # The watcher should receive a lobby_update automatically.
        msg = await self._recv(ws_watcher)
        self.assertEqual(msg["type"], "lobby_update")
        rooms = msg["rooms"]
        self.assertEqual(len(rooms), 1)
        self.assertEqual(rooms[0]["room_id"], "pub-watch")

        await ws_joiner.close()
        await ws_watcher.close()

    async def test_lobby_update_on_public_room_empty(self) -> None:
        """When the last user leaves a public room it is removed from lobby_update."""
        ws_watcher = await self._connect()
        ws_joiner  = await self._connect()

        await self._send(ws_joiner, "room_join",
                         {"room_id": "pub-gone", "display_name": "Alice", "public": True})
        await self._recv(ws_joiner)
        await self._recv(ws_watcher)   # consume lobby_update for join

        # Joiner leaves; watcher should get another lobby_update with empty rooms.
        await ws_joiner.close()
        msg = await self._recv(ws_watcher)
        self.assertEqual(msg["type"], "lobby_update")
        self.assertEqual(msg["rooms"], [])

        await ws_watcher.close()


if __name__ == "__main__":
    unittest.main()

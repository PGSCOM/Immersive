#!/usr/bin/env python3
"""SFU relay server for Immersive-2 — handles 3+ user rooms.

When a room crosses the P2P_MAX_USERS threshold the signaling server broadcasts
topology_changed(mode="sfu") and clients route pose updates through the server
relay instead of direct WebRTC data channels.

NOTE: Godot's WebRTCPeerConnection supports only data channels, not media
tracks.  Video streams continue to flow via the existing host TCP/UDP protocol
(port 19801/19802).  Only pose/avatar data and signaling travel through here.

This module re-uses SignalingServer from server.py (all relay logic already
lives there) and exposes it on a dedicated SFU port so it can run as a
separate process if desired.  In a single-machine deployment both can share
the same SignalingServer instance.
"""

from __future__ import annotations

import asyncio
import logging

from server import SignalingServer, DEFAULT_HOST, P2P_MAX_USERS  # noqa: F401

logger = logging.getLogger("sfu_relay")

SFU_PORT = 19811  # dedicated port; signaling default is 19810


class SFURelayServer(SignalingServer):
    """Signaling server configured for 3+ user SFU relay mode.

    Inherits all of SignalingServer's WebSocket signaling and pose relay.
    The topology threshold (P2P_MAX_USERS) drives automatic switching: when a
    room grows past it, topology_changed(mode="sfu") is broadcast and the
    server takes over pose fan-out.  Video frames are never routed here.
    """


async def _main() -> None:
    server = SFURelayServer()
    logger.info(
        "SFU relay server starting on ws://%s:%d (P2P threshold = %d users)",
        DEFAULT_HOST, SFU_PORT, P2P_MAX_USERS,
    )
    await server.run(host=DEFAULT_HOST, port=SFU_PORT)


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )
    asyncio.run(_main())

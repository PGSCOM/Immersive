#!/usr/bin/env python3
"""SFU relay entry point for Immersive-2.

Inherits all logic from server.py; just runs on a separate port so it can
coexist with the base signaling server in a single-machine deployment.

In practice a single `python server.py` handles both P2P and SFU topology
automatically (it switches based on room size).  Run this only when you
want an isolated SFU-only process on port 19811.

All env vars from server.py (PORT, HOST, MAX_USERS_PER_ROOM, LOG_LEVEL)
are honoured; PORT defaults to 19811 here instead of 19810.
"""

from __future__ import annotations

import asyncio
import logging
import os

from server import SignalingServer, DEFAULT_HOST, P2P_MAX_USERS  # noqa: F401

logger = logging.getLogger("sfu_relay")

SFU_PORT: int = int(os.environ.get("PORT", "19811"))


class SFURelayServer(SignalingServer):
	"""SignalingServer pre-configured for explicit SFU relay deployments."""


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

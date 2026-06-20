#!/usr/bin/env python3
"""SFU (Selective Forwarding Unit) server for Immersive-2 multi-user rooms.

Receives media streams from all participants and forwards selectively.
Routes encrypted SRTP packets only (no decryption).
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Dict, List, Optional

from aiortc import RTCPeerConnection, RTCSessionDescription
from aiortc.contrib.signaling import object_from_string, object_to_string

logger = logging.getLogger("sfu")

class SFUPeer:
    """Represents a peer in the SFU."""
    def __init__(self, user_id: int, pc: RTCPeerConnection) -> None:
        self.user_id = user_id
        self.pc = pc
        self.tracks: List = []

class SFUServer:
    """Selective Forwarding Unit for 3+ users."""
    
    def __init__(self) -> None:
        self.peers: Dict[int, SFUPeer] = {}
        self._shutdown_event = asyncio.Event()
    
    async def add_peer(self, user_id: int, offer_sdp: str) -> str:
        """Add a new peer to the SFU. Returns the answer SDP."""
        pc = RTCPeerConnection()
        peer = SFUPeer(user_id, pc)
        self.peers[user_id] = peer
        
        # Set remote description (offer)
        offer = RTCSessionDescription(sdp=offer_sdp, type="offer")
        await pc.setRemoteDescription(offer)
        
        # Create answer
        answer = await pc.createAnswer()
        await pc.setLocalDescription(answer)
        
        logger.info("Peer %d added to SFU", user_id)
        return pc.localDescription.sdp
    
    async def remove_peer(self, user_id: int) -> None:
        """Remove a peer from the SFU."""
        if user_id in self.peers:
            peer = self.peers.pop(user_id)
            await peer.pc.close()
            logger.info("Peer %d removed from SFU", user_id)
    
    async def forward_tracks(self, user_id: int) -> None:
        """Forward tracks from a peer to all other peers."""
        if user_id not in self.peers:
            return
        
        peer = self.peers[user_id]
        for other_id, other_peer in self.peers.items():
            if other_id != user_id:
                for track in peer.tracks:
                    other_peer.pc.addTrack(track)
        
        logger.info("Tracks from peer %d forwarded to %d peers", user_id, len(self.peers) - 1)
    
    async def run(self) -> None:
        """Main SFU loop."""
        logger.info("SFU server started")
        await self._shutdown_event.wait()
    
    def shutdown(self) -> None:
        self._shutdown_event.set()

async def main() -> None:
    sfu = SFUServer()
    try:
        await sfu.run()
    except KeyboardInterrupt:
        logger.info("SFU shutting down...")

if __name__ == "__main__":
    asyncio.run(main())

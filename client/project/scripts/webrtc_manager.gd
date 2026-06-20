## WebRTC manager for P2P mesh media connections.
## Manages WebRTCPeerConnection instances for multi-user rooms.

extends Node

# --- Signals ---

signal peer_connected(user_id: int)
signal peer_disconnected(user_id: int)
signal data_channel_message(user_id: int, data: String)
signal track_received(user_id: int, track_type: String)

# --- State ---

## Map of user_id -> WebRTCPeerConnection
var _peers: Dictionary = {}

## Signaling client reference
var _signaling: Node = null

## Local user ID
var _local_user_id: int = -1

## Whether this peer is the offerer (true) or answerer (false)
var _is_offerer: bool = false

func initialize(signaling_client: Node, local_user_id: int, is_offerer: bool = false) -> void:
    _signaling = signaling_client
    _local_user_id = local_user_id
    _is_offerer = is_offerer

## Create a new peer connection for a remote user.
func create_peer(user_id: int) -> WebRTCPeerConnection:
    if _peers.has(user_id):
        return _peers[user_id]
    
    var peer := WebRTCPeerConnection.new()
    peer.initialize({
        "iceServers": [
            {"urls": ["stun:stun.l.google.com:19302"]}
        ]
    })
    
    peer.session_description_created.connect(_on_session_description_created.bind(user_id))
    peer.ice_candidate_created.connect(_on_ice_candidate_created.bind(user_id))
    peer.data_channel_received.connect(_on_data_channel_received.bind(user_id))
    
    _peers[user_id] = peer
    
    # Create data channel for pose updates
    if _is_offerer:
        var channel := peer.create_data_channel("pose", {"id": 1, "negotiated": true})
        channel.message_received.connect(_on_data_channel_message.bind(user_id))
    
    return peer

## Start connection as offerer.
func create_offer(user_id: int) -> void:
    var peer := create_peer(user_id)
    peer.create_offer()

## Handle incoming offer/answer from signaling.
func set_remote_description(user_id: int, type: String, sdp: String) -> void:
    var peer := create_peer(user_id)
    peer.set_remote_description(type, sdp)
    
    if type == "offer":
        peer.create_answer()

## Add ICE candidate.
func add_ice_candidate(user_id: int, media: String, index: int, name: String) -> void:
    var peer := create_peer(user_id)
    peer.add_ice_candidate(media, index, name)

## Close a peer connection.
func close_peer(user_id: int) -> void:
    if _peers.has(user_id):
        _peers[user_id].close()
        _peers.erase(user_id)
        peer_disconnected.emit(user_id)

## Close all peer connections.
func close_all() -> void:
    for user_id in _peers.keys():
        close_peer(user_id)

# --- Internal handlers ---

func _on_session_description_created(type: String, sdp: String, user_id: int) -> void:
    var peer: WebRTCPeerConnection = _peers[user_id]
    peer.set_local_description(type, sdp)
    
    # Send to remote peer via signaling
    if _signaling and _signaling.has_method("send_webrtc_offer"):
        if type == "offer":
            _signaling.send_webrtc_offer(user_id, sdp)
        elif type == "answer":
            _signaling.send_webrtc_answer(user_id, sdp)

func _on_ice_candidate_created(media: String, index: int, name: String, user_id: int) -> void:
    if _signaling and _signaling.has_method("send_ice_candidate"):
        _signaling.send_ice_candidate(user_id, "%s|%d|%s" % [media, index, name])

func _on_data_channel_received(channel: WebRTCDataChannel, user_id: int) -> void:
    channel.message_received.connect(_on_data_channel_message.bind(user_id))

func _on_data_channel_message(message: String, user_id: int) -> void:
    data_channel_message.emit(user_id, message)

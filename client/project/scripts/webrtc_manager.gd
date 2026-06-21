## WebRTC manager for P2P mesh media/data connections (Immersive-2 multi-user).
##
## Per AGENTS.md §6 the topology is server-driven: 1-2 users use a direct P2P mesh
## (this manager), 3+ users fall back to the SFU relay (poses go through the
## signaling server instead). Here we establish one WebRTCPeerConnection per remote
## user with a negotiated "pose" data channel, relay SDP/ICE through the injected
## signaling client, and expose broadcast_pose() so the multiuser manager can send
## pose over the low-latency P2P channel when it is open.

extends Node
class_name WebRTCManager

# --- Signals ---

signal peer_connected(user_id: int)
signal peer_disconnected(user_id: int)
## A pose (or other JSON) payload arrived over a peer's data channel.
signal pose_received(user_id: int, payload: String)
## A binary voice frame arrived over a peer's voice data channel.
signal voice_received(user_id: int, frame: PackedByteArray)

# --- State ---

## user_id -> WebRTCPeerConnection
var _peers: Dictionary = {}
## user_id -> WebRTCDataChannel ("pose", negotiated id 1)
var _channels: Dictionary = {}
## user_id -> WebRTCDataChannel ("voice", negotiated id 2, unreliable/unordered)
var _voice_channels: Dictionary = {}

## Injected signaling client (duck-typed: send_webrtc_offer/answer/ice_candidate).
var _signaling: Node = null
var _local_user_id: int = -1
var _is_offerer: bool = false

## STUN configuration (overridable for tests / self-hosted TURN).
var ice_servers: Array = [{"urls": ["stun:stun.l.google.com:19302"]}]

func initialize(signaling_client: Node, local_user_id: int, is_offerer: bool = false) -> void:
	_signaling = signaling_client
	_local_user_id = local_user_id
	_is_offerer = is_offerer

## Create (or fetch) a peer connection + negotiated data channel for a remote user.
func create_peer(user_id: int) -> WebRTCPeerConnection:
	if _peers.has(user_id):
		return _peers[user_id]

	var peer := WebRTCPeerConnection.new()
	peer.initialize({"iceServers": ice_servers})
	peer.session_description_created.connect(_on_session_description_created.bind(user_id))
	peer.ice_candidate_created.connect(_on_ice_candidate_created.bind(user_id))
	_peers[user_id] = peer

	# A negotiated channel (same id on both ends) needs no data_channel_received
	# round-trip, so both offerer and answerer create it symmetrically.
	var channel := peer.create_data_channel("pose", {"id": 1, "negotiated": true})
	if channel:
		channel.message_received.connect(_on_data_channel_message.bind(user_id))
		_channels[user_id] = channel

	# Voice rides a separate negotiated channel (id 2). Audio favours freshness
	# over completeness, so it is unordered with a short packet lifetime — a late
	# voice frame is worse than a dropped one.
	var voice := peer.create_data_channel("voice",
		{"id": 2, "negotiated": true, "ordered": false, "maxPacketLifeTime": 100})
	if voice:
		voice.message_received.connect(_on_voice_channel_message.bind(user_id))
		_voice_channels[user_id] = voice

	return peer

## Begin a connection to `user_id` as the offerer.
func create_offer(user_id: int) -> void:
	var peer := create_peer(user_id)
	peer.create_offer()

## Apply a remote SDP (and answer if it was an offer).
func set_remote_description(user_id: int, type: String, sdp: String) -> void:
	var peer := create_peer(user_id)
	peer.set_remote_description(type, sdp)
	if type == "offer":
		peer.create_answer()

## Handle an ICE candidate string of the form "media|index|name" from signaling.
func handle_ice_candidate(user_id: int, candidate_str: String) -> void:
	var parsed := parse_ice_candidate(candidate_str)
	if not parsed.get("valid", false):
		return
	var peer := create_peer(user_id)
	peer.add_ice_candidate(parsed["media"], int(parsed["index"]), parsed["name"])

## Parse the "media|index|name" wire form. Returns { valid, media, index, name }.
static func parse_ice_candidate(candidate_str: String) -> Dictionary:
	var parts := candidate_str.split("|", true, 2)
	if parts.size() != 3:
		return {"valid": false}
	if not parts[1].is_valid_int():
		return {"valid": false}
	return {"valid": true, "media": parts[0], "index": int(parts[1]), "name": parts[2]}

## Send a pose/JSON payload over every OPEN data channel. Returns the number of
## peers it was sent to (0 = no live P2P link, caller should use the SFU relay).
func broadcast_pose(payload: String) -> int:
	var sent := 0
	for user_id in _channels:
		var channel: WebRTCDataChannel = _channels[user_id]
		if channel and channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			channel.put_packet(payload.to_utf8_buffer())
			sent += 1
	return sent

## Send a binary voice frame over every OPEN voice channel. Returns the number of
## peers it reached (0 = no live P2P voice link, caller should use the SFU relay).
func broadcast_voice(frame: PackedByteArray) -> int:
	var sent := 0
	for user_id in _voice_channels:
		var channel: WebRTCDataChannel = _voice_channels[user_id]
		if channel and channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			channel.put_packet(frame)
			sent += 1
	return sent

## Number of peers whose data channel is currently open.
func open_channel_count() -> int:
	var n := 0
	for user_id in _channels:
		var channel: WebRTCDataChannel = _channels[user_id]
		if channel and channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			n += 1
	return n

## Drive the ICE/connection state machines — call each frame while in P2P mode.
func poll() -> void:
	for user_id in _peers:
		var peer: WebRTCPeerConnection = _peers[user_id]
		if peer:
			peer.poll()

func close_peer(user_id: int) -> void:
	if _channels.has(user_id):
		_channels.erase(user_id)
	if _voice_channels.has(user_id):
		_voice_channels.erase(user_id)
	if _peers.has(user_id):
		_peers[user_id].close()
		_peers.erase(user_id)
		peer_disconnected.emit(user_id)

func close_all() -> void:
	for user_id in _peers.keys():
		close_peer(user_id)

func peer_count() -> int:
	return _peers.size()

## In SFU mode the server relays poses, so the P2P mesh is torn down. On a return
## to P2P the caller re-creates offers.
func on_topology_changed(mode: String) -> void:
	if mode == "sfu":
		close_all()

# --- Internal handlers ---

func _on_session_description_created(type: String, sdp: String, user_id: int) -> void:
	if not _peers.has(user_id):
		return
	_peers[user_id].set_local_description(type, sdp)
	if _signaling == null:
		return
	if type == "offer" and _signaling.has_method("send_webrtc_offer"):
		_signaling.send_webrtc_offer(user_id, sdp)
	elif type == "answer" and _signaling.has_method("send_webrtc_answer"):
		_signaling.send_webrtc_answer(user_id, sdp)

func _on_ice_candidate_created(media: String, index: int, name: String, user_id: int) -> void:
	if _signaling and _signaling.has_method("send_ice_candidate"):
		_signaling.send_ice_candidate(user_id, "%s|%d|%s" % [media, index, name])

func _on_data_channel_message(message: PackedByteArray, user_id: int) -> void:
	pose_received.emit(user_id, message.get_string_from_utf8())

func _on_voice_channel_message(message: PackedByteArray, user_id: int) -> void:
	voice_received.emit(user_id, message)

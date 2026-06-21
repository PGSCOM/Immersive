## Multi-user session orchestrator for the VR client (Immersive-2 telepresence).
##
## Wires the signaling client and the WebRTC mesh together and exposes a small,
## scene-agnostic surface that main.gd drives:
##   • join()/leave() a room,
##   • broadcast_pose() — routed P2P in a 1-2 user mesh, via the SFU relay for 3+,
##   • signals (remote_pose / remote_presence / room state / topology) that main.gd
##     turns into RemoteUser avatars.
##
## Topology follows AGENTS.md §6 (locked): ≤2 users = P2P mesh, 3+ = SFU relay,
## with seamless migration driven by the server's topology_changed events. The
## dependency injection in setup() keeps the routing logic unit-testable with mock
## signaling / WebRTC objects (no live sockets needed).

extends Node
class_name MultiuserManager

# --- Signals consumed by main.gd ---
signal remote_pose(user_id: int, head: Dictionary, left_hand: Dictionary, right_hand: Dictionary)
signal remote_presence(user_id: int, display_name: String, is_online: bool)
signal room_state(room_id: String, local_user_id: int, mode: String)
signal user_left(user_id: int)
signal mode_changed(mode: String)
signal remote_whiteboard_stroke(user_id: int, stroke: Dictionary)
signal remote_whiteboard_clear(user_id: int)
signal remote_voice(user_id: int, frame: PackedByteArray)
## A remote user toggled screen sharing (which monitors they expose, on/off).
signal remote_screen_share(user_id: int, monitor_count: int, monitor_ids: Array, enabled: bool)
## A remote user's shared-screen layout (where their shared panels sit in the room).
signal remote_screen_layout(user_id: int, monitors: Array)
## Re-emitted from the signaling client on lobby_rooms / lobby_update responses.
signal lobby_rooms_received(rooms: Array)
## A remote user's MJPEG video frame for one of their shared monitors.
## Routed from the P2P video channel (2-user mesh) or the SFU relay (3+ users).
signal remote_video_frame(user_id: int, monitor_id: int, frame_data: PackedByteArray)

## Mirrors signaling/server.py P2P_MAX_USERS (the locked topology threshold).
const P2P_MAX_USERS := 2

var _signaling: Node = null
var _webrtc: Node = null
var _mode: String = "p2p"
var _local_user_id: int = -1
var _room_id: String = ""
## user_id -> display_name (remote participants only).
var _participants: Dictionary = {}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

## Inject the signaling client and (optional) WebRTC manager and wire their
## signals. Both are duck-typed so tests can pass lightweight mocks.
func setup(signaling: Node, webrtc: Node = null) -> void:
	_signaling = signaling
	_webrtc = webrtc

	if signaling:
		_connect_if(signaling, "room_joined", _on_room_joined)
		_connect_if(signaling, "room_left", _on_room_left)
		_connect_if(signaling, "user_presence", _on_user_presence)
		_connect_if(signaling, "user_pose_received", _on_relay_pose)
		_connect_if(signaling, "topology_changed", _on_topology_changed)
		_connect_if(signaling, "webrtc_offer_received", _on_webrtc_offer)
		_connect_if(signaling, "webrtc_answer_received", _on_webrtc_answer)
		_connect_if(signaling, "ice_candidate_received", _on_ice_candidate)
		_connect_if(signaling, "whiteboard_stroke_received", _on_whiteboard_stroke)
		_connect_if(signaling, "whiteboard_clear_received", _on_whiteboard_clear)
		_connect_if(signaling, "voice_frame_received", _on_relay_voice)
		_connect_if(signaling, "screen_share_state", _on_screen_share_state)
		_connect_if(signaling, "remote_screen_layout", _on_remote_screen_layout)
		_connect_if(signaling, "lobby_rooms_received", _on_lobby_rooms)
		_connect_if(signaling, "video_frame_received", _on_relay_video)

	if webrtc:
		if webrtc.has_method("initialize"):
			webrtc.initialize(signaling, _local_user_id)
		_connect_if(webrtc, "pose_received", _on_p2p_pose)
		_connect_if(webrtc, "voice_received", _on_p2p_voice)
		_connect_if(webrtc, "video_frame_received", _on_p2p_video)

func _connect_if(obj: Object, sig: String, callable: Callable) -> void:
	if obj.has_signal(sig) and not obj.is_connected(sig, callable):
		obj.connect(sig, callable)

## Connect to a signaling server and join a room.
## Pass public=true to make the room visible in the public lobby listing.
func join(url: String, room_id: String, display_name: String, public: bool = false) -> void:
	if _signaling == null:
		return
	if _signaling.has_method("connect_to_signaling"):
		_signaling.connect_to_signaling(url)
	if _signaling.has_signal("connected_to_signaling"):
		await _signaling.connected_to_signaling
	if _signaling.has_method("send_room_join"):
		_signaling.send_room_join(room_id, display_name, public)

## Request the public lobby list from the signaling server.
## The server replies with lobby_rooms_received (and pushes lobby_update on changes).
func request_lobby() -> void:
	if _signaling and _signaling.has_method("send_lobby_list"):
		_signaling.send_lobby_list()

## Leave the room and drop all peer connections.
func leave() -> void:
	if _webrtc and _webrtc.has_method("close_all"):
		_webrtc.close_all()
	if _signaling and _signaling.has_method("disconnect_from_signaling"):
		_signaling.disconnect_from_signaling()
	_participants.clear()
	_local_user_id = -1

# ---------------------------------------------------------------------------
# Pose transport (topology-aware)
# ---------------------------------------------------------------------------

## Send the local pose to the room. In a P2P mesh it goes over the low-latency
## WebRTC data channel when one is open; otherwise (or in SFU mode) it goes through
## the signaling relay. Returns the path used: "p2p", "sfu", or "none".
func broadcast_pose(head: Dictionary, left_hand: Dictionary, right_hand: Dictionary) -> String:
	if _mode == "p2p" and _webrtc and _webrtc.has_method("broadcast_pose"):
		var payload := JSON.stringify({"head": head, "left": left_hand, "right": right_hand})
		if int(_webrtc.broadcast_pose(payload)) > 0:
			return "p2p"
	if _signaling and _signaling.has_method("send_user_pose"):
		_signaling.send_user_pose(head, left_hand, right_hand)
		return "sfu"
	return "none"

## Send an encoded voice frame to the room. Mirrors broadcast_pose: it rides the
## low-latency P2P voice channel in a 1-2 user mesh when one is open, otherwise
## (or in SFU mode) it goes through the signaling relay. Returns "p2p", "sfu" or
## "none".
func broadcast_voice(frame: PackedByteArray) -> String:
	if frame.is_empty():
		return "none"
	if _mode == "p2p" and _webrtc and _webrtc.has_method("broadcast_voice"):
		if int(_webrtc.broadcast_voice(frame)) > 0:
			return "p2p"
	if _signaling and _signaling.has_method("send_voice_frame"):
		_signaling.send_voice_frame(frame)
		return "sfu"
	return "none"

## Send an MJPEG frame for a shared monitor to the room. Uses the P2P WebRTC
## video channel when peers are connected (1-2 user mesh), otherwise falls back
## to the SFU signaling relay (3+ users). Returns "p2p", "sfu", or "none".
func broadcast_video(monitor_id: int, frame_data: PackedByteArray) -> String:
	if frame_data.is_empty():
		return "none"
	if _mode == "p2p" and _webrtc and _webrtc.has_method("broadcast_video"):
		if int(_webrtc.broadcast_video(monitor_id, frame_data)) > 0:
			return "p2p"
	if _signaling and _signaling.has_method("send_video_frame"):
		_signaling.send_video_frame(monitor_id, frame_data)
		return "sfu"
	return "none"

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

func get_mode() -> String:
	return _mode

func get_local_user_id() -> int:
	return _local_user_id

func get_participant_count() -> int:
	return _participants.size()

func is_offerer_for(user_id: int) -> bool:
	# Deterministic glare avoidance: the lower user_id is always the offerer.
	return _local_user_id >= 0 and _local_user_id < user_id

# ---------------------------------------------------------------------------
# Signaling callbacks
# ---------------------------------------------------------------------------

func _on_room_joined(room_id: String, user_id: int, participants: Array) -> void:
	_room_id = room_id
	_local_user_id = user_id
	_mode = "p2p" if participants.size() <= P2P_MAX_USERS else "sfu"
	if _webrtc and _webrtc.has_method("initialize"):
		_webrtc.initialize(_signaling, _local_user_id)

	for p in participants:
		var pid: int = int(p.get("user_id", 0))
		if pid == _local_user_id:
			continue
		var pname := String(p.get("display_name", ""))
		_participants[pid] = pname
		_maybe_offer(pid)
		# Surface already-present users so the scene spawns their avatars.
		remote_presence.emit(pid, pname, true)

	room_state.emit(_room_id, _local_user_id, _mode)

func _on_user_presence(user_id: int, display_name: String, is_online: bool) -> void:
	if is_online:
		_participants[user_id] = display_name
		_maybe_offer(user_id)
	else:
		_participants.erase(user_id)
		if _webrtc and _webrtc.has_method("close_peer"):
			_webrtc.close_peer(user_id)
	remote_presence.emit(user_id, display_name, is_online)

func _on_room_left(user_id: int) -> void:
	_participants.erase(user_id)
	if _webrtc and _webrtc.has_method("close_peer"):
		_webrtc.close_peer(user_id)
	user_left.emit(user_id)

func _on_relay_pose(user_id: int, head: Dictionary, left_hand: Dictionary, right_hand: Dictionary) -> void:
	remote_pose.emit(user_id, head, left_hand, right_hand)

func _on_p2p_pose(user_id: int, payload: String) -> void:
	var data = JSON.parse_string(payload)
	if data is Dictionary:
		remote_pose.emit(user_id, data.get("head", {}), data.get("left", {}), data.get("right", {}))

func _on_topology_changed(mode: String) -> void:
	_mode = mode
	if _webrtc and _webrtc.has_method("on_topology_changed"):
		_webrtc.on_topology_changed(mode)
	mode_changed.emit(mode)

func _on_webrtc_offer(from_user_id: int, sdp: String) -> void:
	if _webrtc and _webrtc.has_method("set_remote_description"):
		_webrtc.set_remote_description(from_user_id, "offer", sdp)

func _on_webrtc_answer(from_user_id: int, sdp: String) -> void:
	if _webrtc and _webrtc.has_method("set_remote_description"):
		_webrtc.set_remote_description(from_user_id, "answer", sdp)

func _on_ice_candidate(from_user_id: int, candidate: String) -> void:
	if _webrtc and _webrtc.has_method("handle_ice_candidate"):
		_webrtc.handle_ice_candidate(from_user_id, candidate)

func _on_relay_voice(user_id: int, frame: PackedByteArray) -> void:
	remote_voice.emit(user_id, frame)

func _on_p2p_voice(user_id: int, frame: PackedByteArray) -> void:
	remote_voice.emit(user_id, frame)

func _on_p2p_video(user_id: int, monitor_id: int, frame_data: PackedByteArray) -> void:
	remote_video_frame.emit(user_id, monitor_id, frame_data)

func _on_relay_video(user_id: int, monitor_id: int, frame_data: PackedByteArray) -> void:
	remote_video_frame.emit(user_id, monitor_id, frame_data)

func _on_whiteboard_stroke(from_user_id: int, stroke: Dictionary) -> void:
	remote_whiteboard_stroke.emit(from_user_id, stroke)

func _on_whiteboard_clear(from_user_id: int) -> void:
	remote_whiteboard_clear.emit(from_user_id)

func _on_lobby_rooms(rooms: Array) -> void:
	lobby_rooms_received.emit(rooms)

## Share a finished whiteboard stroke (serialised dict) with the room.
func broadcast_whiteboard_stroke(stroke: Dictionary) -> void:
	if _signaling and _signaling.has_method("send_whiteboard_stroke"):
		_signaling.send_whiteboard_stroke(stroke)

## Tell the room the whiteboard was cleared.
func broadcast_whiteboard_clear() -> void:
	if _signaling and _signaling.has_method("send_whiteboard_clear"):
		_signaling.send_whiteboard_clear()

# ---------------------------------------------------------------------------
# Screen sharing (opt-in, per-monitor) — see PrivacyManager in main.gd
# ---------------------------------------------------------------------------

## Tell the room which monitors the local user is exposing (or that sharing is off).
## The server fans this out to the other participants as `screen_share_state`.
func broadcast_screen_share(monitor_count: int, monitor_ids: Array, enabled: bool) -> void:
	if _signaling and _signaling.has_method("send_screen_share_state"):
		_signaling.send_screen_share_state(monitor_count, monitor_ids, enabled)

## Send the layout (world pose + size + resolution) of the local user's shared
## panels so the room can place them around this user's avatar. The server fans it
## out as `remote_screen_layout`.
func broadcast_screen_layout(monitors: Array) -> void:
	if _signaling and _signaling.has_method("send_monitor_layout_update"):
		_signaling.send_monitor_layout_update(monitors)

func _on_screen_share_state(user_id: int, monitor_count: int, monitor_ids: Array, enabled: bool) -> void:
	remote_screen_share.emit(user_id, monitor_count, monitor_ids, enabled)

func _on_remote_screen_layout(user_id: int, monitors: Array) -> void:
	remote_screen_layout.emit(user_id, monitors)

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

## In a P2P mesh, the lower-id peer offers to the higher-id peer (glare-free).
func _maybe_offer(user_id: int) -> void:
	if _mode != "p2p":
		return
	if _webrtc and _webrtc.has_method("create_offer") and is_offerer_for(user_id):
		_webrtc.create_offer(user_id)

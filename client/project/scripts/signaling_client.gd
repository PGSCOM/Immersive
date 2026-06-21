## WebSocket client for the Immersive-2 signaling server.
## Handles room join/leave, presence, pose relay, and WebRTC signaling.

extends Node

# --- Signals ---

signal connected_to_signaling
signal disconnected_from_signaling
signal room_joined(room_id: String, user_id: int, participants: Array)
signal room_left(user_id: int)
signal user_presence(user_id: int, display_name: String, is_online: bool)
signal user_pose_received(user_id: int, head: Dictionary, left_hand: Dictionary, right_hand: Dictionary)
signal screen_share_state(user_id: int, monitor_count: int, monitor_ids: Array, enabled: bool)
signal remote_screen_layout(user_id: int, monitors: Array)
signal topology_changed(mode: String)
signal webrtc_offer_received(from_user_id: int, sdp: String)
signal webrtc_answer_received(from_user_id: int, sdp: String)
signal ice_candidate_received(from_user_id: int, candidate: String)
signal whiteboard_stroke_received(from_user_id: int, stroke: Dictionary)
signal whiteboard_clear_received(from_user_id: int)
signal voice_frame_received(from_user_id: int, frame: PackedByteArray)
## A remote user's shared-monitor MJPEG frame relayed by the SFU (3+ users).
signal video_frame_received(from_user_id: int, monitor_id: int, frame: PackedByteArray)
## Emitted on lobby_rooms (response to send_lobby_list) and lobby_update (server push).
signal lobby_rooms_received(rooms: Array)

# --- State ---

var ws_client: WebSocketPeer = WebSocketPeer.new()
var _connected: bool = false
var _url: String = ""
var _reconnect_timer: float = 0.0
var _reconnect_interval: float = 5.0

func _ready() -> void:
	set_process(false)

func connect_to_signaling(url: String) -> void:
	_url = url
	var err := ws_client.connect_to_url(url)
	if err != OK:
		push_error("[Signaling] Failed to connect to %s (error %d)" % [url, err])
		return
	set_process(true)
	print("[Signaling] Connecting to %s..." % url)

func disconnect_from_signaling() -> void:
	ws_client.close()
	_connected = false
	set_process(false)

func _process(delta: float) -> void:
	ws_client.poll()
	var state := ws_client.get_ready_state()

	match state:
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				connected_to_signaling.emit()
				print("[Signaling] Connected")
			_read_messages()

		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				disconnected_from_signaling.emit()
				print("[Signaling] Disconnected")
			set_process(false)

		WebSocketPeer.STATE_CLOSING:
			pass

		WebSocketPeer.STATE_CONNECTING:
			pass

func _read_messages() -> void:
	while ws_client.get_available_packet_count() > 0:
		var packet := ws_client.get_packet()
		var text := packet.get_string_from_utf8()
		var data: Dictionary
		if not _safe_parse_json(text, data):
			continue
		_handle_message(data)

func _safe_parse_json(text: String, out: Dictionary) -> bool:
	if text.is_empty():
		return false
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		out.assign(parsed)
		return true
	return false

func _handle_message(data: Dictionary) -> void:
	var msg_type: String = data.get("type", "")
	match msg_type:
		"room_joined":
			room_joined.emit(
				data.get("room_id", ""),
				data.get("user_id", 0),
				data.get("participants", [])
			)
		"room_left":
			room_left.emit(data.get("user_id", 0))
		"user_presence":
			user_presence.emit(
				data.get("user_id", 0),
				data.get("display_name", ""),
				data.get("is_online", false)
			)
		"user_pose":
			user_pose_received.emit(
				data.get("user_id", 0),
				data.get("head", {}),
				data.get("left_hand", {}),
				data.get("right_hand", {})
			)
		"screen_share_state":
			screen_share_state.emit(
				data.get("user_id", 0),
				data.get("monitor_count", 0),
				data.get("monitor_ids", []),
				data.get("enabled", false)
			)
		"remote_screen_layout":
			remote_screen_layout.emit(
				data.get("user_id", 0),
				data.get("monitors", [])
			)
		"topology_changed":
			topology_changed.emit(data.get("mode", "p2p"))
		"webrtc_offer":
			webrtc_offer_received.emit(data.get("from_user_id", 0), data.get("sdp", ""))
		"webrtc_answer":
			webrtc_answer_received.emit(data.get("from_user_id", 0), data.get("sdp", ""))
		"ice_candidate":
			ice_candidate_received.emit(data.get("from_user_id", 0), data.get("candidate", ""))
		"whiteboard_stroke":
			whiteboard_stroke_received.emit(data.get("from_user_id", 0), data.get("stroke", {}))
		"whiteboard_clear":
			whiteboard_clear_received.emit(data.get("from_user_id", 0))
		"lobby_rooms", "lobby_update":
			lobby_rooms_received.emit(data.get("rooms", []))
		"voice_frame":
			var b64: String = data.get("audio", "")
			if not b64.is_empty():
				voice_frame_received.emit(data.get("from_user_id", 0), Marshalls.base64_to_raw(b64))
		"video_frame":
			var b64: String = data.get("video", "")
			if not b64.is_empty():
				video_frame_received.emit(
					data.get("from_user_id", 0),
					data.get("monitor_id", 0),
					Marshalls.base64_to_raw(b64)
				)

# --- Outbound messages ---

## Join or create a room. Pass public=true so the room appears in the lobby listing.
func send_room_join(room_id: String, display_name: String, public: bool = false) -> void:
	_send_json({"type": "room_join", "payload": {"room_id": room_id, "display_name": display_name, "public": public}})

## Request the current public-lobby room list (server replies with lobby_rooms).
func send_lobby_list() -> void:
	_send_json({"type": "lobby_list", "payload": {}})

func send_user_pose(head: Dictionary, left_hand: Dictionary, right_hand: Dictionary) -> void:
	_send_json({"type": "user_pose", "payload": {"head": head, "left_hand": left_hand, "right_hand": right_hand}})

func send_screen_share_state(monitor_count: int, monitor_ids: Array, enabled: bool) -> void:
	_send_json({"type": "screen_share_state", "payload": {"monitor_count": monitor_count, "monitor_ids": monitor_ids, "enabled": enabled}})

func send_monitor_layout_update(monitors: Array) -> void:
	_send_json({"type": "monitor_layout_update", "payload": {"monitors": monitors}})

func send_webrtc_offer(target_user_id: int, sdp: String) -> void:
	_send_json({"type": "webrtc_offer", "payload": {"target_user_id": target_user_id, "sdp": sdp}})

func send_webrtc_answer(target_user_id: int, sdp: String) -> void:
	_send_json({"type": "webrtc_answer", "payload": {"target_user_id": target_user_id, "sdp": sdp}})

func send_ice_candidate(target_user_id: int, candidate: String) -> void:
	_send_json({"type": "ice_candidate", "payload": {"target_user_id": target_user_id, "candidate": candidate}})

func send_whiteboard_stroke(stroke: Dictionary) -> void:
	_send_json({"type": "whiteboard_stroke", "payload": {"stroke": stroke}})

func send_whiteboard_clear() -> void:
	_send_json({"type": "whiteboard_clear", "payload": {}})

## Relay an encoded voice frame to the room (SFU path; base64 over JSON). The
## server never logs or stores the payload — it only fans it out to the room.
func send_voice_frame(frame: PackedByteArray) -> void:
	if frame.is_empty():
		return
	_send_json({"type": "voice_frame", "payload": {"audio": Marshalls.raw_to_base64(frame)}})

## Relay an MJPEG frame for one shared monitor to the room (SFU path, 3+ users).
## In a 2-user P2P room this is never called — frames go over the WebRTC video
## channel instead (see webrtc_manager.gd). The server fans the payload out to
## all other participants as a "video_frame" message.
func send_video_frame(monitor_id: int, frame: PackedByteArray) -> void:
	if frame.is_empty():
		return
	_send_json({"type": "video_frame", "payload": {
		"monitor_id": monitor_id,
		"video": Marshalls.raw_to_base64(frame),
	}})

func _send_json(data: Dictionary) -> void:
	if _connected:
		ws_client.send_text(JSON.stringify(data))

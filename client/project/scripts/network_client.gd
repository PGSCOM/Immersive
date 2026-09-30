## Network client for Immersive-2.
## Handles TCP control channel and UDP video reception.

extends Node

# --- Signals ---

## Emitted when successfully connected to the host.
signal connected_to_host
## Emitted when disconnected from the host.
signal disconnected_from_host
## Emitted when monitor list is received.
signal monitor_list_received(monitors: Array)
## Emitted when streaming starts.
signal stream_started(monitor_id: int, width: int, height: int, codec: int)
## Emitted when a monitor stream stops (monitor_id = -1 if unknown).
signal stream_stopped(monitor_id: int)
## Emitted when a complete video frame is received.
signal video_frame_received(monitor_id: int, frame_data: PackedByteArray, width: int, height: int)
## Emitted when a latency response is received from the host.
signal latency_response_received(probe_id: int, client_timestamp: int)
## Emitted when the host announces its audio stream.
signal audio_stream_started(sample_rate: int, channels: int, audio_port: int)
## Emitted when the host stops its audio stream.
signal audio_stream_stopped
## Emitted when a gap in completed frame numbers is detected (frame lost or
## dropped). For inter-frame codecs this breaks the decode chain.
signal frame_gap_detected(monitor_id: int)
## Emitted per audio packet received in-band on TCP (USB mode). Same bytes as
## one UDP audio packet; feed it to AudioReceiver.parse_packet().
signal audio_packet_received(packet: PackedByteArray)
## The host refused the HELLO (REJECT_* reason, see protocol.h); the
## connection is closed right after, with disconnected_from_host.
signal connection_rejected(reason: int)
## HELLO_ACK arrived: the PC's name (empty from older hosts) and its
## HOST_FLAG_* bits (view-only, can make virtual screens).
signal handshake_accepted(host_name: String, host_flags: int)
## Answer to a virtual screen request (VDISPLAY_* status; removed = answer to
## a removal; monitor_id = the screen made or removed, 0xFF on failure).
signal virtual_display_result(status: int, removed: bool, monitor_id: int)

# --- Constants (matching protocol.h) ---

const MSG_HELLO: int                 = 0x01
const MSG_HELLO_ACK: int             = 0x02
const MSG_MONITOR_LIST: int          = 0x03
const MSG_MONITOR_SELECT: int        = 0x04
const MSG_STREAM_START: int          = 0x05
const MSG_STREAM_STOP: int           = 0x06
const MSG_AUDIO_START: int           = 0x07
const MSG_AUDIO_STOP: int            = 0x08
const MSG_HELLO_REJECT: int          = 0x09
const MSG_INPUT_MOUSE: int           = 0x10
const MSG_INPUT_KEYBOARD: int        = 0x11
const MSG_INPUT_POINTER: int         = 0x12
const MSG_MULTI_MONITOR_SELECT: int  = 0x20
const MSG_STREAM_CONFIG: int         = 0x21
const MSG_VIRTUAL_DISPLAY_CREATE: int = 0x22
const MSG_VIRTUAL_DISPLAY_REMOVE: int = 0x23
const MSG_VIRTUAL_DISPLAY_RESULT: int = 0x24
const MSG_FRAME_ACK: int             = 0x30
const MSG_REQUEST_KEYFRAME: int      = 0x31
const MSG_LATENCY_PROBE: int         = 0x40
const MSG_LATENCY_RESPONSE: int      = 0x41
const MSG_VIDEO_FRAME: int           = 0x50
const MSG_AUDIO_DATA: int            = 0x51
const MSG_PING: int                  = 0xFF

const PROTOCOL_VERSION: int   = 1
const MAX_UDP_PAYLOAD: int    = 1400
const VIDEO_HEADER_SIZE: int  = 9  # 1 + 4 + 2 + 2 bytes
const HELLO_FLAG_TCP_MEDIA: int = 0x01
const REJECT_PIN_REQUIRED: int = 1
const REJECT_WRONG_PIN: int = 2
const REJECT_SERVER_FULL: int = 3
const REJECT_LOCKED_OUT: int = 4
const HOST_FLAG_VIEW_ONLY: int = 0x01
const HOST_FLAG_VIRTUAL_DISPLAYS: int = 0x02
const MONITOR_FLAG_VIRTUAL: int = 0x01
const MONITOR_FLAG_PRIMARY: int = 0x02
## A whole encoded frame arrives as one VIDEO_FRAME message in TCP media mode;
## a high-quality 4K MJPEG keyframe runs to a few MB.
const MAX_MESSAGE_SIZE: int   = 16 * 1024 * 1024

# --- State ---

var tcp_client: StreamPeerTCP = StreamPeerTCP.new()
var udp_client: PacketPeerUDP = PacketPeerUDP.new()

var _connected: bool = false
var _host_ip: String = ""
var _tcp_port: int = 0
var _udp_port: int = 0
## USB mode: `adb reverse` only tunnels TCP, so video and audio are asked for
## in-band on the control socket (HELLO_FLAG_TCP_MEDIA) and UDP is unused.
var _tcp_media: bool = false
## Pairing PIN sent in HELLO (0 = none; the host skips it for 127.0.0.1).
var _pin: int = 0

## Received video, for the stats line: frames and bytes since the last
## take_stats() call.
var _stat_frames: int = 0
var _stat_bytes: int = 0
var _stat_since_ms: int = 0

## Frame reassembly buffer: frame_number -> { chunks: Dictionary, total: int }
var _frame_buffer: Dictionary = {}

## Stream resolution per monitor id -> Vector2i. One shared pair of globals was
## wrong as soon as a second monitor started: the latest STREAM_START overwrote
## it, so every other monitor's frames were reported at the wrong size.
var _stream_size: Dictionary = {}

## Connection-attempt deadline (ms). StreamPeerTCP can sit in STATUS_CONNECTING
## for the whole OS SYN timeout, which left the client stuck on "Connecting…"
## with auto-reconnect never firing.
const CONNECT_TIMEOUT_MS: int = 8000
var _connect_deadline_ms: int = 0

## The host answers main.gd's LATENCY_PROBE every 2 s, so this much silence
## means it is gone: hung, powered off, or dropped off Wi-Fi without a FIN/RST.
## TCP alone keeps such a socket "connected" for ~15 min, frozen panels and all,
## and auto-reconnect never fires. (Not PING: both ends echo PING, so a
## client-sent PING would bounce back and forth forever.)
const HOST_TIMEOUT_MS: int = 10000
var _last_rx_ms: int = 0

## Throttle for the stale-partial-frame sweep.
var _next_cleanup_ms: int = 0

## Highest completed frame number per monitor, for loss/gap detection.
var _last_completed_frame: Dictionary = {}
## First frame number of each monitor's current stream (STREAM_START's
## first_frame). Anything below it is a late leftover of the previous stream.
## Hosts too old to send it get no ordering checks (their streams restart at 0).
var _first_frame: Dictionary = {}

var _tcp_buffer := PackedByteArray()

func _ready() -> void:
	set_process(false)

func _notification(what: int) -> void:
	# Nothing is probed while the app is paused (headset taken off), so the
	# silence is ours, not the host's — don't count it against the host.
	if what == NOTIFICATION_APPLICATION_RESUMED:
		_last_rx_ms = Time.get_ticks_msec()

## Connect to the Immersive-2 host. tcp_media: receive video/audio on the TCP
## control socket instead of UDP (USB via adb reverse).
func connect_to_server(ip: String, tcp_port: int, udp_port: int, tcp_media: bool = false,
		pin: int = 0) -> void:
	# Cerrar conexiones previas limpiamente antes de reconectar
	udp_client.close()
	tcp_client.disconnect_from_host()
	_tcp_buffer.clear()
	_connected = false
	_frame_buffer.clear()
	_last_completed_frame.clear()
	_first_frame.clear()
	_stream_size.clear()

	_host_ip = ip
	_tcp_port = tcp_port
	_udp_port = udp_port
	_tcp_media = tcp_media
	_pin = pin

	_connect_deadline_ms = Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	tcp_client.connect_to_host(ip, tcp_port)
	set_process(true)

	print("[Network] Connecting to %s:%d%s..." % [ip, tcp_port,
		" (video over TCP)" if tcp_media else ""])

func _process(_delta: float) -> void:
	tcp_client.poll()

	# Handle TCP connection state
	var tcp_status: StreamPeerTCP.Status = tcp_client.get_status()

	match tcp_status:
		StreamPeerTCP.STATUS_CONNECTED:
			if not _connected:
				_connected = true
				_last_rx_ms = Time.get_ticks_msec()
				_on_tcp_connected()
			_read_tcp_messages()
			if _connected and Time.get_ticks_msec() - _last_rx_ms > HOST_TIMEOUT_MS:
				_fail_connection("host not responding for %d s" % (HOST_TIMEOUT_MS / 1000))
				return

		StreamPeerTCP.STATUS_CONNECTING:
			# A host that is off or unreachable never reaches STATUS_ERROR
			# quickly — without this deadline the client stayed in CONNECTING
			# forever and main.gd's auto-reconnect (which only runs while
			# DISCONNECTED) never got a chance to retry.
			if Time.get_ticks_msec() > _connect_deadline_ms:
				_fail_connection("connection to %s:%d timed out" % [_host_ip, _tcp_port])

		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			# Also covers a connect that was refused before it ever succeeded,
			# which previously left the client silently wedged.
			_fail_connection("disconnected" if _connected else
				"could not connect to %s:%d" % [_host_ip, _tcp_port])

	# Read UDP video packets
	if _connected and not _tcp_media:
		_read_udp_packets()

## Tear the connection down and tell the rest of the app, so the reconnect
## logic and the UI both see a DISCONNECTED state.
func _fail_connection(reason: String) -> void:
	_connected = false
	_tcp_buffer.clear()
	_frame_buffer.clear()
	_last_completed_frame.clear()
	_first_frame.clear()
	_stream_size.clear()
	tcp_client.disconnect_from_host()
	udp_client.close()
	set_process(false)
	print("[Network] %s" % reason)
	disconnected_from_host.emit()

func _on_tcp_connected() -> void:
	print("[Network] TCP connected, sending HELLO")

	# Bind UDP for receiving video. A large receive buffer keeps a burst of
	# chunks for one frame (a keyframe is ~150-200 packets) from being dropped by
	# the OS/Godot ring buffer on a busy WiFi link — losing a single chunk makes
	# the whole frame fail to reassemble, which looks like stutter, artifacts or a
	# frozen/black screen. PacketPeerUDP.bind()'s recv_buffer_size (bytes) is the
	# queue capacity in Godot 4; 8 MB gives generous headroom for motion bursts.
	var bind_err := OK if _tcp_media else udp_client.bind(_udp_port, "*", 8 * 1024 * 1024)
	if bind_err != OK:
		push_error("[Network] Failed to bind UDP port %d (error %d) — no video will be received. Is another client (or the host on this machine) using it?" % [_udp_port, bind_err])

	# HELLO: version, name[32] (shown in the host's log), flags, pairing PIN.
	var hello := PackedByteArray()
	hello.resize(38)
	hello[0] = PROTOCOL_VERSION
	var model := OS.get_model_name()
	var name_bytes := (model if model != "GenericDevice" and not model.is_empty() \
		else "Immersive-2 VR").to_utf8_buffer()
	for i in range(min(name_bytes.size(), 31)):
		hello[1 + i] = name_bytes[i]
	hello[33] = HELLO_FLAG_TCP_MEDIA if _tcp_media else 0
	hello.encode_u32(34, _pin)

	_send_control_message(MSG_HELLO, hello)
	connected_to_host.emit()

## Select a monitor to stream.
func select_monitor(monitor_id: int) -> void:
	var payload := PackedByteArray()
	payload.resize(1)
	payload[0] = monitor_id
	_send_control_message(MSG_MONITOR_SELECT, payload)

## Send mouse input to the host.
func send_mouse_input(monitor_id: int, x: int, y: int, buttons: int, scroll: int, scroll_h: int = 0) -> void:
	var payload := PackedByteArray()
	payload.resize(10)
	payload[0] = monitor_id
	payload.encode_u16(1, x)
	payload.encode_u16(3, y)
	payload[5] = buttons
	payload.encode_s16(6, scroll)
	payload.encode_s16(8, scroll_h)
	_send_control_message(MSG_INPUT_MOUSE, payload)

## Send keyboard input to the host.
func send_keyboard_input(monitor_id: int, scancode: int, pressed: bool, modifiers: int) -> void:
	var payload := PackedByteArray()
	payload.resize(5)
	payload[0] = monitor_id
	payload.encode_u16(1, scancode)
	payload[3] = 1 if pressed else 0
	payload[4] = modifiers
	_send_control_message(MSG_INPUT_KEYBOARD, payload)

# --- Internal TCP handling ---

func _send_control_message(msg_type: int, payload: PackedByteArray) -> void:
	# Build TLV header: type (1 byte) + length (4 bytes LE)
	var msg := PackedByteArray()
	msg.resize(5)
	msg[0] = msg_type
	msg.encode_u32(1, payload.size())
	if payload.size() > 0:
		msg.append_array(payload)
	# One write, not two: FRAME_ACK alone is one message per decoded frame per
	# monitor, so halving the socket writes matters at 3 x 60 fps.
	tcp_client.put_data(msg)

func _read_tcp_messages() -> void:
	# Leer todos los bytes disponibles y guardarlos en el buffer seguro.
	# In a loop: in TCP media mode whole frames come through here, and one read
	# per render frame capped throughput at whatever the socket had buffered.
	var avail: int = tcp_client.get_available_bytes()
	while avail > 0:
		var data := tcp_client.get_data(avail)
		if data[0] != OK:
			break
		_tcp_buffer.append_array(data[1])
		_last_rx_ms = Time.get_ticks_msec()
		avail = tcp_client.get_available_bytes()

	# Procesar mensajes completos. Walk an offset and trim once at the end:
	# re-slicing the remainder after every message copied the whole backlog
	# per message, which with frames in the stream (USB mode) went quadratic.
	var off := 0
	while _tcp_buffer.size() - off >= 5:
		var msg_type: int = _tcp_buffer[off]
		var msg_length: int = _tcp_buffer.decode_u32(off + 1)

		# Filtro de seguridad
		if msg_length > MAX_MESSAGE_SIZE:
			_fail_connection("rejecting oversized message: %d bytes" % msg_length)
			return

		# Si el buffer aún no tiene el mensaje completo, esperamos al siguiente fotograma
		if _tcp_buffer.size() - off < 5 + msg_length:
			break

		var payload := _tcp_buffer.slice(off + 5, off + 5 + msg_length)
		off += 5 + msg_length

		_handle_control_message(msg_type, payload)
		if not _connected:
			return  # a handler tore the connection down (buffer already cleared)
	if off > 0:
		_tcp_buffer = _tcp_buffer.slice(off)

func _handle_control_message(msg_type: int, payload: PackedByteArray) -> void:
	match msg_type:
		MSG_HELLO_ACK:
			if payload.size() >= 4:
				var version: int = payload[0]
				var udp_port: int = payload.decode_u16(1)
				var monitor_count: int = payload[3]
				var host_name := payload.slice(4, 68).get_string_from_utf8() \
					if payload.size() >= 68 else ""
				var host_flags: int = payload[68] if payload.size() >= 69 else 0
				print("[Network] HELLO_ACK: version=%d udp_port=%d monitors=%d host=%s flags=%d" %
					[version, udp_port, monitor_count, host_name, host_flags])
				handshake_accepted.emit(host_name, host_flags)

		MSG_HELLO_REJECT:
			var reason: int = payload[0] if payload.size() >= 1 else 0
			connection_rejected.emit(reason)
			_fail_connection("host refused the connection (reason %d)" % reason)

		MSG_MONITOR_LIST:
			if payload.size() >= 1:
				var count: int = payload[0]
				var monitors: Array = []
				var offset: int = 1
				for i in range(count):
					if offset + 70 > payload.size():
						break
					var mon := {
						"id": payload[offset],
						"width": payload.decode_u16(offset + 1),
						"height": payload.decode_u16(offset + 3),
						"refresh_rate": payload[offset + 5],
						"name": payload.slice(offset + 6, offset + 70).get_string_from_utf8(),
						"virtual": false,
						"primary": false,
					}
					monitors.append(mon)
					offset += 70
				# Newer hosts append one MONITOR_FLAG_* byte per monitor.
				if payload.size() >= offset + monitors.size():
					for i in monitors.size():
						var f: int = payload[offset + i]
						monitors[i]["virtual"] = (f & MONITOR_FLAG_VIRTUAL) != 0
						monitors[i]["primary"] = (f & MONITOR_FLAG_PRIMARY) != 0
				monitor_list_received.emit(monitors)

		MSG_VIRTUAL_DISPLAY_RESULT:
			if payload.size() >= 3:
				print("[Network] VIRTUAL_DISPLAY_RESULT: status=%d removed=%d monitor=%d" %
					[payload[0], payload[1], payload[2]])
				virtual_display_result.emit(payload[0], payload[1] != 0, payload[2])

		MSG_STREAM_START:
			if payload.size() >= 6:
				var monitor_id: int = payload[0]
				var w: int = payload.decode_u16(1)
				var h: int = payload.decode_u16(3)
				var codec: int = payload[5]
				_stream_size[monitor_id] = Vector2i(w, h)
				print("[Network] STREAM_START: monitor=%d %dx%d codec=%d" %
					[monitor_id, w, h, codec])
				# New stream: forget the old high-water mark and any half-built
				# frame. Chunks of the old stream can still be queued in the
				# UDP socket; first_frame tells them apart.
				_last_completed_frame.erase(monitor_id)
				_first_frame.erase(monitor_id)
				_drop_partial_frames(monitor_id, 1 << 32)
				if payload.size() >= 10:
					var first: int = payload.decode_u32(6)
					_first_frame[monitor_id] = first
					_last_completed_frame[monitor_id] = first - 1
				stream_started.emit(monitor_id, w, h, codec)

		MSG_STREAM_STOP:
			var stopped_monitor: int = payload[0] if payload.size() >= 1 else -1
			print("[Network] STREAM_STOP monitor=%d" % stopped_monitor)
			# Drop pending chunks of that monitor (or all if unknown)
			for key in _frame_buffer.keys():
				if stopped_monitor < 0 or _frame_buffer[key]["monitor_id"] == stopped_monitor:
					_frame_buffer.erase(key)
			if stopped_monitor < 0:
				_last_completed_frame.clear()
				_first_frame.clear()
				_stream_size.clear()
			else:
				_last_completed_frame.erase(stopped_monitor)
				_stream_size.erase(stopped_monitor)
			stream_stopped.emit(stopped_monitor)

		MSG_AUDIO_START:
			# payload: sample_rate (u16) + channels (u8) + audio_port (u16)
			if payload.size() >= 5:
				var sample_rate: int = payload.decode_u16(0)
				var channels: int = payload[2]
				var audio_port: int = payload.decode_u16(3)
				print("[Network] AUDIO_START: %d Hz, %d ch, UDP:%d" %
					[sample_rate, channels, audio_port])
				audio_stream_started.emit(sample_rate, channels, audio_port)

		MSG_AUDIO_STOP:
			print("[Network] AUDIO_STOP")
			audio_stream_stopped.emit()

		MSG_LATENCY_RESPONSE:
			# payload: probe_id (8B) + client_timestamp (8B) + server_timestamp (8B)
			if payload.size() >= 16:
				var probe_id: int      = payload.decode_u64(0)
				var client_ts: int     = payload.decode_u64(8)
				latency_response_received.emit(probe_id, client_ts)

		MSG_VIDEO_FRAME:
			# payload: monitor_id (u8) + frame_number (u32) + whole frame
			if payload.size() > 5:
				_deliver_frame(payload[0], payload.decode_u32(1), payload.slice(5))

		MSG_AUDIO_DATA:
			audio_packet_received.emit(payload)

		MSG_PING:
			# Echo back
			_send_control_message(MSG_PING, PackedByteArray())

# --- Internal UDP handling ---

func _read_udp_packets() -> void:
	while udp_client.get_available_packet_count() > 0:
		var packet: PackedByteArray = udp_client.get_packet()
		if packet.size() < VIDEO_HEADER_SIZE:
			continue

		# Parse video packet header
		var monitor_id: int = packet[0]
		var frame_num: int = packet.decode_u32(1)
		var chunk_idx: int = packet.decode_u16(5)
		var chunk_cnt: int = packet.decode_u16(7)
		var chunk_data: PackedByteArray = packet.slice(VIDEO_HEADER_SIZE)

		# Validate chunk index to avoid corrupting the frame buffer
		if frame_num < 0 or chunk_idx < 0 or chunk_idx >= chunk_cnt:
			continue
		# Late chunks of a stream that was stopped, or of a frame older than
		# the last one shown: nothing can use them.
		if not _stream_size.has(monitor_id) or \
				(_first_frame.has(monitor_id) and frame_num <= int(_last_completed_frame[monitor_id])):
			continue

		# Store chunk in frame buffer (key combines monitor and frame number
		# so simultaneous monitor streams cannot collide)
		var frame_key: int = (monitor_id << 32) | frame_num
		# A restarted stream reuses low frame numbers; if a late chunk from the
		# previous stream shares a key but reports a different chunk count, the
		# stale entry would never complete. Start over on a mismatch.
		if _frame_buffer.has(frame_key) and int(_frame_buffer[frame_key]["total"]) != chunk_cnt:
			_frame_buffer.erase(frame_key)
		if not _frame_buffer.has(frame_key):
			_frame_buffer[frame_key] = {
				"chunks": {},
				"total": chunk_cnt,
				"monitor_id": monitor_id,
				"frame_num": frame_num,
				"created_ms": Time.get_ticks_msec()
			}

		_frame_buffer[frame_key]["chunks"][chunk_idx] = chunk_data

		# Check if frame is complete
		if _frame_buffer[frame_key]["chunks"].size() == chunk_cnt:
			_assemble_frame(frame_key)

	_cleanup_old_frames()

var _frames_assembled: int = 0

func _assemble_frame(frame_key: int) -> void:
	var frame_info: Dictionary = _frame_buffer[frame_key]
	var total: int = frame_info["total"]

	# Concatenate chunks in order
	var frame_data := PackedByteArray()
	for i in range(total):
		if frame_info["chunks"].has(i):
			frame_data.append_array(frame_info["chunks"][i])
	_frame_buffer.erase(frame_key)
	_deliver_frame(frame_info["monitor_id"], frame_info["frame_num"], frame_data)

## Hand a complete frame (reassembled from UDP, or one TCP VIDEO_FRAME) to
## the app and ACK it.
func _deliver_frame(monitor_id: int, frame_num: int, frame_data: PackedByteArray) -> void:
	# Detect a gap in completed frame numbers (a frame was lost or the host
	# dropped it). For inter-frame codecs this breaks the decode chain, so we
	# signal it; main.gd asks for a keyframe when a hardware decoder is active.
	if not _stream_size.has(monitor_id):
		return  # that monitor's stream already stopped
	if _last_completed_frame.has(monitor_id):
		var prev: int = _last_completed_frame[monitor_id]
		if frame_num <= prev and _first_frame.has(monitor_id):
			return  # older than one already shown, or of the previous stream
		if frame_num > prev + 1:
			frame_gap_detected.emit(monitor_id)
			_drop_partial_frames(monitor_id, frame_num)
	# (An older host restarts streams at 0 and sends no first_frame: its
	# frames are shown as they come, as before.)
	_last_completed_frame[monitor_id] = frame_num

	_frames_assembled += 1
	_stat_frames += 1
	_stat_bytes += frame_data.size()
	# Log every large frame (potential IDR) and periodically for small ones.
	if frame_data.size() > 50000:
		print("[Net] LARGE frame assembled: mon=%d frame=%d size=%d" % [
				monitor_id, frame_num, frame_data.size()])
	elif _frames_assembled % 120 == 0:
		print("[Net] frames assembled=%d last: mon=%d frame=%d size=%d buf_entries=%d" % [
				_frames_assembled, monitor_id, frame_num, frame_data.size(), _frame_buffer.size()])

	var size: Vector2i = _stream_size.get(monitor_id, Vector2i.ZERO)
	video_frame_received.emit(monitor_id, frame_data, size.x, size.y)

	# Acknowledge so the host's flow control can drop frames when we lag
	send_frame_ack(monitor_id, frame_num)

## Forget the unfinished frames of `monitor_id` older than `frame_num`: once a
## newer frame is complete they can never be shown.
func _drop_partial_frames(monitor_id: int, frame_num: int) -> void:
	for key in _frame_buffer.keys():
		var e: Dictionary = _frame_buffer[key]
		if e["monitor_id"] == monitor_id and e["frame_num"] < frame_num:
			_frame_buffer.erase(key)

## Drop partial frames older than 5 s, across every monitor.
##
## Time-based rather than the old frame-count window (90 frames), which could
## race a large IDR that takes ~0.5 s to transmit and discard it mid-assembly.
## Swept once a second instead of on every completed frame: it walks the whole
## buffer, and at 3 monitors x 60 fps that was 180 full scans a second. Sweeping
## every monitor (not just the one that just completed) also means a stream that
## dies mid-frame no longer leaks its chunks for the rest of the session.
func _cleanup_old_frames() -> void:
	var now := Time.get_ticks_msec()
	if now < _next_cleanup_ms:
		return
	_next_cleanup_ms = now + 1000

	var keys_to_remove: Array = []
	for key in _frame_buffer.keys():
		var entry = _frame_buffer[key]
		var age_ms: int = now - int(entry.get("created_ms", now))
		if age_ms > 5000:
			print("[Net] CLEANUP stale frame age=%dms: mon=%d frame=%d chunks=%d/%d" % [
					age_ms, entry["monitor_id"], entry["frame_num"],
					entry["chunks"].size(), entry["total"]])
			keys_to_remove.append(key)
	for key in keys_to_remove:
		_frame_buffer.erase(key)

## Received video since the previous call: {fps, mbps} (fps summed over
## every monitor). Call about once a second.
func take_stats() -> Dictionary:
	var now := Time.get_ticks_msec()
	var secs: float = max(0.001, (now - _stat_since_ms) / 1000.0)
	var stats := {"fps": _stat_frames / secs, "mbps": _stat_bytes * 8.0 / secs / 1e6}
	_stat_frames = 0
	_stat_bytes = 0
	_stat_since_ms = now
	return stats

## Send a multi-monitor select (up to 3 monitors simultaneously).
func select_monitors(monitor_ids: Array) -> void:
	var payload := PackedByteArray()
	payload.resize(5)  # 1 count + 3 ids + 1 reserved
	payload[0] = min(monitor_ids.size(), 3)
	for i in range(min(monitor_ids.size(), 3)):
		payload[1 + i] = monitor_ids[i]
	# Fill unused slots with 0xFF
	for i in range(monitor_ids.size(), 3):
		payload[1 + i] = 0xFF
	payload[4] = 0  # reserved
	_send_control_message(MSG_MULTI_MONITOR_SELECT, payload)

## Send stream quality settings. A new codec or size restarts the streams;
## bitrate, JPEG quality and fps are retuned live (they are ceilings: the
## host adapts below them to the link).
## codec: 0 = H.264, 2 = MJPEG, 0xFF = host default. Zero values = default.
func send_stream_config(codec: int, bitrate_kbps: int, jpeg_quality: int,
		max_width: int, max_fps: int) -> void:
	var payload := PackedByteArray()
	payload.resize(9)
	payload[0] = codec & 0xFF
	payload.encode_u32(1, max(0, bitrate_kbps))
	payload[5] = clamp(jpeg_quality, 0, 95)
	payload.encode_u16(6, max(0, max_width))
	payload[8] = clamp(max_fps, 0, 120)
	_send_control_message(MSG_STREAM_CONFIG, payload)
	print("[Network] STREAM_CONFIG: codec=%d bitrate=%d jpegq=%d max_w=%d fps=%d" %
		[codec, bitrate_kbps, jpeg_quality, max_width, max_fps])

## Ask the host for an extra, virtual screen of this size.
func send_virtual_display_create(width: int, height: int, refresh_rate: int = 60) -> void:
	var payload := PackedByteArray()
	payload.resize(5)
	payload.encode_u16(0, width)
	payload.encode_u16(2, height)
	payload[4] = clampi(refresh_rate, 0, 255)
	_send_control_message(MSG_VIRTUAL_DISPLAY_CREATE, payload)

## Remove a virtual screen the host made.
func send_virtual_display_remove(monitor_id: int) -> void:
	_send_control_message(MSG_VIRTUAL_DISPLAY_REMOVE, PackedByteArray([monitor_id]))

## Send a frame acknowledgement.
func send_frame_ack(monitor_id: int, frame_number: int) -> void:
	var payload := PackedByteArray()
	payload.resize(5)
	payload[0] = monitor_id
	payload.encode_u32(1, frame_number)
	_send_control_message(MSG_FRAME_ACK, payload)

## Ask the host to emit a keyframe (IDR) for a monitor — recovery after loss.
func send_request_keyframe(monitor_id: int) -> void:
	var payload := PackedByteArray()
	payload.resize(1)
	payload[0] = monitor_id
	_send_control_message(MSG_REQUEST_KEYFRAME, payload)

## Send a latency probe (probe_id + client_timestamp, each 8 bytes LE).
func send_latency_probe(probe_id: int, client_timestamp_us: int) -> void:
	var payload := PackedByteArray()
	payload.resize(16)
	payload.encode_u64(0, probe_id)
	payload.encode_u64(8, client_timestamp_us)
	_send_control_message(MSG_LATENCY_PROBE, payload)

## Explicit, user-initiated disconnect. No disconnected_from_host signal: the
## caller (main.gd) already drives the state change. Use _fail_connection() for
## a drop the app did not ask for.
func disconnect_from_server() -> void:
	_connected = false
	_tcp_buffer.clear()
	_frame_buffer.clear()
	_last_completed_frame.clear()
	_first_frame.clear()
	_stream_size.clear()
	tcp_client.disconnect_from_host()
	udp_client.close()
	set_process(false)

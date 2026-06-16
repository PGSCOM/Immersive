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

# --- Constants (matching protocol.h) ---

const MSG_HELLO: int                 = 0x01
const MSG_HELLO_ACK: int             = 0x02
const MSG_MONITOR_LIST: int          = 0x03
const MSG_MONITOR_SELECT: int        = 0x04
const MSG_STREAM_START: int          = 0x05
const MSG_STREAM_STOP: int           = 0x06
const MSG_AUDIO_START: int           = 0x07
const MSG_AUDIO_STOP: int            = 0x08
const MSG_INPUT_MOUSE: int           = 0x10
const MSG_INPUT_KEYBOARD: int        = 0x11
const MSG_INPUT_POINTER: int         = 0x12
const MSG_MULTI_MONITOR_SELECT: int  = 0x20
const MSG_STREAM_CONFIG: int         = 0x21
const MSG_FRAME_ACK: int             = 0x30
const MSG_LATENCY_PROBE: int         = 0x40
const MSG_LATENCY_RESPONSE: int      = 0x41
const MSG_PING: int                  = 0xFF

const PROTOCOL_VERSION: int   = 1
const MAX_UDP_PAYLOAD: int    = 1400
const VIDEO_HEADER_SIZE: int  = 9  # 1 + 4 + 2 + 2 bytes

# --- State ---

var tcp_client: StreamPeerTCP = StreamPeerTCP.new()
var udp_client: PacketPeerUDP = PacketPeerUDP.new()

var _connected: bool = false
var _host_ip: String = ""
var _tcp_port: int = 0
var _udp_port: int = 0

## Frame reassembly buffer: frame_number -> { chunks: Dictionary, total: int }
var _frame_buffer: Dictionary = {}
var _stream_width: int = 0
var _stream_height: int = 0

var _tcp_buffer := PackedByteArray()

# --- DEBUG: instrumentación temporal para diagnosticar pantalla negra ---
var _dbg_packets: int = 0
var _dbg_frames: int = 0
var _dbg_dropped: int = 0
var _dbg_last_bytes: int = 0
var _dbg_last_report_ms: int = 0

func _ready() -> void:
	set_process(false)

## Connect to the Immersive-2 host.
func connect_to_server(ip: String, tcp_port: int, udp_port: int) -> void:
	# Cerrar conexiones previas limpiamente antes de reconectar
	udp_client.close()
	tcp_client.disconnect_from_host()
	_tcp_buffer.clear()
	_connected = false
	_frame_buffer.clear()

	_host_ip = ip
	_tcp_port = tcp_port
	_udp_port = udp_port

	tcp_client.connect_to_host(ip, tcp_port)
	set_process(true)

	print("[Network] Connecting to %s:%d..." % [ip, tcp_port])

func _process(_delta: float) -> void:
	tcp_client.poll()

	# Handle TCP connection state
	var tcp_status: StreamPeerTCP.Status = tcp_client.get_status()

	match tcp_status:
		StreamPeerTCP.STATUS_CONNECTED:
			if not _connected:
				_connected = true
				_on_tcp_connected()
			_read_tcp_messages()

		StreamPeerTCP.STATUS_CONNECTING:
			pass  # Still connecting

		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			if _connected:
				_connected = false
				udp_client.close()
				disconnected_from_host.emit()
				set_process(false)
				print("[Network] Disconnected")

	# Read UDP video packets
	if _connected:
		_read_udp_packets()

func _on_tcp_connected() -> void:
	print("[Network] TCP connected, sending HELLO")

	# Bind UDP for receiving video. A large receive buffer (2 MB, matching the
	# host's send buffer) keeps a burst of chunks for one frame from being
	# dropped by the OS/Godot ring buffer on a busy WiFi link — losing a single
	# chunk makes the whole frame fail to reassemble, which looks like stutter
	# or a frozen/black screen.
	var bind_err := udp_client.bind(_udp_port, "*", 2 * 1024 * 1024)
	if bind_err != OK:
		push_error("[Network] Failed to bind UDP port %d (error %d) — no video will be received. Is another client (or the host on this machine) using it?" % [_udp_port, bind_err])

	# Send HELLO message
	var hello := PackedByteArray()
	hello.resize(33)  # 1 byte version + 32 bytes name
	hello[0] = PROTOCOL_VERSION
	var name_bytes := "Immersive-2 VR".to_utf8_buffer()
	for i in range(min(name_bytes.size(), 32)):
		hello[1 + i] = name_bytes[i]

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
	var header := PackedByteArray()
	header.resize(5)
	header[0] = msg_type
	header.encode_u32(1, payload.size())

	tcp_client.put_data(header)
	tcp_client.put_data(payload)

func _read_tcp_messages() -> void:
	# Leer todos los bytes disponibles y guardarlos en el buffer seguro
	var avail: int = tcp_client.get_available_bytes()
	if avail > 0:
		var data := tcp_client.get_data(avail)
		if data[0] == OK:
			_tcp_buffer.append_array(data[1])

	# Procesar mensajes completos
	while _tcp_buffer.size() >= 5:
		var msg_type: int = _tcp_buffer[0]
		var msg_length: int = _tcp_buffer.decode_u32(1)

		# Filtro de seguridad
		if msg_length > 1048576:
			print("[Network] Rejecting oversized message: %d bytes" % msg_length)
			disconnect_from_server() # Evita bucles infinitos
			return

		# Si el buffer aún no tiene el mensaje completo, esperamos al siguiente fotograma
		if _tcp_buffer.size() < 5 + msg_length:
			return

		var payload := _tcp_buffer.slice(5, 5 + msg_length)
		# Avanzar el buffer eliminando el mensaje ya procesado
		_tcp_buffer = _tcp_buffer.slice(5 + msg_length)

		_handle_control_message(msg_type, payload)

func _handle_control_message(msg_type: int, payload: PackedByteArray) -> void:
	match msg_type:
		MSG_HELLO_ACK:
			if payload.size() >= 4:
				var version: int = payload[0]
				var udp_port: int = payload.decode_u16(1)
				var monitor_count: int = payload[3]
				print("[Network] HELLO_ACK: version=%d udp_port=%d monitors=%d" %
					[version, udp_port, monitor_count])

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
						"name": payload.slice(offset + 6, offset + 70).get_string_from_utf8()
					}
					monitors.append(mon)
					offset += 70
				monitor_list_received.emit(monitors)

		MSG_STREAM_START:
			if payload.size() >= 6:
				var monitor_id: int = payload[0]
				_stream_width = payload.decode_u16(1)
				_stream_height = payload.decode_u16(3)
				var codec: int = payload[5]
				print("[Network] STREAM_START: monitor=%d %dx%d codec=%d" %
					[monitor_id, _stream_width, _stream_height, codec])
				stream_started.emit(monitor_id, _stream_width, _stream_height, codec)

		MSG_STREAM_STOP:
			var stopped_monitor: int = payload[0] if payload.size() >= 1 else -1
			print("[Network] STREAM_STOP monitor=%d" % stopped_monitor)
			# Drop pending chunks of that monitor (or all if unknown)
			for key in _frame_buffer.keys():
				if stopped_monitor < 0 or _frame_buffer[key]["monitor_id"] == stopped_monitor:
					_frame_buffer.erase(key)
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

		MSG_PING:
			# Echo back
			_send_control_message(MSG_PING, PackedByteArray())

# --- Internal UDP handling ---

func _read_udp_packets() -> void:
	# DEBUG: reporte una vez por segundo
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _dbg_last_report_ms >= 1000:
		_dbg_last_report_ms = now_ms
		print("[DBG-NET] udp_pkts/s=%d frames/s=%d dropped_incompletos/s=%d ultimo_frame_bytes=%d buffer_pendiente=%d" %
			[_dbg_packets, _dbg_frames, _dbg_dropped, _dbg_last_bytes, _frame_buffer.size()])
		_dbg_packets = 0
		_dbg_frames = 0
		_dbg_dropped = 0

	while udp_client.get_available_packet_count() > 0:
		var packet: PackedByteArray = udp_client.get_packet()
		if packet.size() < VIDEO_HEADER_SIZE:
			continue
		_dbg_packets += 1

		# Parse video packet header
		var monitor_id: int = packet[0]
		var frame_num: int = packet.decode_u32(1)
		var chunk_idx: int = packet.decode_u16(5)
		var chunk_cnt: int = packet.decode_u16(7)
		var chunk_data: PackedByteArray = packet.slice(VIDEO_HEADER_SIZE)

		# Validate chunk index to avoid corrupting the frame buffer
		if frame_num < 0 or chunk_idx < 0 or chunk_idx >= chunk_cnt:
			continue

		# Store chunk in frame buffer (key combines monitor and frame number
		# so simultaneous monitor streams cannot collide)
		var frame_key: int = (monitor_id << 32) | frame_num
		if not _frame_buffer.has(frame_key):
			_frame_buffer[frame_key] = {
				"chunks": {},
				"total": chunk_cnt,
				"monitor_id": monitor_id,
				"frame_num": frame_num
			}

		_frame_buffer[frame_key]["chunks"][chunk_idx] = chunk_data

		# Check if frame is complete
		if _frame_buffer[frame_key]["chunks"].size() == chunk_cnt:
			_assemble_frame(frame_key)

			# Clean up old frames periodically
			_cleanup_old_frames(monitor_id, frame_num)

func _assemble_frame(frame_key: int) -> void:
	var frame_info: Dictionary = _frame_buffer[frame_key]
	var total: int = frame_info["total"]
	var monitor_id: int = frame_info["monitor_id"]
	var frame_num: int = frame_info["frame_num"]

	# Concatenate chunks in order
	var frame_data := PackedByteArray()
	for i in range(total):
		if frame_info["chunks"].has(i):
			frame_data.append_array(frame_info["chunks"][i])

	_dbg_frames += 1
	_dbg_last_bytes = frame_data.size()
	video_frame_received.emit(monitor_id, frame_data, _stream_width, _stream_height)
	_frame_buffer.erase(frame_key)

	# Acknowledge so the host's flow control can drop frames when we lag
	send_frame_ack(monitor_id, frame_num)

func _cleanup_old_frames(monitor_id: int, current_frame: int) -> void:
	# Remove incomplete frames of this monitor older than 30 frames ago
	# (increased from 10 to reduce chance of dropping late-arriving chunks)
	var keys_to_remove: Array = []
	for key in _frame_buffer.keys():
		if _frame_buffer[key]["monitor_id"] == monitor_id and \
				_frame_buffer[key]["frame_num"] < current_frame - 30:
			keys_to_remove.append(key)
	for key in keys_to_remove:
		_dbg_dropped += 1
		_frame_buffer.erase(key)

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

## Send stream quality settings. The host restarts active streams to apply.
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

## Send a frame acknowledgement.
func send_frame_ack(monitor_id: int, frame_number: int) -> void:
	var payload := PackedByteArray()
	payload.resize(5)
	payload[0] = monitor_id
	payload.encode_u32(1, frame_number)
	_send_control_message(MSG_FRAME_ACK, payload)

## Send a latency probe (probe_id + client_timestamp, each 8 bytes LE).
func send_latency_probe(probe_id: int, client_timestamp_us: int) -> void:
	var payload := PackedByteArray()
	payload.resize(16)
	payload.encode_u64(0, probe_id)
	payload.encode_u64(8, client_timestamp_us)
	_send_control_message(MSG_LATENCY_PROBE, payload)

func disconnect_from_server() -> void:
	_connected = false
	_tcp_buffer.clear()
	_frame_buffer.clear()
	tcp_client.disconnect_from_host()
	udp_client.close()
	set_process(false)

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
signal stream_started(monitor_id: int, width: int, height: int)
## Emitted when a complete video frame is received.
signal video_frame_received(frame_data: PackedByteArray, width: int, height: int)

# --- Constants (matching protocol.h) ---

const MSG_HELLO: int          = 0x01
const MSG_HELLO_ACK: int      = 0x02
const MSG_MONITOR_LIST: int   = 0x03
const MSG_MONITOR_SELECT: int = 0x04
const MSG_STREAM_START: int   = 0x05
const MSG_STREAM_STOP: int    = 0x06
const MSG_INPUT_MOUSE: int    = 0x10
const MSG_INPUT_KEYBOARD: int = 0x11
const MSG_INPUT_POINTER: int  = 0x12
const MSG_PING: int           = 0xFF

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

func _ready() -> void:
	set_process(false)

## Connect to the Immersive-2 host.
func connect_to_server(ip: String, tcp_port: int, udp_port: int) -> void:
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
				disconnected_from_host.emit()
				set_process(false)
				print("[Network] Disconnected")

	# Read UDP video packets
	if _connected:
		_read_udp_packets()

func _on_tcp_connected() -> void:
	print("[Network] TCP connected, sending HELLO")

	# Bind UDP for receiving video
	udp_client.bind(_udp_port)

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
func send_mouse_input(monitor_id: int, x: int, y: int, buttons: int, scroll: int) -> void:
	var payload := PackedByteArray()
	payload.resize(8)
	payload[0] = monitor_id
	payload.encode_u16(1, x)
	payload.encode_u16(3, y)
	payload[5] = buttons
	payload.encode_s16(6, scroll)
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
	while tcp_client.get_available_bytes() >= 5:
		# Read header (5 bytes: 1 type + 4 length)
		var header_data := tcp_client.get_data(5)
		if header_data[0] != OK:
			return
		var header: PackedByteArray = header_data[1]
		var msg_type: int = header[0]
		var msg_length: int = header.decode_u32(1)

		# Sanity check: reject unreasonably large messages (> 1 MB)
		if msg_length > 1048576:
			print("[Network] Rejecting oversized message: %d bytes" % msg_length)
			return

		# Read payload
		if msg_length > 0:
			if tcp_client.get_available_bytes() < msg_length:
				return  # Wait for more data
			var payload_data := tcp_client.get_data(msg_length)
			if payload_data[0] != OK:
				return
			_handle_control_message(msg_type, payload_data[1])
		else:
			_handle_control_message(msg_type, PackedByteArray())

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
				stream_started.emit(monitor_id, _stream_width, _stream_height)

		MSG_STREAM_STOP:
			print("[Network] STREAM_STOP")

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

		# Store chunk in frame buffer
		var frame_key: int = frame_num
		if not _frame_buffer.has(frame_key):
			_frame_buffer[frame_key] = {
				"chunks": {},
				"total": chunk_cnt,
				"monitor_id": monitor_id
			}

		_frame_buffer[frame_key]["chunks"][chunk_idx] = chunk_data

		# Check if frame is complete
		if _frame_buffer[frame_key]["chunks"].size() == chunk_cnt:
			_assemble_frame(frame_key)

			# Clean up old frames
			_cleanup_old_frames(frame_num)

func _assemble_frame(frame_key: int) -> void:
	var frame_info: Dictionary = _frame_buffer[frame_key]
	var total: int = frame_info["total"]

	# Concatenate chunks in order
	var frame_data := PackedByteArray()
	for i in range(total):
		if frame_info["chunks"].has(i):
			frame_data.append_array(frame_info["chunks"][i])

	video_frame_received.emit(frame_data, _stream_width, _stream_height)
	_frame_buffer.erase(frame_key)

func _cleanup_old_frames(current_frame: int) -> void:
	# Remove frames older than 10 frames ago
	var keys_to_remove: Array = []
	for key in _frame_buffer.keys():
		if key < current_frame - 10:
			keys_to_remove.append(key)
	for key in keys_to_remove:
		_frame_buffer.erase(key)

func disconnect_from_server() -> void:
	tcp_client.disconnect_from_host()
	udp_client.close()
	_connected = false
	set_process(false)

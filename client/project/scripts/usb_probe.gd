## Finds the PC at the other end of a USB cable.
##
## The host keeps `adb reverse` armed on a headset plugged into it, which makes
## the PC answer on the headset's own 127.0.0.1:<port>. While enabled, this
## connects there every couple of seconds and says HELLO: a HELLO_ACK means
## the tunnel is up and reaches a running host. (No tunnel: the connect is
## refused at once. Tunnel but no host: adbd accepts, then hangs up.)

extends Node
class_name UsbProbe

## One check finished; found = a host answered through the cable.
signal checked(found: bool)

const NetworkClient := preload("res://scripts/network_client.gd")
const INTERVAL_MS := 2000
const TIMEOUT_MS := 1500
## A host that refused us (full): don't knock again every two seconds.
const REFUSED_WAIT_MS := 30000

var port: int = 19800

var _tcp: StreamPeerTCP = null
var _sent := false
var _deadline_ms := 0
var _next_ms := 0

func _ready() -> void:
	set_process(false)

## Probe or stop probing. Cheap to call every frame.
func set_enabled(on: bool) -> void:
	if on == is_processing():
		return
	set_process(on)
	if not on and _tcp:
		_tcp.disconnect_from_host()
		_tcp = null

## No check before `ms` from now.
func hold(ms: int) -> void:
	_next_ms = max(_next_ms, Time.get_ticks_msec() + ms)

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _tcp == null:
		if now < _next_ms:
			return
		_tcp = StreamPeerTCP.new()
		_sent = false
		_deadline_ms = now + TIMEOUT_MS
		if _tcp.connect_to_host("127.0.0.1", port) != OK:
			_finish(false, INTERVAL_MS)
		return
	_tcp.poll()
	match _tcp.get_status():
		StreamPeerTCP.STATUS_CONNECTING:
			pass
		StreamPeerTCP.STATUS_CONNECTED:
			if not _sent:
				_tcp.put_data(NetworkClient.hello_message(true, 0, " USB check"))
				_sent = true
			if _tcp.get_available_bytes() > 0:
				# The first message's type: HELLO_ACK or HELLO_REJECT.
				var ok := _tcp.get_u8() == NetworkClient.MSG_HELLO_ACK
				_finish(ok, INTERVAL_MS if ok else REFUSED_WAIT_MS)
				return
		_:
			_finish(false, INTERVAL_MS)
			return
	if now > _deadline_ms:
		_finish(false, INTERVAL_MS)

func _finish(found: bool, wait_ms: int) -> void:
	_tcp.disconnect_from_host()
	_tcp = null
	_next_ms = Time.get_ticks_msec() + wait_ms
	checked.emit(found)

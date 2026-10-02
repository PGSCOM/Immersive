## LAN discovery of Immersive-2 hosts.
##
## While running, broadcasts a DiscoveryRequest ("IM2?", protocol.h) to UDP
## <tcp_port> every couple of seconds and collects the hosts' unicast
## DiscoveryReply ("IM2!"), so the headset can list PCs instead of asking for
## an IP. Only sends broadcasts and reads replies, so Android needs no
## multicast lock.

extends Node
class_name HostDiscovery

## The list changed (a host appeared, went quiet, or renamed).
signal hosts_changed(hosts: Array)

const REQUEST_MAGIC := 0x3F324D49  # "IM2?"
const REPLY_MAGIC := 0x21324D49    # "IM2!"
const FLAG_PIN := 0x01
const FLAG_VIEW_ONLY := 0x02
const PROBE_INTERVAL_MS := 2000
## A host that stops answering drops off the list after this long.
const FORGET_AFTER_MS := 7000

var port: int = 19800

var _udp := PacketPeerUDP.new()
var _running := false
var _next_probe_ms := 0
## "name:port" -> {ip, name, port, monitors, pin_required, seen_ms}
var _hosts: Dictionary = {}

func _ready() -> void:
	set_process(_running)  # start() may run before the node is ready

func _exit_tree() -> void:
	stop()

func start() -> void:
	if _running:
		return
	if _udp.bind(0) != OK:
		push_warning("[Discovery] Cannot open a UDP socket; enter the PC's IP instead")
		return
	_udp.set_broadcast_enabled(true)
	_running = true
	_next_probe_ms = 0
	set_process(true)

func stop() -> void:
	if not _running:
		return
	_running = false
	_udp.close()
	set_process(false)

func is_running() -> bool:
	return _running

## Hosts currently answering, sorted by name.
func get_hosts() -> Array:
	var list := _hosts.values()
	list.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	return list

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if now >= _next_probe_ms:
		_next_probe_ms = now + PROBE_INTERVAL_MS
		_probe()
	var changed := false
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		changed = _on_reply(pkt, _udp.get_packet_ip(), now) or changed
	for key in _hosts.keys():
		if now - int(_hosts[key].seen_ms) > FORGET_AFTER_MS:
			_hosts.erase(key)
			changed = true
	if changed:
		hosts_changed.emit(get_hosts())

func _probe() -> void:
	var req := PackedByteArray()
	req.resize(5)
	req.encode_u32(0, REQUEST_MAGIC)
	req[4] = 1  # protocol version
	for addr in _broadcast_targets():
		_udp.set_dest_address(addr, port)
		_udp.put_packet(req)

## 255.255.255.255 plus each private interface's /24 broadcast (some Wi-Fi
## stacks drop the limited broadcast), plus loopback for a host on this PC.
func _broadcast_targets() -> Array:
	var targets := ["255.255.255.255", "127.0.0.1"]
	for ip in IP.get_local_addresses():
		if ip.count(".") != 3 or ip.begins_with("127."):
			continue
		if ip.begins_with("10.") or ip.begins_with("192.168.") or _is_172_private(ip):
			var parts: PackedStringArray = ip.split(".")
			var bcast := "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]
			if not targets.has(bcast):
				targets.append(bcast)
	return targets

static func _is_172_private(ip: String) -> bool:
	if not ip.begins_with("172."):
		return false
	var second := int(ip.get_slice(".", 1))
	return second >= 16 and second <= 31

## Returns true when the list changed.
func _on_reply(pkt: PackedByteArray, ip: String, now: int) -> bool:
	if pkt.size() < 73 or pkt.decode_u32(0) != REPLY_MAGIC:
		return false
	var host := {
		"ip": ip,
		"port": pkt.decode_u16(5),
		"monitors": pkt[7],
		"pin_required": (pkt[8] & FLAG_PIN) != 0,
		"view_only": (pkt[8] & FLAG_VIEW_ONLY) != 0,
		"name": pkt.slice(9, 73).get_string_from_utf8(),
		"seen_ms": now,
	}
	if host.name.is_empty():
		host.name = ip
	# One PC answers on every address it has (LAN and loopback when it is
	# this machine): list it once, preferring loopback, which needs no PIN.
	var key := "%s:%d" % [host.name, host.port]
	var old: Dictionary = _hosts.get(key, {})
	if not old.is_empty() and old.ip.begins_with("127.") and not ip.begins_with("127."):
		old.seen_ms = now
		return false
	_hosts[key] = host
	return old.is_empty() or old.ip != ip or old.pin_required != host.pin_required

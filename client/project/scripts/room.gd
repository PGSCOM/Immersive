## A multiplayer room: headsets that see each other's avatars, hear each
## other and watch the screens each one chooses to share.
##
## No server anywhere. One headset opens the room (ENet on UDP `port`; it also
## answers LAN discovery on `port` + 1, so the others find it in a list) and
## relays between the rest, who join with its address and the room's six-digit
## PIN (SceneMultiplayer authentication; five wrong ones lock an address out
## for a minute). Everything in the room is encrypted (DTLS, a self-signed
## certificate made once per run): nobody else on the network reads the PIN,
## the voices or how to watch someone's PC. The certificate is not checked
## (there is nothing to check it against), so it keeps out who listens, not
## someone who sits between us and the room. Through the room go each person's profile (name, microphone,
## how to watch their PC and where their shared screens hang), their pose
## (head and hands relative to their XROrigin3D, POSE_HZ) and their voice
## (16 kHz mono PCM in 20 ms packets, only while louder than a noise gate).
## Our whiteboard goes too: where it hangs and who may draw on it (in the
## profile), and every stroke as it is drawn (`ink` ops with their author,
## reliable). Whoever sees it for the first time (joins while it is shown, or
## is there when we show it) gets it as it is now (Whiteboard.snapshot(), not
## its history). Someone we let draw sends their ops to us (`_draw_on`) and we
## pass them on; ops we refuse (they may not, or no more) get them our board
## as it is, so their copy drops what we did not take. What we see and hear of
## each person, who draws on our board and who may watch our screens is up to
## us (pref(), the menu's Permissions page; this session only).
## The screens never go through the room: each PC streams them straight to the
## headsets that watch it (Participant, protocol.h WatchCode). How to watch
## ours (the code) goes only to whom we let (_profile_for()), and a new code
## replaces it whenever one of them should not watch any more (watch_revoked).
##
## Everything is in the room frame (this node's, i.e. the world), not the
## tracking origin: walking (main.gd moves XROrigin3D) carries us towards the
## others, and they see us come. Seats: everyone in one row, ordered by peer
## id, SEAT_SPACING_M apart and facing the same way (each person's world laid
## beside the others), so whoever is on my right sees me on their left.

extends Node3D
class_name Room

## State, people, a notice or what someone is doing changed (main.gd
## refreshes the menu).
signal changed
## Rooms answering on this network: HostDiscovery entries (ip, port, name,
## and the number of people in `monitors`).
signal rooms_found(rooms: Array)
## A voice packet from someone (client/tests/room_bot.gd repeats them).
signal voice_heard(peer_id: int, pcm: PackedByteArray)
## Someone who may know how to watch our PC should not any more: they left,
## or we turned off their "Sees my screens". main.gd gives the PC a new
## watch code (which drops every watcher) and tells it only to the others.
signal watch_revoked(peer_id: int)

enum State { OFF, JOINING, IN }

const PORT := 19820
const MAX_PEOPLE := 8
const POSE_HZ := 30.0
const SEAT_SPACING_M := 3.2
const JOIN_TIMEOUT_MS := 8000
const VOICE_RATE := 16000
const VOICE_CHUNK := 320           ## 20 ms
## A chunk louder than this (RMS) opens the gate; it stays open GATE_HOLD_S,
## so the ends of words are not clipped.
const GATE_RMS := 0.012
const GATE_HOLD_S := 0.35
const MIC_BUS := "RoomMic"
## The name in the room's certificate (DTLS); joiners do not check it.
const TLS_NAME := "immersive-room"

var state := State.OFF
var is_host := false
var port := PORT
var pin := 0
## The room's address: what others type to join (ours, when we host it).
var address := ""
var my_name := "Someone"
var mic_on := true
## The last thing worth telling the person ("" = nothing): could not open,
## wrong PIN, the room closed.
var notice := ""
## Where our voice comes from: "mic", "tone" (440 Hz, --im2-tone, tests) or
## "" (none: --im2-no-mic; a test bot speaks with say()).
var voice_from := "mic"
## Voice packets sent, for the test harness.
var voice_out := 0
## Everyone who joins may draw on our whiteboard (--im2-board-open: tests, the bot).
var open_board := false

var _origin: Node3D = null
var _camera: Node3D = null
var _controllers: Array = []
var _peer: ENetMultiplayerPeer = null
var _people := {}                  ## peer id -> Participant
var _profile := {"name": "", "mic": true, "share": {}, "screens": [], "board": {}}
## Our own whiteboard (main.gd's): guests' ink is replayed on it.
var board: Whiteboard = null
## Peer id -> true: they have our board (a snapshot, then every op).
var _synced := {}
## Peer id -> true: we refused their ink, they get our board again soon.
var _resync := {}
var _resync_s := 0.0
const RESYNC_S := 0.5
## Our own ink not sent yet (queue_ink).
var _ink_out: Array = []
## Peer id -> {board, screens, voice: what we see / hear of them; draw: they
## may draw on our board}. Missing = the default (see pref()).
var _prefs := {}
## Our board's placement as main.gd last gave it (the guests are added to it).
var _board_place := {}
const INK_BATCH := 2000
## The author of a board owner's own ink: never a peer id (those start at 1).
const OWNER := 0
var _join_deadline_ms := 0
var _pose_s := 0.0
var _summary_s := 0.0
var _last_summary := ""
var _disc: PacketPeerUDP = null    ## answers LAN discovery while we host
var _finder: HostDiscovery = null  ## finds rooms while we are in none
var _failures := {}                ## address -> {n, until}: wrong PINs
## The room's DTLS key and certificate, made the first time we open one.
static var _tls_key: CryptoKey = null
static var _tls_cert: X509Certificate = null

# Microphone: captured on a muted bus, mixed to mono, box-filtered down to
# VOICE_RATE, gated, and sent VOICE_CHUNK samples at a time.
var _mic: AudioStreamPlayer = null
var _capture: AudioEffectCapture = null
var _mic_buf := PackedFloat32Array()
var _acc := 0.0
var _acc_n := 0
var _phase := 0.0
var _gate_s := 0.0
var _tone_t := 0.0
var _tone_due := 0.0

func _ready() -> void:
	var mp := multiplayer as SceneMultiplayer
	mp.auth_callback = _on_auth
	mp.auth_timeout = 5.0
	mp.peer_authenticating.connect(_on_authenticating)
	mp.peer_connected.connect(_on_peer_connected)
	mp.peer_disconnected.connect(_on_peer_disconnected)
	mp.connected_to_server.connect(_on_joined)
	mp.connection_failed.connect(func(): leave.call_deferred("No room answered at %s." % address))
	mp.server_disconnected.connect(func(): leave.call_deferred("The room closed: the headset that opened it left."))
	get_tree().on_request_permissions_result.connect(func(permission: String, granted: bool):
		if granted and permission.ends_with("RECORD_AUDIO"):
			_update_mic())
	_finder = HostDiscovery.new()
	_finder.name = "RoomFinder"
	add_child(_finder)
	_finder.hosts_changed.connect(func(rooms: Array): rooms_found.emit(rooms))

## Where poses come from: the tracking origin, the head and both controllers.
func setup(origin: Node3D, camera: Node3D, left: Node3D, right: Node3D) -> void:
	_origin = origin
	_camera = camera
	_controllers = [left, right]

func _exit_tree() -> void:
	leave()

func _process(delta: float) -> void:
	_answer_discovery()
	_flush_ink()
	if state == State.JOINING and Time.get_ticks_msec() > _join_deadline_ms:
		leave("No room answered at %s." % address)
	if state != State.IN:
		return
	_seat_people()
	_capture_voice(delta)
	_resync_s += delta
	if _resync_s >= RESYNC_S and not _resync.is_empty():
		_resync_s = 0.0
		for id in _resync:
			if _people.has(id):
				_sync_board(id)
		_resync.clear()
	_pose_s += delta
	if _pose_s >= 1.0 / POSE_HZ and not _people.is_empty() and _origin and _camera:
		_pose_s = 0.0
		_take_pose.rpc(_my_pose())
	_summary_s += delta
	if _summary_s >= 0.25:
		_summary_s = 0.0
		var now := str(people())
		if now != _last_summary:
			_last_summary = now
			changed.emit()

# ---------------------------------------------------------------------------
# Open, join, leave
# ---------------------------------------------------------------------------

## Open a room here. with_pin: a fixed PIN (tests); 0 = a new random one.
func open(at_port: int = PORT, with_pin: int = 0) -> bool:
	leave()
	_peer = ENetMultiplayerPeer.new()
	if _peer.create_server(at_port, MAX_PEOPLE - 1) != OK:
		_peer = null
		_say("Could not open a room: UDP port %d is in use on this headset." % at_port)
		return false
	if _peer.host.dtls_server_setup(_tls_server()) != OK:
		_peer.close()
		_peer = null
		_say("Could not open a room: encryption (DTLS) is not available here.")
		return false
	is_host = true
	port = at_port
	pin = with_pin if with_pin >= 100000 else random_pin()
	address = lan_address()
	multiplayer.multiplayer_peer = _peer
	_disc = PacketPeerUDP.new()
	if _disc.bind(port + 1) != OK:
		_disc = null  # another room on this machine answers there; the address still works
	print("[Room] opened on UDP %d (%s), PIN %d" % [port, address, pin])
	_enter(State.IN)
	return true

func join(ip: String, at_port: int, with_pin: int) -> void:
	leave()
	_peer = ENetMultiplayerPeer.new()
	if _peer.create_client(ip, at_port) != OK \
			or _peer.host.dtls_client_setup(TLS_NAME, TLSOptions.client_unsafe()) != OK:
		_peer = null
		_say("Could not reach %s." % ip)
		return
	is_host = false
	port = at_port
	pin = with_pin
	address = ip
	multiplayer.multiplayer_peer = _peer
	_join_deadline_ms = Time.get_ticks_msec() + JOIN_TIMEOUT_MS
	print("[Room] joining %s:%d" % [ip, at_port])
	_enter(State.JOINING)

## Leave (or, hosting, close) the room. `why`: the notice to show.
func leave(why: String = "") -> void:
	if why:
		print("[Room] %s" % why)
	if _peer:
		_peer.close()
		_peer = null
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if _disc:
		_disc.close()
		_disc = null
	for p in _people.values():
		p.queue_free()
	_people.clear()
	_synced.clear()
	_resync.clear()
	is_host = false
	if why or state != State.OFF:
		_say(why)
	_enter(State.OFF)

func _enter(s: State) -> void:
	state = s
	_profile.name = my_name
	_profile.mic = mic_on
	_update_mic()
	changed.emit()

func _say(text: String) -> void:
	notice = text
	changed.emit()

## Look for rooms on the network (only while in none): the menu's Room tab.
func look_for_rooms(on: bool) -> void:
	on = on and state == State.OFF
	if on == _finder.is_running():
		return
	if on:
		_finder.port = port + 1
		_finder.start()
	else:
		_finder.stop()

## A room PIN: six digits from the system's random source (not randi(), whose
## state other outputs could give away).
static func random_pin() -> int:
	return 100000 + Crypto.new().generate_random_bytes(4).decode_u32(0) % 900000

## A watch code (protocol.h WatchCode): 1 to 2^31-1, from the same source.
static func random_code() -> int:
	var code := 0
	while code == 0:
		code = Crypto.new().generate_random_bytes(4).decode_u32(0) & 0x7FFFFFFF
	return code

## The DTLS server side: an RSA key and a self-signed certificate, made the
## first time a room opens in this run (a moment's work) and kept until quit.
static func _tls_server() -> TLSOptions:
	if _tls_key == null:
		var crypto := Crypto.new()
		_tls_key = crypto.generate_rsa(2048)
		_tls_cert = crypto.generate_self_signed_certificate(_tls_key, "CN=%s" % TLS_NAME)
	return TLSOptions.server(_tls_key, _tls_cert)

## This headset's address on the local network, for others to type.
static func lan_address() -> String:
	var best := ""
	var rank := 9
	for ip: String in IP.get_local_addresses():
		if ip.count(".") != 3 or ip.begins_with("127.") or ip.begins_with("169.254."):
			continue
		var r := 0 if ip.begins_with("192.168.") else 1 if ip.begins_with("10.") \
			else 2 if HostDiscovery._is_172_private(ip) else 3
		if r < rank:
			best = ip
			rank = r
	return best

# ---------------------------------------------------------------------------
# Peers
# ---------------------------------------------------------------------------

## Joining: show the PIN and trust the room. Hosting: wait for theirs (_on_auth).
func _on_authenticating(id: int) -> void:
	if id == 1 and not is_host:
		var mp := multiplayer as SceneMultiplayer
		var d := PackedByteArray()
		d.resize(4)
		d.encode_u32(0, pin)
		mp.send_auth(1, d)
		mp.complete_auth(1)

func _on_auth(id: int, data: PackedByteArray) -> void:
	var mp := multiplayer as SceneMultiplayer
	if not is_host:
		if id == 1 and data == PackedByteArray([0]):
			leave.call_deferred("Wrong PIN for the room at %s." % address)
		return
	var ip := _peer.get_peer(id).get_remote_address() if _peer else ""
	var f: Dictionary = _failures.get(ip, {"n": 0, "until": 0})
	var now := Time.get_ticks_msec()
	if now >= int(f.until) and data.size() == 4 and data.decode_u32(0) == pin:
		_failures.erase(ip)
		mp.complete_auth(id)
		return
	f.n += 1
	if f.n >= 5:
		f = {"n": 0, "until": now + 60000}
	_failures[ip] = f
	print("[Room] %s gave a wrong PIN" % ip)
	# It leaves on this; one that does not is dropped at auth_timeout.
	mp.send_auth(id, PackedByteArray([0]))

func _on_joined() -> void:
	print("[Room] joined the room at %s" % address)
	_say("")
	_enter(State.IN)

func _on_peer_connected(id: int) -> void:
	var p := Participant.new()
	p.peer_id = id
	p.name = "Person%d" % id
	add_child(p)
	_people[id] = p
	_retone()
	if open_board:
		_prefs[id] = {"draw": true}
		_publish_board()
	p.set_seen(pref(id, "board"), pref(id, "screens"), pref(id, "voice"))
	_take_profile.rpc_id(id, _profile_for(id))
	if board and board.visible:
		_sync_board(id)
	changed.emit()

func _on_peer_disconnected(id: int) -> void:
	var p: Participant = _people.get(id)
	if p:
		print("[Room] %s left" % p.display_name)
		p.queue_free()
	_people.erase(id)
	_synced.erase(id)
	_resync.erase(id)
	_retone()
	if pref(id, "draw"):
		_prefs.erase(id)
		_publish_board()
	watch_revoked.emit(id)  # they still know the code
	changed.emit()

@rpc("any_peer", "call_remote", "reliable")
func _take_profile(p: Dictionary) -> void:
	var who: Participant = _people.get(multiplayer.get_remote_sender_id())
	if who:
		var first := who.display_name == "…"
		who.set_profile(p)
		if first:
			print("[Room] %s is here" % who.display_name)
		changed.emit()

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _take_pose(d: PackedFloat32Array) -> void:
	var who: Participant = _people.get(multiplayer.get_remote_sender_id())
	if who:
		who.set_pose(d)

## Ink on the sender's board: [[author, op], …].
@rpc("any_peer", "call_remote", "reliable", 3)
func _take_ink(inked: Array) -> void:
	var who: Participant = _people.get(multiplayer.get_remote_sender_id())
	if who:
		who.apply_ink(inked)

## The sender's board as it is now (Whiteboard.snapshot()), in batches; the
## first one empties our copy first.
@rpc("any_peer", "call_remote", "reliable", 3)
func _take_board(inked: Array, first: bool) -> void:
	var who: Participant = _people.get(multiplayer.get_remote_sender_id())
	if who:
		who.apply_board(inked, first)

## Our board as it is now, to `id` (same channel as the ops: they follow it).
func _sync_board(id: int) -> void:
	if board == null:
		return
	_flush_ink()  # to the others; this snapshot has it
	var snap := board.snapshot()
	_take_board.rpc_id(id, snap.slice(0, INK_BATCH), true)
	for i in range(INK_BATCH, snap.size(), INK_BATCH):
		_take_board.rpc_id(id, snap.slice(i, i + INK_BATCH), false)
	_synced[id] = true

## A guest's ink on OUR board: drawn here if we let them, then passed on to
## everyone else who has our board (the guest drew it on their copy already).
## Refused (they may not draw, or no more): they get our board as it is, so
## the strokes we did not take leave their copy too.
@rpc("any_peer", "call_remote", "reliable", 3)
func _draw_on(ops: Array) -> void:
	var from := multiplayer.get_remote_sender_id()
	if board == null or not _people.has(from):
		return
	if not pref(from, "draw"):
		_resync[from] = true
		return
	var inked := []
	for op in ops.slice(0, INK_BATCH):
		if board.apply_ink(op, from):
			inked.append([from, op])
	if inked.is_empty():
		return
	for id in _synced:
		if id != from:
			_take_ink.rpc_id(id, inked)

## Ink we drew on someone else's board (Participant): to its owner.
func draw_on(owner_id: int, ops: Array) -> void:
	if state == State.IN and _people.has(owner_id):
		_draw_on.rpc_id(owner_id, ops)

@rpc("any_peer", "call_remote", "unreliable_ordered", 2)
func _take_voice(pcm: PackedByteArray) -> void:
	var who: Participant = _people.get(multiplayer.get_remote_sender_id())
	if who:
		who.push_voice(pcm)
		voice_heard.emit(who.peer_id, pcm)

## Send one voice packet (16-bit PCM at VOICE_RATE) as it is, ungated.
func say(pcm: PackedByteArray) -> void:
	if state == State.IN and not _people.is_empty():
		_take_voice.rpc(pcm)
		voice_out += 1

## Everyone's peer id, ours included, in seat order.
func _ids() -> Array:
	var ids: Array = _people.keys()
	ids.append(multiplayer.get_unique_id())
	ids.sort()
	return ids

## Colours follow the seats, so everyone sees the same person in the same one.
func _tone_for(id: int) -> Color:
	return UiTheme.PEOPLE[maxi(_ids().find(id), 0) % UiTheme.PEOPLE.size()]

func _retone() -> void:
	for id in _people:
		_people[id].set_tone(_tone_for(id))

func _seat_people() -> void:
	var ids := _ids()
	var me := ids.find(multiplayer.get_unique_id())
	for id in _people:
		_people[id].global_transform = global_transform * seat(ids.find(id) - me)

## Where someone `slots` seats to our right sits, in our room frame.
static func seat(slots: int) -> Transform3D:
	return Transform3D(Basis(), Vector3(slots * SEAT_SPACING_M, 0.0, 0.0))

# ---------------------------------------------------------------------------
# What we tell the room
# ---------------------------------------------------------------------------

func set_display_name(n: String) -> void:
	n = n.strip_edges().left(32)
	if n.is_empty() or n == my_name:
		return
	my_name = n
	_profile.name = n
	_publish()

func set_mic(on: bool) -> void:
	mic_on = on
	_profile.mic = on
	_update_mic()
	_publish()

## How to watch our PC ({ip, port, code}; {} = we do not share).
func set_share(share: Dictionary) -> void:
	if share != _profile.share:
		_profile.share = share
		_publish()

## Where our shared screens hang: [{id, x: 12 floats (basis columns, origin,
## in the room frame), w: metres wide, c: curvature 0-1}].
func set_screens(screens: Array) -> void:
	if screens != _profile.screens:
		_profile.screens = screens
		_publish()

## Where our whiteboard hangs: {on, x: 12 floats in the room frame, w}.
## Shown, it goes to whoever does not have it yet.
func set_board(place: Dictionary) -> void:
	_board_place = place
	_publish_board()
	if place.get("on", false) == true and state == State.IN:
		for id in _people:
			if not _synced.has(id):
				_sync_board(id)

## The placement plus who may draw on it ("guests": peer ids).
func _publish_board() -> void:
	var b := _board_place.duplicate()
	b["guests"] = _prefs.keys().filter(func(id): return pref(id, "draw"))
	if b != _profile.board:
		_profile.board = b
		_publish()

## A change we made to our whiteboard (Whiteboard.ink), sent with the others
## of this frame (_flush_ink).
func queue_ink(op: Array) -> void:
	_ink_out.append(op)

## Our queued ink to everyone who has our board (the others get a snapshot
## when they first see it, which has it already: a snapshot always flushes
## first). Outside a room it is dropped. Its author is OWNER (0), not our
## peer id: the room host's copy of our board would skip ops under its own
## id, 1.
func _flush_ink() -> void:
	if _ink_out.is_empty():
		return
	var inked := _ink_out.map(func(op): return [OWNER, op])
	_ink_out = []
	if state != State.IN or not _peer:
		return
	for id in _synced:
		_take_ink.rpc_id(id, inked)

## What we see and hear of person `id`, whether they may draw on our board
## and watch our screens: "board", "screens", "voice", "watch" (all on unless
## turned off), "draw" (off unless turned on).
func pref(id: int, what: String) -> bool:
	return _prefs.get(id, {}).get(what, what != "draw")

func set_pref(id: int, what: String, on: bool) -> void:
	if not _prefs.has(id):
		_prefs[id] = {}
	_prefs[id][what] = on
	var p: Participant = _people.get(id)
	if p:
		p.set_seen(pref(id, "board"), pref(id, "screens"), pref(id, "voice"))
	if what == "draw":
		_publish_board()
	if what == "watch":
		if not on:
			watch_revoked.emit(id)  # main.gd: a new code, for the others only
		_publish()
	changed.emit()

func sharing() -> bool:
	return not _profile.share.is_empty()

func _publish() -> void:
	if state == State.IN and _peer:
		for id in _people:
			_take_profile.rpc_id(id, _profile_for(id))
	changed.emit()

## Our profile as person `id` gets it: without how to watch our PC unless
## they may ("Sees my screens").
func _profile_for(id: int) -> Dictionary:
	if pref(id, "watch") or _profile.share.is_empty():
		return _profile
	var p := _profile.duplicate()
	p.share = {}
	p.screens = []
	return p

func _my_pose() -> PackedFloat32Array:
	var o := global_transform.affine_inverse()
	return Participant.pack_pose(o * _camera.global_transform, _hand(0, o), _hand(1, o))

## Hand i (0 left, 1 right) in the room frame `o`: the controller while it is
## in use (vr_input.gd: held, not put down), else the bare hand's palm while
## the runtime really tracks it (as hand_input.gd decides), else null (not
## seen). A controller lying on the desk is not the hand: the Pico keeps
## reporting it as tracked.
func _hand(i: int, o: Transform3D) -> Variant:
	var c: XRNode3D = _controllers[i] if i < _controllers.size() else null
	var input: Node = c.get_node_or_null("VRInput") if c else null
	if c and (input.in_use() if input else c.get_has_tracking_data()):
		return o * c.global_transform
	var t := XRServer.get_tracker(&"/user/hand_tracker/left" if i == 0 else &"/user/hand_tracker/right") as XRHandTracker
	if t and _origin and t.has_tracking_data and t.hand_tracking_source in [
			XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED, XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN] \
			and t.get_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID:
		return o * _origin.global_transform * t.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM)
	return null

# ---------------------------------------------------------------------------
# Voice
# ---------------------------------------------------------------------------

## The microphone runs only in a room with it switched on. Android asks for
## the permission first and comes back here once it is granted.
func _update_mic() -> void:
	var want := state == State.IN and mic_on and voice_from == "mic"
	if want and _mic == null:
		if OS.has_feature("android") and not OS.request_permission("RECORD_AUDIO"):
			return
		var bus := AudioServer.get_bus_index(MIC_BUS)
		if bus < 0:
			bus = AudioServer.bus_count
			AudioServer.add_bus(bus)
			AudioServer.set_bus_name(bus, MIC_BUS)
			AudioServer.set_bus_mute(bus, true)  # captured, never played back here
			var cap := AudioEffectCapture.new()
			cap.buffer_length = 0.5
			AudioServer.add_bus_effect(bus, cap)
		_capture = AudioServer.get_bus_effect(bus, 0) as AudioEffectCapture
		_capture.clear_buffer()
		_mic = AudioStreamPlayer.new()
		_mic.stream = AudioStreamMicrophone.new()
		_mic.bus = MIC_BUS
		add_child(_mic)
		_mic.play()
	elif not want and _mic:
		_mic.queue_free()
		_mic = null
		_capture = null
		_mic_buf.clear()
		_gate_s = 0.0

func _capture_voice(delta: float) -> void:
	if voice_from == "tone" and mic_on:
		_tone_due += delta * VOICE_RATE
		for i in int(_tone_due):
			_mic_buf.append(0.25 * sin(TAU * 440.0 * _tone_t))
			_tone_t = fmod(_tone_t + 1.0 / VOICE_RATE, 1.0)
		_tone_due -= int(_tone_due)
	elif _capture:
		var step := AudioServer.get_mix_rate() / VOICE_RATE
		for f in _capture.get_buffer(_capture.get_frames_available()):
			_acc += f.x + f.y
			_acc_n += 2
			_phase += 1.0
			if _phase >= step:
				_phase -= step
				_mic_buf.append(_acc / _acc_n)
				_acc = 0.0
				_acc_n = 0
	while _mic_buf.size() >= VOICE_CHUNK:
		var chunk := _mic_buf.slice(0, VOICE_CHUNK)
		_mic_buf = _mic_buf.slice(VOICE_CHUNK)
		_gate_s = GATE_HOLD_S if rms(chunk) > GATE_RMS \
			else maxf(0.0, _gate_s - float(VOICE_CHUNK) / VOICE_RATE)
		if _gate_s > 0.0 and not _people.is_empty():
			_take_voice.rpc(encode_voice(chunk))
			voice_out += 1

static func rms(samples: PackedFloat32Array) -> float:
	var sum := 0.0
	for v in samples:
		sum += v * v
	return sqrt(sum / maxi(samples.size(), 1))

## Samples in -1..1 as 16-bit little-endian PCM.
static func encode_voice(samples: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(samples.size() * 2)
	for i in samples.size():
		out.encode_s16(i * 2, clampi(roundi(samples[i] * 32767.0), -32768, 32767))
	return out

## 16-bit PCM as the stereo frames an AudioStreamGenerator takes.
static func decode_voice(pcm: PackedByteArray) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pcm.size() / 2)
	for i in out.size():
		var v := pcm.decode_s16(i * 2) / 32768.0
		out[i] = Vector2(v, v)
	return out

# ---------------------------------------------------------------------------
# For the menu and the test harness
# ---------------------------------------------------------------------------

## Who is here, us first: [{id, name, me, host, tone, mic, speaking, screens
## (Participant.watch_state(), or "live" for us while sharing), count,
## and for the others board (they show one), see_board, see_screens, hear,
## draw, watch (see pref()), may_draw (we may draw on theirs)}].
func people() -> Array:
	var me := multiplayer.get_unique_id()
	var out := [{"id": me, "name": my_name, "me": true, "host": is_host, "tone": _tone_for(me),
		"mic": mic_on, "speaking": mic_on and _gate_s > 0.0,
		"screens": "live" if sharing() else "", "count": _profile.screens.size()}]
	for id in _ids():
		if id == me:
			continue
		var p: Participant = _people[id]
		out.append({"id": id, "name": p.display_name, "me": false, "host": id == 1, "tone": p.tone,
			"mic": p.mic_on, "speaking": p.is_speaking(), "screens": p.watch_state(),
			"count": p.remote_panels().size(), "board": p.shows_board(),
			"see_board": pref(id, "board"), "see_screens": pref(id, "screens"),
			"hear": pref(id, "voice"), "draw": pref(id, "draw"), "watch": pref(id, "watch"),
			"may_draw": p.may_draw()})
	return out

## Points on everyone else and what they show (world), so main.gd can tell
## when one of our screens hides them.
func occluder_points() -> Array:
	var out := []
	for p in _people.values():
		out.append_array(p.occluder_points())
	return out

## Everyone else's whiteboard that we see (main.gd::pick()).
func remote_boards() -> Array:
	var out := []
	for p in _people.values():
		if p.board_shown():
			out.append(p.board_node())
	return out

## Whether `b` (someone's board, remote_boards()) lets us draw on it.
func may_draw_on(b: Node) -> bool:
	return b.get_parent() is Participant and b.get_parent().may_draw()

## Every screen someone shares with us (main.gd::pick() can grab them).
func remote_panels() -> Array:
	var out := []
	for p in _people.values():
		out.append_array(p.remote_panels())
	return out

func debug_lines() -> Array:
	if state == State.OFF:
		return []
	var out := ["[Immersive-2][TEST] room people=%d voice_out=%d" % [_people.size() + 1, voice_out]]
	for p in _people.values():
		out.append("[Immersive-2][TEST] room peer=%s poses=%d voice=%d screens=%s" % [p.display_name,
			p.poses_in, p.voice_in, p.watch_state()])
		out.append_array(p.debug_lines())
	return out

## The room's host answers DiscoveryRequests on port + 1 like a PC does
## (HostDiscovery parses it): its port, how many are in, needs a PIN, its name.
func _answer_discovery() -> void:
	while _disc and _disc.get_available_packet_count() > 0:
		var req := _disc.get_packet()
		if req.size() < 5 or req.decode_u32(0) != HostDiscovery.REQUEST_MAGIC:
			continue
		var reply := PackedByteArray()
		reply.resize(73)
		reply.encode_u32(0, HostDiscovery.REPLY_MAGIC)
		reply[4] = 1
		reply.encode_u16(5, port)
		reply[7] = mini(_people.size() + 1, 255)
		reply[8] = HostDiscovery.FLAG_PIN
		var label := my_name.to_utf8_buffer()
		for i in mini(label.size(), 63):
			reply[9 + i] = label[i]
		_disc.set_dest_address(_disc.get_packet_ip(), _disc.get_packet_port())
		_disc.put_packet(reply)

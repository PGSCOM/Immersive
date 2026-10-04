## One other person in a multiplayer room, as this headset shows them: an
## avatar (a head wearing a headset, a torso, two hands and their name), their
## voice from where their head is, and the screens they share, streamed
## straight from their PC (a watch-only connection, protocol.h
## HELLO_FLAG_WATCH; the PC sends watchers an MJPEG copy of their screens):
## the room only carries where to connect and the code.
##
## Room places this node at their seat; everything under it is in their own
## room frame, exactly as they sent it.
## Their screens can be grabbed by the bar and moved closer: from then on that
## screen stays where it was put, here only.

extends Node3D
class_name Participant

const NetworkClientScript := preload("res://scripts/network_client.gd")
const ScreenPanelScript := preload("res://scripts/screen_panel.gd")

## A received pose is eased toward over this long (hides the 30 Hz steps).
const POSE_SMOOTH_S := 0.06
## The torso turns after the head, slowly.
const TORSO_SMOOTH_S := 0.5
const WATCH_RETRY_S := 5.0
## Their PC's host drops a silent watcher after 10 s: probe like main.gd.
const PROBE_INTERVAL_S := 2.0
const VOICE_RATE := 16000
## Voice queued past this is dropped, so a burst after a stall never lags.
const VOICE_MAX := 4800
## Silence pushed ahead of a sentence (the queue had run dry): it absorbs the
## jitter of the packets behind it.
const VOICE_CUSHION := 960
## A pose packet: flags, then position + rotation (7 floats) of the head and
## of the left and right hands. Flag bit 0 / 1: that hand is tracked.
const POSE_FLOATS := 22
const POSE_LIMIT_M := 50.0
const CODEC_NAMES := {0: "H.264", 1: "HEVC", 2: "MJPEG", 3: "AV1"}

var peer_id := 0
var display_name := "…"
var tone := Color.WHITE
var mic_on := true
## When their last voice packet came in, for "speaking".
var _voice_at_ms := -100000

var _head: Node3D
var _torso: Node3D
var _hands: Array[Node3D] = []
var _label: Label3D
var _voice: AudioStreamPlayer3D
var _voice_pb: AudioStreamGeneratorPlayback
var _voice_capacity := 0
var _voice_skips := 0
var _posed := false
var _target_head := Transform3D.IDENTITY
var _target_hands: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _hand_seen: Array[bool] = [false, false]
var _torso_yaw := 0.0

## What to watch, as they sent it: {ip, port, code}, or {} (not sharing).
var _share := {}
var _net: Node = null
var _retry_s := 0.0
## Their PC turned us away: wait for a new share (a new code) before trying again.
var _refused := false
var _probe_s := 0.0
var _probe_id := 0
var _panels := {}            ## monitor id -> ScreenPanel
var _layouts := {}           ## monitor id -> {xform, w, curve}
var _decoders := {}          ## monitor id -> SoftwareVideoDecoder
## Their whiteboard, replayed here (made when they first draw or show it),
## and where they have it ({on, x, w, guests}).
var _board: Whiteboard = null
var _board_info := {}
## What we drew on their board (they let us), not yet sent to them.
var _guest_ink: Array = []
## What we see and hear of them (Room.pref(), the menu's Permissions page).
var see_board := true
var see_screens := true
var hear := true

## Received, for the test harness: pose and voice packets.
var poses_in := 0
var voice_in := 0

func _ready() -> void:
	_build_avatar()
	_build_voice()

func _exit_tree() -> void:
	_stop_watching()

func _process(delta: float) -> void:
	_ease_avatar(delta)
	_update_watch(delta)
	for mid in _decoders:
		VideoDecoder.show_on(_decoders[mid], _panels.get(mid))
	for p in _panels.values() + ([_board] if _board else []):
		if p.is_dragging():
			p.set_meta("moved", true)  # put somewhere by hand: theirs no longer moves it
	if not _guest_ink.is_empty():
		get_parent().draw_on(peer_id, _guest_ink)
		_guest_ink = []

## What we see and hear of them: their whiteboard, their screens (off: not
## even downloaded) and their voice.
func set_seen(board: bool, screens: bool, voice: bool) -> void:
	see_board = board
	hear = voice
	if screens != see_screens:
		see_screens = screens
		_stop_watching()
		_retry_s = 0.0
	_place_board(_board_info)

# ---------------------------------------------------------------------------
# What the room says about them
# ---------------------------------------------------------------------------

## Their colour (Room keeps it in step with the seats).
func set_tone(color: Color) -> void:
	tone = color
	_paint()

## Their profile (untrusted, from the network): name, microphone, what to
## watch and where their shared screens hang.
func set_profile(p: Dictionary) -> void:
	display_name = str(p.get("name", "")).strip_edges().left(32)
	if display_name.is_empty():
		display_name = "Someone"
	var mic = p.get("mic", true)
	mic_on = mic if typeof(mic) == TYPE_BOOL else true
	if _label:
		_label.text = display_name
	var share := {}
	var s = p.get("share", {})
	if typeof(s) == TYPE_DICTIONARY and str(s.get("ip", "")).is_valid_ip_address():
		var port := _num(s.get("port"), 0.0)
		var code := _num(s.get("code"), 0.0)
		if port >= 1 and port <= 65535 and code >= 1 and code <= 0x7FFFFFFF:
			share = {"ip": str(s.ip), "port": int(port), "code": int(code)}
	if share != _share:
		_stop_watching()
		_share = share
		_refused = false
		_retry_s = 0.0
	_place_board(p.get("board", {}))
	_layouts.clear()
	var screens = p.get("screens", [])
	if typeof(screens) == TYPE_ARRAY:
		for sc in screens.slice(0, 8):
			if typeof(sc) != TYPE_DICTIONARY:
				continue
			var t: Variant = _xform(sc.get("x", []))
			if t == null:
				continue
			_layouts[int(_num(sc.get("id"), -1.0))] = {"xform": t,
				"w": clampf(_num(sc.get("w"), 1.6), 0.4, 4.0), "curve": clampf(_num(sc.get("c"), 0.0), 0.0, 1.0)}
	_place_screens()

## 12 numbers from the network (basis columns, origin) as a placement, or null.
static func _xform(x: Variant) -> Variant:
	if typeof(x) != TYPE_ARRAY or x.size() != 12 or x.any(func(v): return typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT):
		return null
	var t := Transform3D(Vector3(x[0], x[1], x[2]), Vector3(x[3], x[4], x[5]),
		Vector3(x[6], x[7], x[8]), Vector3(x[9], x[10], x[11]))
	if not t.is_finite() or t.origin.length() > POSE_LIMIT_M or absf(t.basis.determinant()) < 0.01:
		return null
	return t.orthonormalized()

## Their whiteboard where they have it, shown while theirs is.
func _place_board(b: Variant) -> void:
	_board_info = b if typeof(b) == TYPE_DICTIONARY else {}
	var at: Variant = _xform(_board_info.get("x", []))
	if at != null and _board_info.get("on", false) == true and see_board:
		_ensure_board()
		if not _board.visible:
			_board.set_shown(true)
		if not _board.get_meta("moved", false):
			_board.transform = at
			_board.set_panel_width(clampf(_num(_board_info.get("w"), 1.2), Whiteboard.MIN_WIDTH, Whiteboard.MAX_WIDTH))
	elif _board and _board.visible:
		_board.set_shown(false)

## Ink on their board, as [[author, op], …] (Room._take_ink); our own comes
## back to nobody, it is on our copy already.
func apply_ink(inked: Array) -> void:
	_ensure_board()
	var me := multiplayer.get_unique_id()
	for pair in inked:
		if typeof(pair) == TYPE_ARRAY and pair.size() == 2 and typeof(pair[0]) == TYPE_INT and pair[0] != me:
			_board.apply_ink(pair[1], pair[0])

## They show a whiteboard; we see it here; they let us draw on it.
func shows_board() -> bool:
	return _board_info.get("on", false) == true

func board_shown() -> bool:
	return _board != null and _board.visible

func board_node() -> Whiteboard:
	return _board

func may_draw() -> bool:
	var guests = _board_info.get("guests", [])
	return typeof(guests) == TYPE_ARRAY and guests.has(multiplayer.get_unique_id())

func _ensure_board() -> void:
	if _board == null:
		_board = Whiteboard.new()
		_board.name = "Board"
		# What we draw here is ours under our peer id, as the owner replays it.
		_board.local_author = multiplayer.get_unique_id()
		add_child(_board)
		# What we draw on it (when they let us: main.gd only lets the pointer
		# draw then) goes to them.
		_board.ink.connect(func(op: Array): _guest_ink.append(op))

## A number from the network, or `default` for anything else.
static func _num(v: Variant, default: float) -> float:
	return float(v) if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT else default

func set_pose(d: PackedFloat32Array) -> void:
	var u := unpack_pose(d)
	if u.is_empty():
		return
	poses_in += 1
	_target_head = u.head
	for i in 2:
		_hand_seen[i] = u.seen[i]
		if u.seen[i]:
			_target_hands[i] = u.hands[i]
	if not _posed:
		_posed = true
		_head.transform = _target_head
		_torso_yaw = _yaw_of(_target_head.basis)

## [flags, head, left hand, right hand] as POSE_FLOATS floats; a hand that is
## null is left out (its flag bit clear).
static func pack_pose(head: Transform3D, left: Variant, right: Variant) -> PackedFloat32Array:
	var d := PackedFloat32Array()
	d.resize(POSE_FLOATS)
	var flags := 0
	var parts: Array = [head, left if left != null else Transform3D.IDENTITY,
		right if right != null else Transform3D.IDENTITY]
	for i in 3:
		var t: Transform3D = parts[i]
		var q := t.basis.get_rotation_quaternion()
		var o := 1 + 7 * i
		d[o] = t.origin.x
		d[o + 1] = t.origin.y
		d[o + 2] = t.origin.z
		d[o + 3] = q.x
		d[o + 4] = q.y
		d[o + 5] = q.z
		d[o + 6] = q.w
	if left != null:
		flags |= 1
	if right != null:
		flags |= 2
	d[0] = flags
	return d

## {head, hands: [left, right], seen: [bool, bool]}, or {} for a malformed packet.
static func unpack_pose(d: PackedFloat32Array) -> Dictionary:
	if d.size() != POSE_FLOATS:
		return {}
	var parts: Array[Transform3D] = []
	for i in 3:
		var o := 1 + 7 * i
		var at := Vector3(d[o], d[o + 1], d[o + 2])
		var q := Quaternion(d[o + 3], d[o + 4], d[o + 5], d[o + 6])
		if not at.is_finite() or at.length() > POSE_LIMIT_M or not q.is_finite() or q.length() < 0.5:
			return {}
		parts.append(Transform3D(Basis(q.normalized()), at))
	var flags := int(d[0])
	return {"head": parts[0], "hands": [parts[1], parts[2]], "seen": [(flags & 1) != 0, (flags & 2) != 0]}

func push_voice(pcm: PackedByteArray) -> void:
	if not _voice_pb or pcm.size() < 2 or pcm.size() > 4096:
		return
	voice_in += 1
	_voice_at_ms = Time.get_ticks_msec()
	if not hear:
		return
	var frames := Room.decode_voice(pcm)
	var queued := _voice_capacity - _voice_pb.get_frames_available()
	if queued + frames.size() > VOICE_MAX:
		return
	# Ran dry since the last packet (a new sentence, or a gap): cushion first.
	if _voice_pb.get_skips() != _voice_skips:
		_voice_skips = _voice_pb.get_skips()
		if queued <= 0:
			var hush := PackedVector2Array()
			hush.resize(VOICE_CUSHION)
			_voice_pb.push_buffer(hush)
	if _voice_pb.get_frames_available() >= frames.size():
		_voice_pb.push_buffer(frames)

func is_speaking() -> bool:
	return Time.get_ticks_msec() - _voice_at_ms < 300

# ---------------------------------------------------------------------------
# Their screens
# ---------------------------------------------------------------------------

## Their head, chest and hands, and the corners and centre of what they show.
func occluder_points() -> Array:
	if not visible:
		return []
	var out := [_head.global_position, _torso.global_position]
	for h in _hands:
		if h.visible:
			out.append(h.global_position)
	var shown := remote_panels()
	if _board and _board.visible:
		shown.append(_board)
	for p in shown:
		for uv in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1), Vector2(0.5, 0.5)]:
			out.append(p.to_global(p.local_point(uv.x, uv.y)))
	return out

func remote_panels() -> Array:
	return _panels.values().filter(func(p): return is_instance_valid(p) and p.visible)

## "" (not sharing), "hidden" (we turned them off), "connecting", "live" (n
## screens), "refused", "unreachable".
func watch_state() -> String:
	if _share.is_empty():
		return ""
	if not see_screens:
		return "hidden"
	if _refused:
		return "refused"
	if _net == null:
		return "unreachable" if _retry_s > 0.0 else "connecting"
	return "live" if not _panels.is_empty() else "connecting"

func _update_watch(delta: float) -> void:
	if _share.is_empty() or _refused or not see_screens:
		return
	if _net == null:
		_retry_s -= delta
		if _retry_s > 0.0:
			return
		_net = NetworkClientScript.new()
		_net.name = "Watch"
		add_child(_net)
		_net.disconnected_from_host.connect(_on_watch_lost)
		_net.connection_rejected.connect(func(_reason: int): _refused = true)
		_net.stream_started.connect(_on_stream_started)
		_net.stream_stopped.connect(_on_stream_stopped)
		_net.video_frame_received.connect(func(mid: int, data: PackedByteArray, _w: int, _h: int):
			if _decoders.has(mid):
				_decoders[mid].submit(data))
		_net.connect_to_server(_share.ip, _share.port, 0, false, 0, _share.code)
		print("[Room] watching %s's screens at %s:%d" % [display_name, _share.ip, _share.port])
		return
	_probe_s += delta
	if _probe_s >= PROBE_INTERVAL_S:
		_probe_s = 0.0
		_probe_id += 1
		_net.send_latency_probe(_probe_id, Time.get_ticks_usec())

func _on_watch_lost() -> void:
	_stop_watching()
	_retry_s = WATCH_RETRY_S

func _stop_watching() -> void:
	if _net:
		_net.disconnect_from_server()
		_net.queue_free()
		_net = null
	for mid in _panels.keys():
		_drop_screen(mid)

func _on_stream_started(mid: int, w: int, h: int, codec: int) -> void:
	_close_decoder(mid)
	var p: MeshInstance3D = _panels.get(mid)
	if p == null:
		p = MeshInstance3D.new()
		p.script = ScreenPanelScript
		p.set_meta("monitor_id", mid)
		add_child(p)
		_panels[mid] = p
	p.set_resolution(w, h, codec)
	_place_screens()
	var sw := SoftwareVideoDecoder.new()
	if sw.open(codec, w, h):  # MJPEG: the copy a host sends its watchers
		_decoders[mid] = sw
	else:
		p.set_placeholder_text("%s shares this in %s, which this headset cannot show." %
			[display_name, CODEC_NAMES.get(codec, "a codec")])

func _on_stream_stopped(mid: int) -> void:
	for m in (_panels.keys() if mid < 0 else [mid]):
		_drop_screen(m)

func _drop_screen(mid: int) -> void:
	_close_decoder(mid)
	if is_instance_valid(_panels.get(mid)):
		_panels[mid].queue_free()
	_panels.erase(mid)

func _close_decoder(mid: int) -> void:
	if _decoders.has(mid):
		_decoders[mid].close()
		_decoders.erase(mid)

## Each screen where they have it, unless it was moved by hand here. One with
## no layout yet stays hidden (it would sit on the floor at their seat).
func _place_screens() -> void:
	for mid in _panels:
		var p: MeshInstance3D = _panels[mid]
		if p.get_meta("moved", false):
			continue
		p.visible = _layouts.has(mid)
		if not p.visible:
			continue
		var l: Dictionary = _layouts[mid]
		if p.get_meta("curve", -1.0) != l.curve:
			p.set_meta("curve", l.curve)
			p.set_curvature(l.curve > 0.001, l.curve)
		if absf(p.panel_width - l.w) > 0.001:
			p.set_panel_width(l.w)
		p.transform = l.xform

## Centre pixel of each screen they share, and their board, for the test harness.
func debug_lines() -> Array:
	var out := []
	if _board:
		out.append("[Immersive-2][TEST] remote board peer=%s shown=%s strokes=%d" % [display_name,
			_board.visible, _board.stroke_count()])
	for mid in _panels:
		var img: Image = _panels[mid].screen_image
		if img and not img.is_empty():
			out.append("[Immersive-2][TEST] remote panel peer=%s mon=%d %dx%d center=%s" % [display_name,
				mid, img.get_width(), img.get_height(),
				img.get_pixel(img.get_width() / 2, img.get_height() / 2).to_html(false)])
	return out

# ---------------------------------------------------------------------------
# Avatar
# ---------------------------------------------------------------------------

func _build_avatar() -> void:
	_head = Node3D.new()
	add_child(_head)
	var skull := SphereMesh.new()
	skull.radius = 0.1
	skull.height = 0.225
	_head.add_child(_part(skull, "skin"))
	# The headset they wear: a rounded visor over the eyes and a strap that
	# rises towards the back of the head.
	var visor := CapsuleMesh.new()
	visor.radius = 0.05
	visor.height = 0.2
	var v := _part(visor, "gear")
	v.transform = Transform3D(Basis(Vector3.BACK, PI / 2.0) * Basis.from_scale(Vector3(1.0, 1.0, 0.72)),
		Vector3(0.0, 0.018, -0.074))
	_head.add_child(v)
	var strap := TorusMesh.new()
	strap.inner_radius = 0.096
	strap.outer_radius = 0.118
	strap.ring_segments = 12
	var st := _part(strap, "gear")
	st.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-9.0)) * Basis.from_scale(Vector3(1.0, 0.75, 1.0)),
		Vector3(0.0, 0.026, 0.004))
	_head.add_child(st)

	# A bust: rounded shoulders over a chest that narrows to the waist, flatter
	# front to back. It hangs under the head and turns after it (_ease_avatar).
	_torso = Node3D.new()
	add_child(_torso)
	var shoulders := CapsuleMesh.new()
	shoulders.radius = 0.075
	shoulders.height = 0.4
	var sh := _part(shoulders, "cloth")
	sh.transform = Transform3D(Basis(Vector3.BACK, PI / 2.0), Vector3(0.0, -0.035, 0.0))
	_torso.add_child(sh)
	var chest := CylinderMesh.new()
	chest.top_radius = 0.165
	chest.bottom_radius = 0.1
	chest.height = 0.36
	var ch := _part(chest, "cloth")
	# Its top edge stays inside the shoulders (no seam shows).
	ch.transform = Transform3D(Basis.from_scale(Vector3(1.0, 1.0, 0.45)), Vector3(0.0, -0.215, 0.0))
	_torso.add_child(ch)

	for i in 2:
		var hand := Node3D.new()
		hand.visible = false
		add_child(hand)
		# A mitten: a flattened capsule along the pointing direction.
		var mitt := CapsuleMesh.new()
		mitt.radius = 0.042
		mitt.height = 0.135
		var m := _part(mitt, "skin")
		m.transform = Transform3D(Basis(Vector3.RIGHT, PI / 2.0) * Basis.from_scale(Vector3(1.0, 1.0, 0.62)),
			Vector3(0.0, 0.0, 0.015))
		hand.add_child(m)
		_hands.append(hand)

	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 48
	_label.pixel_size = 0.0024  # ~11 cm tall: readable from the next seat
	_label.outline_size = 12
	_label.outline_modulate = Color(UiTheme.GROUND, 0.75)
	_label.text = display_name
	add_child(_label)
	_paint()

## A mesh part; its material is set by _paint() from the role ("skin", "gear", "cloth").
func _part(mesh: Mesh, role: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_meta("role", role)
	return mi

func _paint() -> void:
	if not _head:
		return
	var mats := {"skin": _mat(tone, 0.85), "gear": _mat(UiTheme.SURFACE, 0.3),
		"cloth": _mat(tone.lerp(UiTheme.GROUND, 0.42), 0.95)}
	for mi in find_children("*", "MeshInstance3D", true, false):
		if mi.has_meta("role"):
			mi.material_override = mats[mi.get_meta("role")]

static func _mat(c: Color, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = roughness
	return m

func _ease_avatar(delta: float) -> void:
	if not _posed:
		visible = false
		return
	visible = true
	var k := 1.0 - exp(-delta / POSE_SMOOTH_S)
	_head.transform = _head.transform.interpolate_with(_target_head, k).orthonormalized()
	for i in 2:
		var hand := _hands[i]
		if _hand_seen[i] and not hand.visible:
			hand.transform = _target_hands[i]  # back in view: no sweep from where it vanished
		hand.visible = _hand_seen[i]
		if hand.visible:
			hand.transform = hand.transform.interpolate_with(_target_hands[i], k).orthonormalized()
	_torso_yaw = lerp_angle(_torso_yaw, _yaw_of(_head.basis), 1.0 - exp(-delta / TORSO_SMOOTH_S))
	var turn := Basis(Vector3.UP, _torso_yaw)
	_torso.transform = Transform3D(turn, _head.position + Vector3(0.0, -0.16, 0.0) + turn * Vector3(0.0, 0.0, 0.05))
	_label.position = _head.position + Vector3(0.0, 0.24, 0.0)
	# Brighter while they talk: who is speaking, seen from anywhere.
	_label.modulate = UiTheme.INK if is_speaking() else Color(UiTheme.INK_2, 0.85)

## The heading (yaw) the basis faces, level.
static func _yaw_of(b: Basis) -> float:
	var fwd := -b.z
	return atan2(-fwd.x, -fwd.z) if Vector2(fwd.x, fwd.z).length_squared() > 1e-6 else 0.0

func _build_voice() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = VOICE_RATE
	gen.buffer_length = 0.5
	_voice = AudioStreamPlayer3D.new()
	_voice.stream = gen
	_voice.unit_size = 3.0  # full voice within a seat or so, softer further away
	_voice.max_db = 3.0
	_head.add_child(_voice)
	_voice.play()
	_voice_pb = _voice.get_stream_playback()
	_voice_capacity = _voice_pb.get_frames_available()
	_voice_skips = _voice_pb.get_skips()

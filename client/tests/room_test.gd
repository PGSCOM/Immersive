extends SceneTree
## The multiplayer room's own logic, headless (two headsets talking to each
## other is e2e_test.py's step 9), plus the whiteboard's ink replay and
## walking:
##   godot --headless --xr-mode off --path client/project \
##       -s "$PWD/client/tests/room_test.gd"
## Pose packets, voice PCM and the noise gate's level, seats seen from both
## sides, a sender's untrusted profile, and a remote screen placed where its
## owner has it. Prints "RESULT fails=N".

var fails := 0

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	# Poses: head and hands survive the trip; a missing hand stays missing.
	var head := Transform3D(Basis(Vector3.UP, 0.7) * Basis(Vector3.RIGHT, -0.2), Vector3(0.3, 1.6, -0.1))
	var right := Transform3D(Basis(Vector3.FORWARD, 0.4), Vector3(0.25, 1.1, -0.4))
	var d: PackedFloat32Array = Participant.pack_pose(head, null, right)
	var u := Participant.unpack_pose(d)
	check(d.size() == Participant.POSE_FLOATS and not u.is_empty(), "a pose packs into %d floats" % d.size())
	check(u.head.is_equal_approx(head) and u.hands[1].is_equal_approx(right),
		"head and right hand come back -> %s / %s" % [u.head, u.hands[1]])
	check(u.seen == [false, true], "the left hand is missing, the right one seen -> %s" % [u.seen])
	var bad := d.duplicate()
	bad[2] = NAN
	check(Participant.unpack_pose(bad).is_empty(), "a NaN in a pose is dropped")
	bad = d.duplicate()
	bad[1] = 1e6
	check(Participant.unpack_pose(bad).is_empty(), "a pose kilometres away is dropped")
	check(Participant.unpack_pose(d.slice(0, 10)).is_empty(), "a short packet is dropped")

	# Voice: 16-bit PCM round trip, both channels, and the gate's level.
	var tone := PackedFloat32Array()
	for i in Room.VOICE_CHUNK:
		tone.append(0.25 * sin(TAU * 440.0 * i / Room.VOICE_RATE))
	var pcm := Room.encode_voice(tone)
	var back := Room.decode_voice(pcm)
	var worst := 0.0
	for i in tone.size():
		worst = maxf(worst, absf(back[i].x - tone[i]) + absf(back[i].y - tone[i]))
	check(pcm.size() == Room.VOICE_CHUNK * 2 and worst < 0.0002,
		"voice: %d bytes per 20 ms, back within %.5f" % [pcm.size(), worst])
	var loud := Room.encode_voice(PackedFloat32Array([2.0, -2.0]))
	check(loud.decode_s16(0) == 32767 and loud.decode_s16(2) == -32768, "voice: clipped, not wrapped")
	var hiss := PackedFloat32Array()
	hiss.resize(Room.VOICE_CHUNK)
	hiss.fill(0.004)
	check(Room.rms(tone) > Room.GATE_RMS and Room.rms(hiss) < Room.GATE_RMS,
		"gate: a voice opens it (%.3f), hiss does not (%.3f)" % [Room.rms(tone), Room.rms(hiss)])

	# Seats: the person one to my right sees me one to their left.
	var mine := Room.seat(1)
	var theirs := Room.seat(-1)
	check(mine.origin.x > 0.0 and is_equal_approx(theirs.origin.x, -mine.origin.x),
		"seats are mirrored: %s / %s" % [mine.origin, theirs.origin])

	# A participant: untrusted profile fields are checked; a shared screen
	# lands where its owner has it, at their seat.
	var p := Participant.new()
	root.add_child(p)
	p.position = mine.origin
	await process_frame
	p.set_profile({"name": 42, "share": {"ip": "not an ip", "port": 19800, "code": 7}, "mic": "yes",
		"screens": [{"id": "x", "x": ["a", 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]}, 5, {"x": {}}]})
	p.set_profile({"name": "Ana", "share": {"ip": "10.0.0.2", "port": {}, "code": "7"}})
	check(p.display_name == "Ana" and p.watch_state() == "" and p.mic_on and p._layouts.is_empty(),
		"bad share and screen fields are ignored -> screens '%s'" % p.watch_state())
	var ok_ips := ["10.0.0.2", "172.16.4.1", "172.31.255.1", "192.168.1.20", "100.101.102.103", "169.254.0.21"]
	var bad_ips := ["127.0.0.1", "0.0.0.0", "8.8.8.8", "172.32.0.1", "192.169.1.1", "224.0.0.1",
		"255.255.255.255", "100.128.0.1", "::1", "fe80::1", "192.168.1"]
	check(ok_ips.all(Participant.watchable_ip) and not bad_ips.any(Participant.watchable_ip),
		"a PC to watch must be on a local network or a VPN -> %s" % [bad_ips.filter(Participant.watchable_ip)])
	p.set_profile({"name": "Ana", "share": {"ip": "127.0.0.1", "port": 19800, "code": 7}})
	check(p.watch_state() == "", "a share at 127.0.0.1 (our own PC over USB) is ignored")
	var at := Transform3D(Basis(Vector3.UP, 0.3), Vector3(-0.4, 1.5, -1.2))
	var b := at.basis
	p.set_profile({"name": "Ana", "screens": [{"id": 1, "w": 1.2, "c": 0.0,
		"x": [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, at.origin.x, at.origin.y, at.origin.z]}]})
	p._on_stream_started(1, 1280, 720, 2)
	await process_frame
	var panel: Node3D = p._panels.get(1)
	check(panel != null and panel.visible and panel.global_position.is_equal_approx(mine.origin + at.origin)
		and is_equal_approx(panel.panel_width, 1.2),
		"their screen hangs at their seat where they put it -> %s" % [panel.global_position if panel else null])
	check(p.remote_panels() == [panel], "it is grabbable here")
	p._on_stream_stopped(1)
	check(p.remote_panels().is_empty(), "and gone when they stop it")
	p.queue_free()

	await _whiteboards()
	await _moving()

	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)

## Someone's whiteboard, replayed from its ink ops on another copy.
func _whiteboards() -> void:
	var mine := Whiteboard.new()
	var theirs := Whiteboard.new()
	root.add_child(mine)
	root.add_child(theirs)
	await process_frame
	mine.set_shown(true)
	var ops: Array = []
	mine.ink.connect(func(op): ops.append(op))
	var n := mine.global_basis.z
	for line in 2:
		for i in 15:
			var at := mine.to_global(mine.local_point(0.2 + 0.04 * i, 0.3 + 0.2 * line))
			mine.pointer_ray(at + n * 0.3, -n, true)
			await process_frame
		mine.pointer_leave()
		await process_frame
	for op in ops:
		theirs.apply_ink(op)
	var a: Line2D = mine._ink.get_child(0)
	var b: Line2D = theirs._ink.get_child(0)
	check(theirs.stroke_count() == 2 and mine.stroke_count() == 2 and a.points.size() == b.points.size()
		and a.points[-1].distance_to(b.points[-1]) < 1.0 and a.default_color == b.default_color,
		"a whiteboard replays from its ink: %d strokes, %d of %d points" % [theirs.stroke_count(),
			b.points.size(), a.points.size()])
	mine.undo()
	mine.clear()
	for op in ops.slice(ops.size() - 2):
		theirs.apply_ink(op)
	check(ops.slice(-2) == [["u"], ["c"]] and theirs.stroke_count() == 0, "undo and clear go across too")
	for bad in [[], [1], ["b", "x", "y", 1, 2], ["p", {}, 3], ["b", 7, 3.0, 1.0, 2.0], "c", null]:
		theirs.apply_ink(bad)
	check(theirs.stroke_count() == 0, "malformed ink ops are skipped")
	# Two people drawing at once: each point lands on its author's stroke, and
	# replaying an undo does not send it on again (it would bounce for ever).
	var echoed := []
	theirs.ink.connect(func(op): echoed.append(op))
	for step in [[["b", "ece6dc", 5.0, 10.0, 10.0], 7], [["b", "e39a7f", 5.0, 500.0, 500.0], 9],
			[["p", 30.0, 10.0], 7], [["p", 520.0, 500.0], 9], [["p", 50.0, 10.0], 7]]:
		theirs.apply_ink(step[0], step[1])
	var lines: Array = theirs._ink.get_children().filter(func(c): return c is Line2D and c.visible)
	check(lines.size() == 2 and lines[0].points.size() == 4 and lines[1].points.size() == 3
		and lines[1].points[-1] == Vector2(520, 500),
		"two people drawing at once keep their own strokes -> %s points" % [lines.map(func(l): return l.points.size())])
	theirs.apply_ink(["u"], 7)
	check(echoed.is_empty() and theirs.stroke_count() == 1, "a replayed undo is not sent on again")
	check(theirs._ink.get_children().filter(func(c): return c is Line2D and c.visible)[0].get_meta("author") == 9,
		"7's undo took back 7's stroke, not 9's newer one")
	mine.queue_free()
	theirs.queue_free()

	# Undo is per author: the owner (OWNER) and a guest (7) each take back
	# their own, while the other's stroke in progress goes on, and two copies
	# that saw the ops in another order end up the same.
	var owner_board := Whiteboard.new()
	var guest_copy := Whiteboard.new()
	guest_copy.local_author = 7
	root.add_child(owner_board)
	root.add_child(guest_copy)
	await process_frame
	var o_ops := [["b", "ece6dc", 5.0, 100.0, 100.0], ["p", 120.0, 100.0]]
	var g_ops := [["b", "e39a7f", 5.0, 500.0, 500.0], ["p", 520.0, 500.0]]
	for op in o_ops:
		owner_board.apply_ink(op, Whiteboard.OWNER)
	for op in g_ops:
		owner_board.apply_ink(op, 7)
	for op in g_ops:
		guest_copy.apply_ink(op, 7)
	for op in o_ops:
		guest_copy.apply_ink(op, Whiteboard.OWNER)
	owner_board.apply_ink(["u"], Whiteboard.OWNER)  # the owner's undo, mid-way through the guest's stroke
	guest_copy.apply_ink(["u"], Whiteboard.OWNER)
	owner_board.apply_ink(["p", 540.0, 500.0], 7)
	guest_copy.apply_ink(["p", 540.0, 500.0], 7)
	var left := func(b: Whiteboard): return b._ink.get_children().filter(func(c): return c is Line2D and c.visible) \
		.map(func(l): return [l.get_meta("author"), l.points.size()])
	check(left.call(owner_board) == [[7, 4]] and left.call(guest_copy) == [[7, 4]],
		"the owner's undo takes the owner's stroke, the guest's goes on, on both copies -> %s / %s" %
		[left.call(owner_board), left.call(guest_copy)])
	guest_copy.undo()  # the button on the guest's copy: the guest's own
	owner_board.apply_ink(["u"], 7)
	check(owner_board.stroke_count() == 0 and guest_copy.stroke_count() == 0, "the guest's undo takes the guest's stroke")
	owner_board.queue_free()
	guest_copy.queue_free()

	# The owner's own ink goes out as OWNER, never as a peer id: drawn outside
	# a room it would be the offline peer's 1, the room host's, and the host's
	# copy (here: we are peer 1) skips its own. Whoever comes later gets the
	# board as it is: what was undone is not in it, a clear that undo can
	# still take back is.
	var own := Whiteboard.new()
	root.add_child(own)
	await process_frame
	for op in [["b", "ece6dc", 5.0, 10.0, 10.0], ["p", 40.0, 10.0], ["p", 80.0, 10.0]]:
		own.apply_ink(op, Whiteboard.OWNER)
	own.apply_ink(["b", "e39a7f", 12.0, 300.0, 300.0], Whiteboard.OWNER)
	own.apply_ink(["u"], Whiteboard.OWNER)
	own.apply_ink(["b", "a3b18a", 5.0, 600.0, 600.0], 7)
	own.apply_ink(["c"], Whiteboard.OWNER)
	var snap := own.snapshot()
	var host_copy := Participant.new()
	root.add_child(host_copy)
	await process_frame
	host_copy.apply_board([[Whiteboard.OWNER, ["b", "ffffff", 5.0, 1.0, 1.0]]], true)
	host_copy.apply_board(snap, true)  # a fresh snapshot replaces what was there
	var copy := host_copy.board_node()
	var kinds := func(b: Whiteboard): return b._ink.get_children().map(func(c): return [c.get_meta("author"),
		(c as Line2D).points.size() if c is Line2D else "clear"])
	check(root.multiplayer.get_unique_id() == 1 and kinds.call(copy) == kinds.call(own)
		and kinds.call(own) == [[0, 4], [7, 2], [0, "clear"]] and copy.stroke_count() == 0,
		"the board as it is reaches the room host's copy, undone strokes left out -> %s" % [kinds.call(copy)])
	copy.apply_ink(["u"], Whiteboard.OWNER)
	own.apply_ink(["u"], Whiteboard.OWNER)
	check(copy.stroke_count() == 2 and own.stroke_count() == 2, "and an undo of that clear after it works on both")
	var room := Room.new()
	root.add_child(room)
	room.queue_ink(["b", "ece6dc", 5.0, 10.0, 10.0])
	room._flush_ink()
	check(room._ink_out.is_empty(), "ink drawn outside a room is dropped (the snapshot will carry it)")

	# Who may watch our screens: the code goes only to them, and turning
	# someone off, or anyone leaving, asks main.gd for a new code.
	var revoked := []
	room.watch_revoked.connect(func(id): revoked.append(id))
	room.set_share({"ip": "192.168.1.20", "port": 19800, "code": 4242})
	room.set_screens([{"id": 0, "x": [], "w": 1.6, "c": 0.0}])
	room.set_pref(5, "watch", false)
	check(room._profile_for(5).share.is_empty() and room._profile_for(5).screens.is_empty()
		and room._profile_for(6).share.code == 4242 and room._profile.share.code == 4242,
		"someone who may not watch gets no code (the others do)")
	room.set_pref(5, "watch", true)
	room._on_peer_disconnected(6)
	check(revoked == [5, 6] and room._profile_for(5).share.code == 4242,
		"turning someone off and someone leaving both ask for a new code -> %s" % [revoked])
	host_copy.queue_free()
	own.queue_free()
	room.queue_free()
	await _encrypted()

## The room speaks DTLS only: a plain ENet client never gets in, one that
## speaks DTLS does. PINs and watch codes come from the system's random source.
func _encrypted() -> void:
	var room := Room.new()
	root.add_child(room)
	await process_frame
	var port := 45610
	check(room.open(port, 135790), "a room opens, encrypted")
	var plain := ENetMultiplayerPeer.new()
	plain.create_client("127.0.0.1", port)
	var dtls := ENetMultiplayerPeer.new()
	dtls.create_client("127.0.0.1", port)
	dtls.host.dtls_client_setup(Room.TLS_NAME, TLSOptions.client_unsafe())
	for i in 150:  # real time (--fixed-fps runs frames as fast as it can): 1.5 s
		plain.poll()
		dtls.poll()
		OS.delay_msec(10)
		await process_frame
	check(plain.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED
		and dtls.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED,
		"a plain client is not let in, a DTLS one is -> %d / %d" % [plain.get_connection_status(),
			dtls.get_connection_status()])
	plain.close()
	dtls.close()
	room.leave()
	var pins := range(20).map(func(_i): return Room.random_pin())
	var codes := range(20).map(func(_i): return Room.random_code())
	check(pins.all(func(p): return p >= 100000 and p <= 999999) and codes.all(func(c): return c >= 1 and c <= 0x7FFFFFFF)
		and pins.any(func(p): return p != pins[0]), "random PINs have six digits, codes 31 bits")
	room.queue_free()

## Walking, turning and pulling move the tracking origin; the head keeps its
## place in a turn; a screen in between hides what is behind it.
func _moving() -> void:
	var m = load("res://scripts/main.gd").new()
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	root.add_child(origin)
	origin.add_child(cam)
	cam.position = Vector3(0.2, 1.6, 0.1)
	cam.rotation.y = PI / 2.0  # looking along -X
	m.xr_origin = origin
	m.xr_camera = cam
	await process_frame
	m.walk(Vector2(0, 1), 1.0)
	check(origin.position.is_equal_approx(Vector3(-m.WALK_SPEED, 0, 0)), "stick up walks where we look -> %s" % origin.position)
	var head := cam.global_position
	m.turn(1)
	check(cam.global_position.is_equal_approx(head) and absf(cam.global_rotation.y - (PI / 2.0 - deg_to_rad(m.TURN_STEP_DEG))) < 0.001,
		"a turn to the right keeps the head where it is -> %s, %.1f deg" % [cam.global_position, rad_to_deg(cam.global_rotation.y)])
	m.back_to_seat()
	m.pull(Vector3(0, 1.2, -0.5), Vector3(0, 1.0, -0.2))  # the hand comes 30 cm back (and down)
	check(origin.position.is_equal_approx(Vector3(0, 0, -0.3 * m.PULL_GAIN)), "pulling the room walks us forward, level -> %s" % origin.position)
	m.back_to_seat()
	check(origin.transform == Transform3D.IDENTITY, "back to my seat")

	var screen: Node3D = MeshInstance3D.new()
	screen.script = load("res://scripts/screen_panel.gd")
	root.add_child(screen)
	await process_frame
	screen.global_position = Vector3(0, 1.6, -1.0)
	var eye := Vector3(0, 1.6, 0)
	check(m._hides_any(screen, eye, [Vector3(0.1, 1.6, -3.0)]) and not m._hides_any(screen, eye, [Vector3(0.1, 1.6, -0.5)])
		and not m._hides_any(screen, eye, [Vector3(3.0, 1.6, -3.0)]),
		"a screen hides someone behind it, not someone in front or to the side")
	screen.queue_free()
	origin.queue_free()
	m.free()

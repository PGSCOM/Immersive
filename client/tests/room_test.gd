extends SceneTree
## The multiplayer room's own logic, headless (two headsets talking to each
## other is e2e_test.py's step 9):
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

	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)

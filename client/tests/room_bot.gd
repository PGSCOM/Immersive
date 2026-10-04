extends SceneTree
## A second person for trying multiplayer alone: the real client, run on the
## PC, plays "Ben" in a room with your headset. Start it with
## host/tools/room_sandbox.py, which also starts Ben's PC (a --stub host).
##
## It takes the client's own --im2-* arguments (room, name, sharing...), and:
## - looks at whoever is in the room and sways a little: its window shows what
##   Ben sees (you, and your screens when they stream in MJPEG, the only codec
##   a PC decodes);
## - moves both hands (fake controllers) and waves now and then;
## - opens its whiteboard beside itself, facing you, lets you draw on it
##   (the launcher passes --im2-board-open) and every few seconds draws a wavy
##   line on it (through the same pointer a person uses), in the next ink, six
##   in all;
## - repeats what it hears from you ECHO_DELAY_MS later, so your own voice
##   comes back from its avatar. It stops listening while it speaks and just
##   after, or your headset's speakers would feed its echo back for ever. With
##   --im2-tone it plays a tone instead. Its own speakers stay muted.

const ECHO_DELAY_MS := 1500
const ECHO_DEAF_MS := 700
const TURN_S := 0.4  ## how fast the head turns towards you

var main: Node
var room: Room
var pads := {}
var echo: Array = []  ## [due ms, pcm]
var deaf_until := 0
var heard := 0
var repeated := 0
var t := 0.0
var status_s := 0.0
var board_s := 0.0
var stroke_i := -1  ## point of the line being drawn, -1 = none
var strokes := 0
const STROKE_POINTS := 40

func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.name = "Main"  # the room's RPCs need /root/Main/Room on every side
	root.add_child(main)
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	for side in [&"left_hand", &"right_hand"]:
		var pad := XRControllerTracker.new()
		pad.name = side
		pad.hand = XRPositionalTracker.TRACKER_HAND_LEFT if side == &"left_hand" \
			else XRPositionalTracker.TRACKER_HAND_RIGHT
		XRServer.add_tracker(pad)
		pads[side] = pad
	_hook_room.call_deferred()

func _hook_room() -> void:
	room = main.room
	room.voice_heard.connect(func(_id: int, pcm: PackedByteArray):
		heard += 1
		if room.voice_from == "" and Time.get_ticks_msec() >= deaf_until:
			echo.append([Time.get_ticks_msec() + ECHO_DELAY_MS, pcm]))
	print("[Bot] %s is up. Its window shows what it sees." % room.my_name)

func _process(delta: float) -> bool:
	if room == null:
		return false
	t += delta
	_move(delta)
	_draw(delta)
	var now := Time.get_ticks_msec()
	while not echo.is_empty() and echo[0][0] <= now:
		room.say(echo.pop_front()[1])
		repeated += 1
		deaf_until = now + ECHO_DEAF_MS
	status_s += delta
	if status_s >= 5.0:
		status_s = 0.0
		_status()
	return false

## Head: at standing height, turned towards the first person in the room (or
## ahead), with a slow sway. Hands: in front of the chest, the right one
## waving for a moment every eight seconds.
func _move(delta: float) -> void:
	var origin: Node3D = main.xr_origin
	var cam: Node3D = main.xr_camera
	var at := Vector3(0.04 * sin(t * 0.6), 1.6 + 0.015 * sin(t * 1.1), 0.0)
	var look := origin.global_transform * (at + Vector3(0.0, -0.15, -2.0))
	for p in room.get_children():
		if p is Participant and p.visible:
			look = p._head.global_position
			break
	var eye: Vector3 = origin.global_transform * at
	var want := Basis.looking_at(look - eye, Vector3.UP) * Basis(Vector3.RIGHT, 0.05 * sin(t * 0.9))
	var k := 1.0 - exp(-delta / TURN_S)
	cam.global_transform = Transform3D(cam.global_basis.orthonormalized().slerp(want.orthonormalized(), k), eye)

	var yaw := Basis(Vector3.UP, cam.global_basis.get_euler().y)
	var wave := clampf(sin(TAU * t / 8.0) * 3.0 - 2.0, 0.0, 1.0)  # up for ~1.5 s of every 8
	var left := Vector3(-0.2, 1.12 + 0.02 * sin(t * 1.7), -0.32)
	var right := Vector3(0.21, 1.14 + 0.02 * sin(t * 1.5 + 1.0), -0.34).lerp(Vector3(0.3, 1.62, -0.22), wave)
	var tilt := Basis(Vector3.RIGHT, -0.35)
	_pose(&"left_hand", Transform3D(yaw * tilt, yaw * left))
	_pose(&"right_hand", Transform3D(yaw * Basis(Vector3.FORWARD, wave * 0.6 * sin(t * 12.0)) * tilt.slerp(Basis(Vector3.RIGHT, 0.9), wave),
		yaw * right))

## The board stands beside Ben, towards the first person in the room, facing them.
func _draw(delta: float) -> void:
	var wb: Whiteboard = main.whiteboard
	board_s += delta
	if stroke_i < 0:
		if board_s < 6.0:
			return
		board_s = 0.0
		if strokes >= 6:
			return  # done: it stays put, the rest of the board is yours
		_place_board(wb)
		stroke_i = 0
		wb._select("ink", Whiteboard.INKS[strokes % Whiteboard.INKS.size()])
	var k := float(stroke_i) / STROKE_POINTS
	var uv := Vector2(0.1 + 0.8 * k, 0.14 + 0.12 * strokes + 0.04 * sin(k * TAU * 2.0))
	var n := wb.global_basis.z
	wb.pointer_ray(wb.to_global(wb.local_point(uv.x, uv.y)) + n * 0.3, -n, stroke_i < STROKE_POINTS)
	stroke_i += 1
	if stroke_i > STROKE_POINTS:
		wb.pointer_leave()
		stroke_i = -1
		strokes += 1

func _place_board(wb: Whiteboard) -> void:
	var me := Vector3(0.0, 1.5, 0.0)
	var you := me + Vector3(3.2, 0.1, 0.0)
	for p in room.get_children():
		if p is Participant and p.visible:
			you = p._head.global_position
			break
	var side := Vector3(you.x - me.x, 0.0, you.z - me.z).normalized()
	var at := me + side * 1.3 + Vector3(0.0, -0.05, -0.45)
	if not wb.visible:
		wb.set_shown(true)
	wb.global_transform = Transform3D(LaserDrag.facing_basis(at, you), at)

func _pose(side: StringName, xform: Transform3D) -> void:
	pads[side].set_pose(&"aim", xform, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)

func _status() -> void:
	var states := ["not in a room", "joining…", "in the room"]
	var line := "[Bot] %s" % states[room.state]
	for p in room.people():
		if not p.me:
			line += " · with %s (mic %s, screens: %s)" % [p.name, "on" if p.mic else "off",
				p.screens if not p.screens.is_empty() else "not shared"]
	if room.voice_from == "":
		line += " · heard %d voice packets, repeated %d" % [heard, repeated]
	print(line)

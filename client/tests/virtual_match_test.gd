extends SceneTree
## The 1:1 virtual screen size and the pointed-screen reference, headless:
##   godot --headless --xr-mode off --path client/project \
##       -s "$PWD/client/tests/virtual_match_test.gd"
## Prints "RESULT fails=N".

var fails := 0

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	var m = load("res://scripts/main.gd")
	# 1.6 m wide at 1.25 m: 65.2 deg; at 20 px/deg that is 1305 px -> 1304 x 736.
	var s: Vector2i = m.one_to_one_size(1.6, 1.25, 16.0 / 9.0, 20.0)
	check(s == Vector2i(1304, 736), "1.6 m at 1.25 m, 20 ppd -> %s" % [s])
	check(s.x % 8 == 0 and s.y % 8 == 0, "multiples of 8")
	var far: Vector2i = m.one_to_one_size(1.6, 4.0, 16.0 / 9.0, 40.0)
	check(far.x < s.x, "further away needs fewer pixels -> %s" % [far])
	check(m.one_to_one_size(0.3, 5.0, 1.78, 10.0) == Vector2i(640, 480), "clamped up to 640 x 480 floor -> %s" % [m.one_to_one_size(0.3, 5.0, 1.78, 10.0)])
	check(m.one_to_one_size(6.0, 0.5, 1.78, 40.0) == Vector2i(3840, 2160), "clamped down to 3840 x 2160")
	check(m.pick_reference(102, [100, 102, 101]) == 1, "pointer's screen is the reference")
	check(m.pick_reference(7, [100, 102]) == 0, "unknown pointed screen falls back to the first")
	check(m.pick_reference(-1, []) == -1, "no screens, no reference")
	print("RESULT fails=%d" % fails)
	quit(fails)

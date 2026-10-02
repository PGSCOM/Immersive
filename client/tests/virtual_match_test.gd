extends SceneTree
## Virtual screen size maths (virtual_size.gd) and the pointed-screen
## reference, headless:
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
	var V = load("res://scripts/virtual_size.gd")
	# 1.6 m wide at 1.25 m: 65.2 deg; at 20 px/deg that is 1305 px -> 1304 x 736.
	var s: Vector2i = V.one_to_one(1.6, 1.25, 16.0 / 9.0, 20.0)
	check(s == Vector2i(1304, 736), "1.6 m at 1.25 m, 20 ppd -> %s" % [s])
	check(s.x % 8 == 0 and s.y % 8 == 0, "multiples of 8")
	var far: Vector2i = V.one_to_one(1.6, 4.0, 16.0 / 9.0, 40.0)
	check(far.x < s.x, "further away needs fewer pixels -> %s" % [far])
	var tiny: Vector2i = V.one_to_one(0.3, 5.0, 1.78, 10.0)
	check(tiny == Vector2i(856, 480), "scaled up to the 480 floor, shape kept -> %s" % [tiny])
	check(V.one_to_one(6.0, 0.5, 1.78, 40.0) == Vector2i(3840, 2160), "1:1 stops at 3840 a side")
	var tall: Vector2i = V.one_to_one(1.2, 0.6, 9.0 / 16.0, 40.0)
	check(tall.y == 3840 and absf(float(tall.x) / tall.y - 0.5625) < 0.01, "a portrait 1:1 keeps its shape -> %s" % [tall])

	# What the host makes: 640..7680 x 480..4320, the shape kept.
	check(V.fit(10000.0, 2812.5) == Vector2i(7680, 2160), "fit: 32:9 down to 7680 wide")
	check(V.fit(300.0, 600.0) == Vector2i(640, 1280), "fit: portrait up to 640 wide")

	# Every preset is its shape and something the host makes.
	var all_ok := true
	for i in V.SHAPES.size():
		for p: Vector2i in V.SHAPES[i][2]:
			if V.shape_of(p.x, p.y) != i or V.shape_of(p.y, p.x) != i or p.x > V.MAX.x \
					or p.y > V.MAX.y or p.x % 2 or p.y % 2:
				all_ok = false
				print("  bad preset %s for %s" % [p, V.SHAPES[i][0]])
	check(all_ok, "every preset has its shape, either way up, within 7680 x 4320")
	check(V.shape_of(3000, 1250) == -1, "3000 x 1250 has no listed shape")

	# How big a new screen hangs: the 16:9 one's area, never too wide or tall.
	check(is_equal_approx(V.default_width_m(16.0 / 9.0), 1.6), "16:9 hangs 1.6 m wide, as before")
	var p_w: float = V.default_width_m(9.0 / 16.0)
	check(is_equal_approx(p_w / (9.0 / 16.0), V.MAX_H_M), "portrait 9:16 stops at %.1f m tall (%.2f m wide)" % [V.MAX_H_M, p_w])
	var u_w: float = V.default_width_m(32.0 / 9.0)
	check(u_w > 2.0 and u_w <= V.MAX_W_M, "32:9 hangs wider (%.2f m)" % u_w)
	# A replaced screen keeps its width, or is rescaled for a new shape.
	check(V.replaced_width_m(2.0, 16.0 / 9.0, 2560.0 / 1440.0) == 2.0, "same shape: same width")
	check(is_equal_approx(V.replaced_width_m(2.0, 16.0 / 9.0, 9.0 / 16.0), 2.0 * p_w / 1.6),
		"16:9 to portrait: scaled like the defaults")

	# H.264 Level 5.2, as the host fits it (fit_h264 in host/src/main.cpp).
	check(V.h264_size(7680, 2160) == Vector2i(4096, 1152), "H.264: 7680 x 2160 -> 4096 x 1152")
	check(V.h264_size(5120, 1440) == Vector2i(4096, 1152), "H.264: 5120 x 1440 -> 4096 x 1152")
	check(V.h264_size(7680, 4320) == Vector2i(4096, 2304), "H.264: 7680 x 4320 -> 4096 x 2304")
	check(V.h264_size(3840, 2160) == Vector2i(3840, 2160), "H.264: 3840 x 2160 whole")
	check(V.h264_size(2160, 3840) == Vector2i(2160, 3840), "H.264: portrait 2160 x 3840 whole")
	var big: Vector2i = V.h264_size(3840, 2560)
	check(ceili(big.x / 16.0) * ceili(big.y / 16.0) <= 36864 and big.x % 16 == 0,
		"H.264: 3840 x 2560 into 36864 macroblocks -> %s" % [big])

	check(m.pick_reference(102, [100, 102, 101]) == 1, "pointer's screen is the reference")
	check(m.pick_reference(7, [100, 102]) == 0, "unknown pointed screen falls back to the first")
	check(m.pick_reference(-1, []) == -1, "no screens, no reference")
	print("RESULT fails=%d" % fails)
	quit(fails)

## Tests for the shared whiteboard (whiteboard.gd).
## Run headlessly via the project test runner:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## Covers: ray → UV geometry, multi-user stroke bookkeeping, live drawing onto the
## board image, remote-stroke application, serialise round-trip, clear, and the
## high-resolution snapshot save.

extends RefCounted

const BoardScript := preload("res://scripts/whiteboard.gd")

func _assert(condition: bool, message: String, passed: Array, failed: Array) -> void:
	if condition:
		passed.append(message)
		print("  PASS: %s" % message)
	else:
		failed.append(message)
		print("  FAIL: %s" % message)

## Colour compare with a tolerance (8-bit textures quantise float colours, so an
## exact is_equal_approx against the source Color fails).
func _color_close(a: Color, b: Color, tol: float = 0.02) -> bool:
	return abs(a.r - b.r) <= tol and abs(a.g - b.g) <= tol \
		and abs(a.b - b.b) <= tol

func run_all(results: Dictionary, tree: SceneTree) -> void:
	print("\n=== Whiteboard Tests ===")
	var passed: Array = []
	var failed: Array = []

	test_ray_to_uv(passed, failed)
	test_multi_user_strokes(passed, failed, tree)
	test_drawing_and_snapshot(passed, failed, tree)
	test_serialisation_roundtrip(passed, failed)
	test_remote_stroke_and_clear(passed, failed, tree)

	print("\n=== Whiteboard Results: Passed %d / Failed %d ===" % [passed.size(), failed.size()])
	results["passed"] = passed.size()
	results["failed"] = failed.size()
	results["failed_messages"] = failed.duplicate()

func test_ray_to_uv(passed: Array, failed: Array) -> void:
	print("\nTest: whiteboard ray → UV")
	var xform := Transform3D(Basis(), Vector3(0.0, 1.5, -2.0))
	var size := BoardScript.BOARD_SIZE

	# Centre ray → UV (0.5, 0.5).
	var c := BoardScript.ray_to_board_uv(xform, size, Vector3(0.0, 1.5, 0.0), Vector3(0.0, 0.0, -1.0))
	_assert(c.get("valid", false), "centre ray hits the board", passed, failed)
	if c.get("valid", false):
		var uv: Vector2 = c["uv"]
		_assert(abs(uv.x - 0.5) < 0.001 and abs(uv.y - 0.5) < 0.001, "centre maps to UV (0.5,0.5)", passed, failed)

	# Just inside the top-left corner (local x=-0.49w, y=+0.49h) → UV ≈ (0.01, 0.01).
	# Use an inset so the test isn't on the knife-edge of the rectangle bounds.
	var tl_world := Vector3(-size.x * 0.49, 1.5 + size.y * 0.49, 0.0)
	var tl := BoardScript.ray_to_board_uv(xform, size, tl_world, Vector3(0.0, 0.0, -1.0))
	_assert(tl.get("valid", false), "near top-left ray hits the board", passed, failed)
	if tl.get("valid", false):
		var uv: Vector2 = tl["uv"]
		_assert(uv.x < 0.05 and uv.y < 0.05, "top-left maps toward UV (0,0)", passed, failed)

	# Ray outside the board misses.
	var miss := BoardScript.ray_to_board_uv(xform, size, Vector3(5.0, 1.5, 0.0), Vector3(0.0, 0.0, -1.0))
	_assert(not miss.get("valid", false), "ray outside the board misses", passed, failed)

func test_multi_user_strokes(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: multiple users draw simultaneously")
	var board = BoardScript.new()
	tree.root.add_child(board)

	board.begin_stroke(1, Vector2(0.1, 0.1), Color.RED)
	board.begin_stroke(2, Vector2(0.9, 0.9), Color.BLUE)
	_assert(board.get_active_count() == 2, "two simultaneous in-progress strokes", passed, failed)

	board.append_point(1, Vector2(0.5, 0.5))
	board.append_point(2, Vector2(0.5, 0.5))
	board.end_stroke(1)
	_assert(board.get_active_count() == 1, "one stroke still active after user 1 ends", passed, failed)
	_assert(board.get_stroke_count() == 1, "one finished stroke committed", passed, failed)

	board.end_stroke(2)
	_assert(board.get_stroke_count() == 2, "both strokes committed", passed, failed)
	_assert(board.get_active_count() == 0, "no active strokes left", passed, failed)

	board.queue_free()

func test_drawing_and_snapshot(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: drawing changes pixels + snapshot save")
	var board = BoardScript.new()
	tree.root.add_child(board)

	var before := board.snapshot()
	var bg := before.get_pixel(BoardScript.TEX_W / 2, BoardScript.TEX_H / 2)
	_assert(_color_close(bg, BoardScript.BG_COLOR), "fresh board is the background colour", passed, failed)

	# Draw a horizontal line straight through the centre.
	board.begin_stroke(7, Vector2(0.1, 0.5), Color.BLACK)
	board.append_point(7, Vector2(0.9, 0.5))
	board.end_stroke(7)

	var after := board.snapshot()
	var centre := after.get_pixel(BoardScript.TEX_W / 2, BoardScript.TEX_H / 2)
	_assert(not _color_close(centre, BoardScript.BG_COLOR), "centre pixel changed after drawing", passed, failed)
	_assert(after.get_size() == Vector2i(BoardScript.TEX_W, BoardScript.TEX_H),
		"snapshot is full board resolution", passed, failed)

	var path := "user://_test_whiteboard_snapshot.png"
	_assert(board.save_snapshot(path), "save_snapshot writes a PNG", passed, failed)
	_assert(FileAccess.file_exists(path), "snapshot PNG exists on disk", passed, failed)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	board.queue_free()

func test_serialisation_roundtrip(passed: Array, failed: Array) -> void:
	print("\nTest: stroke serialise round-trip")
	var stroke := {
		"user_id": 42,
		"color": Color(0.2, 0.4, 0.8),
		"points": PackedVector2Array([Vector2(0.1, 0.2), Vector2(0.3, 0.4), Vector2(0.5, 0.6)]),
	}
	var d := BoardScript.stroke_to_dict(stroke)
	_assert(int(d["user_id"]) == 42, "serialised user_id preserved", passed, failed)
	_assert((d["points"] as Array).size() == 6, "points flattened to [x,y,...]", passed, failed)

	var back := BoardScript.stroke_from_dict(d)
	var pts: PackedVector2Array = back["points"]
	_assert(pts.size() == 3, "deserialised back to 3 points", passed, failed)
	_assert(pts[1].is_equal_approx(Vector2(0.3, 0.4)), "point round-trips", passed, failed)
	_assert((back["color"] as Color).is_equal_approx(Color(0.2, 0.4, 0.8)), "colour round-trips", passed, failed)

func test_remote_stroke_and_clear(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: remote stroke application + clear")
	var board = BoardScript.new()
	tree.root.add_child(board)

	var remote := {
		"user_id": 99,
		"color": Color.GREEN,
		"points": PackedVector2Array([Vector2(0.2, 0.2), Vector2(0.8, 0.8)]),
	}
	board.apply_remote_stroke(remote)
	_assert(board.get_stroke_count() == 1, "remote stroke added to the board", passed, failed)

	# last_stroke_serialized returns the remote stroke flattened.
	var ser := board.last_stroke_serialized()
	_assert(int(ser.get("user_id", -1)) == 99, "last_stroke_serialized returns the remote author", passed, failed)

	board.clear_board()
	_assert(board.get_stroke_count() == 0, "clear removes all strokes", passed, failed)
	var px := board.snapshot().get_pixel(BoardScript.TEX_W / 2, BoardScript.TEX_H / 2)
	_assert(_color_close(px, BoardScript.BG_COLOR), "board image reset to background after clear", passed, failed)

	board.queue_free()

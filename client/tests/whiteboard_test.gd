extends SceneTree
## The whiteboard, headless:
##   - a ray with the trigger / pinch held draws a stroke; a ray elsewhere misses;
##   - a fingertip hovering in front of it draws nothing, touching it draws,
##     lifting it ends the stroke; while one hand owns it the other hand and the
##     ray do not draw;
##   - the tool row works with the pointer (eraser), undo, and clear (undoable);
##   - a corner handle resizes it, aspect kept, the opposite corner fixed.
##
##   godot --headless --xr-mode off --fixed-fps 72 --path client/project \
##       -s "$PWD/client/tests/whiteboard_test.gd"
##
## Prints one ok/FAIL line per check and "RESULT fails=N".

var fails := 0
var head: Camera3D
var wb: Whiteboard

func _initialize() -> void:
	var main := Node3D.new()
	main.name = "Main"
	root.add_child(main)
	head = Camera3D.new()
	head.position = Vector3(0, 1.6, 0)
	main.add_child(head)
	head.current = true
	wb = Whiteboard.new()
	main.add_child(wb)
	_run()

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _frames(n: int) -> void:
	for i in n:
		await process_frame

## World point on the board at viewport pixel `px`, `depth` in front of it.
func _at(px: Vector2, depth := 0.0) -> Vector3:
	var uv := px / Vector2(Whiteboard.VIEW_SIZE)
	return wb.to_global(wb.local_point(uv.x, uv.y) + Vector3(0, 0, depth))

func _ray(px: Vector2, pressing: bool) -> float:
	return wb.pointer_ray(head.position, (_at(px) - head.position).normalized(), pressing)

func _run() -> void:
	await _frames(1)
	wb.set_shown(true)
	check(wb.global_basis.z.dot((head.position - wb.global_position).normalized()) > 0.99,
		"shown in front of the head, facing it")
	check(wb.pointer_ray(head.position, Vector3.UP, true) < 0.0, "a ray at the sky misses it")

	# --- Ray drawing ----------------------------------------------------------
	_ray(Vector2(300, 300), false)
	check(wb.stroke_count() == 0, "pointing without pressing draws nothing")
	_ray(Vector2(300, 300), true)
	for i in 20:
		_ray(Vector2(300 + i * 20, 300 + i * 5), true)
	_ray(Vector2(700, 400), false)
	check(wb.stroke_count() == 1 and wb._ink.get_child(0).points.size() > 5,
		"trigger held + moving draws one stroke (%d points)" % wb._ink.get_child(0).points.size())

	# --- Fingertip ------------------------------------------------------------
	check(wb.touch(0, _at(Vector2(400, 600), 0.05)), "a fingertip 5 cm in front owns the board")
	check(wb.stroke_count() == 1 and wb._ring > 0.5, "hovering draws nothing, shows the wide ring")
	check(not wb.touch(1, _at(Vector2(500, 600), 0.0)), "the other hand cannot draw meanwhile")
	_ray(Vector2(800, 700), true)
	_ray(Vector2(900, 700), true)
	check(wb.stroke_count() == 1, "nor can the ray")
	for i in 15:
		wb.touch(0, _at(Vector2(400 + i * 15, 600), 0.004))
	check(wb.stroke_count() == 2, "touching it draws")
	wb.touch(0, _at(Vector2(625, 600), 0.015))
	check(wb._pointer_pressed, "within the release band it keeps drawing (hysteresis)")
	wb.touch(0, _at(Vector2(625, 600), 0.03))
	check(not wb._pointer_pressed, "lifting it 3 cm ends the stroke")
	check(not wb.touch(0, _at(Vector2(625, 600), 0.2)), "20 cm away it lets go")
	check(wb.touch(1, _at(Vector2(500, 600), 0.05)), "then the other hand can have it")
	wb.touch(1, _at(Vector2(500, 600), 0.2))
	_ray(Vector2(900, 700), false)

	# --- Tools ----------------------------------------------------------------
	var eraser: Vector2 = wb._btn_eraser.get_global_rect().get_center()
	_ray(eraser, false)
	_ray(eraser, true)
	_ray(eraser, false)
	check(wb._erasing, "the Eraser button turns the eraser on")
	_ray(Vector2(500, 300), true)
	_ray(Vector2(520, 320), true)
	_ray(Vector2(520, 320), false)
	var last: Line2D = wb._ink.get_child(-1)
	check(wb.stroke_count() == 3 and last.default_color == Whiteboard.SLATE \
		and last.width == Whiteboard.ERASER_PX, "it erases with a wide slate stroke")
	wb.undo()
	check(wb.stroke_count() == 2, "undo takes the last stroke away")
	wb.clear()
	check(wb.stroke_count() == 0, "clear empties the board")
	wb.undo()
	check(wb.stroke_count() == 2, "undo brings the cleared strokes back")

	# --- Resize ---------------------------------------------------------------
	var handle: ResizeHandle = wb.resize_handles[3]  # bottom-right
	var fixed := wb.to_global(wb.local_point(0, 0))
	var w0 := wb.panel_width
	var pointer := Node3D.new()
	wb.get_parent().add_child(pointer)
	pointer.global_position = head.position + Vector3(0.2, -0.3, 0)
	pointer.look_at(handle.global_position)
	var d := handle.probe(pointer.global_position, -pointer.global_basis.z)
	check(d > 0.0, "the corner handle is in reach of the ray")
	handle.start_drag(pointer, d)
	pointer.look_at(handle.global_position + wb.global_basis.x * 0.3 - wb.global_basis.y * 0.2)
	await _frames(40)
	handle.stop_drag()
	var aspect := wb.panel_width / wb.panel_height
	check(wb.panel_width > w0 + 0.2, "dragging the corner out grows it (%.2f -> %.2f m)" % [w0, wb.panel_width])
	check(absf(aspect - float(Whiteboard.VIEW_SIZE.x) / Whiteboard.VIEW_SIZE.y) < 0.001, "aspect kept")
	check(wb.to_global(wb.local_point(0, 0)).distance_to(fixed) < 0.005, "the opposite corner stays put")
	wb.set_panel_width(10.0)
	check(is_equal_approx(wb.panel_width, Whiteboard.MAX_WIDTH), "size clamped")

	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)

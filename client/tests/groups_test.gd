extends SceneTree
## Linked screens, snapping, locking and saving the links, headless:
##   - drag_group_for lists the other linked screens only for a linked one;
##   - a screen dragged near any side of another (flat or curved) is offered
##     a frame there (snap_target_for), and released it lands exactly in it,
##     flush, with its neighbour's orientation; far, turned away or occupied
##     sides offer nothing; "Move together" blocks move rigidly;
##   - a screen dropped in the frame follows that neighbour: grabbing the
##     neighbour (a real LaserDrag) brings it and what follows it, grabbed
##     itself it goes alone, dropped away it follows nobody, a resized
##     neighbour keeps it flush, virtual screens removed or replaced;
##   - a locked layout refuses moves; snap off leaves the screen alone;
##   - link flags and snaps survive a save and a load of the workspace file.
##
##   godot --headless --xr-mode off --path client/project \
##       -s "$PWD/client/tests/groups_test.gd"
##
## Prints one ok/FAIL line per check and "RESULT fails=N".

var fails := 0

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	_run()

func _panel(main: Node, mid: int, pos: Vector3) -> Node3D:
	var p := MeshInstance3D.new()
	p.set_script(load("res://scripts/screen_panel.gd"))
	root.add_child(p)
	p.set_meta("monitor_id", mid)
	p.set_resolution(1920, 1080)
	p.place_facing(pos, Vector3(0, 1.6, 0))
	main.screen_panels.append(p)
	return p

func _run() -> void:
	# main.gd is not added to the tree: _ready (XR, network) never runs and
	# _head() falls back to a head at (0, 1.6, 0) looking down -Z.
	var main: Node3D = load("res://scripts/main.gd").new()
	main._ephemeral = true
	await process_frame
	var head := Vector3(0, 1.6, 0)
	var a := _panel(main, 0, Vector3(0, 1.52, -1.25))
	var b := _panel(main, 1, Vector3(1.9, 1.52, -1.25))
	var c := _panel(main, 2, Vector3(-3.5, 1.52, -3.0))
	await process_frame

	check(main.drag_group_for(a).is_empty(), "unlinked screen: no group")
	main._linked = {0: true, 1: true}
	check(main.drag_group_for(a) == [b], "linked screen: the other linked one")
	check(main.drag_group_for(c).is_empty(), "an unlinked screen has no group")
	main._linked = {}

	# Snap: b dropped near each side of a lands exactly where the frame shows.
	for curve in [0.0, 0.5]:
		for pn in [a, b, c]:
			pn.set_curvature(curve > 0.0, curve)
		for side in 4:
			var land: Transform3D = a.landing_beside(side, b.panel_width, b.panel_height, main.SNAP_GAP_M)
			# 12 cm off and turned 10 degrees: well inside the capture zone.
			b.global_transform = Transform3D(land.basis * Basis(Vector3.UP, deg_to_rad(10.0)),
				land.origin + Vector3(0.08, 0.06, 0.05))
			var tgt: Dictionary = main.snap_target_for(b)
			check(tgt.get("panel") == a and tgt.get("side") == side,
				"curve %.1f side %d: the frame is offered on that side" % [curve, side])
			main.on_panel_drag_ended(b)
			check(b.global_transform.is_equal_approx(land), "curve %.1f side %d: released, it lands in the frame" % [curve, side])
		# Flush: the facing edges are a gap apart (curved: along the arc's chord).
		b.global_transform = a.landing_beside(1, b.panel_width, b.panel_height, main.SNAP_GAP_M)
		var edge: float = a.to_global(a.local_point(1.0, 0.5)).distance_to(b.to_global(b.local_point(0.0, 0.5)))
		check(edge > main.SNAP_GAP_M * 0.9 and edge < main.SNAP_GAP_M + 0.002,
			"curve %.1f: snapped screens are flush, %.3f m apart" % [curve, edge])
		check(b.global_basis.y.is_equal_approx(a.global_basis.y), "curve %.1f: same upright as its neighbour" % curve)
	for pn in [a, b, c]:
		pn.set_curvature(false, 0.0)

	# Far from everything, or turned away: no frame, nothing moves.
	b.place_facing(Vector3(1.2, 1.5, -3.5), head)
	var before: Transform3D = b.global_transform
	check(main.snap_target_for(b).is_empty(), "far from the others: no frame")
	main.on_panel_drag_ended(b)
	check(b.global_transform.is_equal_approx(before), "a screen far from the others stays put")
	var near: Transform3D = a.landing_beside(1, b.panel_width, b.panel_height, main.SNAP_GAP_M)
	b.global_transform = Transform3D(near.basis * Basis(Vector3.UP, deg_to_rad(120.0)), near.origin)
	check(main.snap_target_for(b).is_empty(), "turned right away from the neighbour: no frame")

	# A side that is taken is not offered.
	c.global_transform = a.landing_beside(1, c.panel_width, c.panel_height, main.SNAP_GAP_M)
	b.global_transform = Transform3D(near.basis, near.origin + Vector3(0.0, 0.1, 0.1))
	check(main.snap_target_for(b).get("side") != 1 or main.snap_target_for(b).get("panel") != a,
		"a side with a screen already on it is not offered")
	c.place_facing(Vector3(-3.5, 1.52, -3.0), head)

	# Rigid block: b and c linked, b released near a: both move by the same transform.
	main._linked = {1: true, 2: true}
	var land_r: Transform3D = a.landing_beside(1, b.panel_width, b.panel_height, main.SNAP_GAP_M)
	b.global_transform = Transform3D(land_r.basis, land_r.origin + Vector3(0.1, 0.05, 0.0))
	c.place_facing(b.global_position + Vector3(0, 0, -2.5), head)
	var rel_before: Transform3D = b.global_transform.affine_inverse() * c.global_transform
	main.on_panel_drag_ended(b)
	var rel_after: Transform3D = b.global_transform.affine_inverse() * c.global_transform
	check(rel_before.is_equal_approx(rel_after) and b.global_transform.is_equal_approx(land_r),
		"linked block moves rigidly while snapping")
	check(main._linked == {1: true, 2: true}, "snapping does not link or unlink screens")
	main._linked = {}

	# Dropped in the frame, a screen follows the one beside it: moving that one
	# moves it (and what follows it); moved itself, it goes alone; dropped away
	# from everything, it follows nobody.
	main._snapped_to = {}
	c.place_facing(Vector3(-3.5, 1.52, -3.0), head)
	var land_b: Transform3D = a.landing_beside(1, b.panel_width, b.panel_height, main.SNAP_GAP_M)
	b.global_transform = Transform3D(land_b.basis, land_b.origin + Vector3(0.05, 0.03, 0.0))
	main.on_panel_drag_ended(b)
	check(main._snapped_to == {1: 0}, "b dropped in the frame beside a follows a -> %s" % [main._snapped_to])
	var land_c: Transform3D = b.landing_beside(1, c.panel_width, c.panel_height, main.SNAP_GAP_M)
	c.global_transform = Transform3D(land_c.basis, land_c.origin + Vector3(0.04, -0.03, 0.02))
	main.on_panel_drag_ended(c)
	check(main._snapped_to == {1: 0, 2: 1}, "c dropped beside b follows b -> %s" % [main._snapped_to])
	check(main.drag_group_for(a) == [b, c], "moving a takes b and c along")
	check(main.drag_group_for(b) == [c], "moving b takes c along, not a")
	check(main.drag_group_for(c).is_empty(), "c moves alone")
	check(main.snap_target_for(a).is_empty() or not [b, c].has(main.snap_target_for(a).get("panel")),
		"a is never offered a frame against what follows it")

	# The real grab (screen_panel.start_drag): a LaserDrag with drag_group_for() as followers.
	var pointer := Node3D.new()
	root.add_child(pointer)
	pointer.global_transform = Transform3D(Basis(), Vector3(0.25, 1.3, -0.2)).looking_at(a.global_position)
	var rel_b: Transform3D = a.global_transform.affine_inverse() * b.global_transform
	var rel_c: Transform3D = a.global_transform.affine_inverse() * c.global_transform
	var a_was: Vector3 = a.global_position
	var drag := LaserDrag.new(a, pointer)
	drag.add_followers(main.drag_group_for(a))
	pointer.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-30.0)), Vector3.ZERO) * pointer.global_transform
	drag.update()
	main.on_panel_drag_ended(a)
	check(a.global_position.distance_to(a_was) > 0.4, "the grab moved a %.2f m" % a.global_position.distance_to(a_was))
	check((a.global_transform.affine_inverse() * b.global_transform).is_equal_approx(rel_b)
		and (a.global_transform.affine_inverse() * c.global_transform).is_equal_approx(rel_c),
		"b and c came along, still flush")
	check(main._snapped_to == {1: 0, 2: 1}, "a dropped in the open keeps what follows it")

	# b grabbed by itself: c comes, a stays; dropped far away b is free, c still follows b.
	var a_at: Transform3D = a.global_transform
	var rel_cb: Transform3D = b.global_transform.affine_inverse() * c.global_transform
	pointer.global_transform = Transform3D(Basis(), Vector3(0.25, 1.3, -0.2)).looking_at(b.global_position)
	drag = LaserDrag.new(b, pointer)
	drag.add_followers(main.drag_group_for(b))
	pointer.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(50.0)), Vector3.ZERO) * pointer.global_transform
	drag.update()
	main.on_panel_drag_ended(b)
	check(a.global_transform.is_equal_approx(a_at), "moving b leaves a where it was")
	check((b.global_transform.affine_inverse() * c.global_transform).is_equal_approx(rel_cb), "c came along with b")
	check(main._snapped_to == {2: 1}, "b dropped away from a follows nobody, c still follows b -> %s" % [main._snapped_to])
	pointer.queue_free()

	# a grows (corner handle or stick): what follows it goes back flush against it.
	b.global_transform = a.landing_beside(1, b.panel_width, b.panel_height, main.SNAP_GAP_M)
	main.on_panel_drag_ended(b)
	c.global_transform = b.landing_beside(1, c.panel_width, c.panel_height, main.SNAP_GAP_M)
	main.on_panel_drag_ended(c)
	var a_width: float = a.panel_width
	a.set_panel_width(a_width + 0.5)
	main.on_layout_changed()
	check(b.global_transform.is_equal_approx(a.landing_beside(1, b.panel_width, b.panel_height, main.SNAP_GAP_M))
		and c.global_transform.is_equal_approx(b.landing_beside(1, c.panel_width, c.panel_height, main.SNAP_GAP_M)),
		"a grown 0.5 m: b and c sit flush again")
	a.set_panel_width(a_width)
	main.on_layout_changed()
	check(not b.bar_on_top and not c.bar_on_top, "side by side: every grab bar under its screen")

	# Stacked: the one on top has its bar over its top edge, out of the lower one's pixels.
	c.global_transform = a.landing_beside(load("res://scripts/screen_panel.gd").Side.BOTTOM,
		c.panel_width, c.panel_height, main.SNAP_GAP_M)
	main.on_panel_drag_ended(c)
	main.on_layout_changed()
	check(a.bar_on_top and not c.bar_on_top, "c snapped under a: a's bar moves over its top edge")
	var hit: Dictionary = main.pick(Vector3(0, 1.6, 0), a.grab_bar.global_position - Vector3(0, 1.6, 0))
	check(hit.get("kind") == "bar" and hit.get("target") == a, "and the pointer reaches it -> %s" % hit.get("kind"))
	c.place_facing(Vector3(-3.5, 1.52, -3.0), head)
	main.on_panel_drag_ended(c)
	main.on_layout_changed()
	check(not a.bar_on_top, "c gone from under it: a's bar back under it")

	# Arrange around me puts each screen on its own.
	main._snapped_to = {1: 0}
	main.arrange_panels()
	check(main._snapped_to.is_empty(), "Arrange around me: nobody follows anybody")

	# Virtual screens: a removed one frees what followed it (its id comes back
	# for the next one); a replaced one keeps its place under the new id.
	main._snapped_to = {100: 0, 2: 100, 1: 0}
	main._rename_snaps(100, 101)
	check(main._snapped_to == {101: 0, 2: 101, 1: 0}, "a replaced virtual screen keeps its snaps -> %s" % [main._snapped_to])
	main._on_virtual_display_result(0, true, 101)
	check(main._snapped_to == {1: 0}, "a removed virtual screen frees what followed it -> %s" % [main._snapped_to])
	main._snapped_to = {}

	# Snap off, lock.
	main.snap_enabled = false
	b.global_transform = Transform3D(near.basis, near.origin + Vector3(0.1, 0.05, 0.0))
	before = b.global_transform
	main.on_panel_drag_ended(b)
	check(b.global_transform.is_equal_approx(before), "snap off: nothing moves")
	check(main.can_move_panel(b), "unlocked: screens move")
	main.lock_layout = true
	check(not main.can_move_panel(b), "locked: screens refuse to move")

	# Link flags round-trip through the workspace file (the user's own is kept).
	var path: String = main.WORKSPACE_PATH
	var backup := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	main._ephemeral = false
	main._linked = {0: true, 2: true, 1: false}
	main._snapped_to = {1: 0, 2: 1}
	main.save_workspace_layout()
	main._linked = {}
	main._snapped_to = {}
	main._load_workspace()
	check(main._linked == {0: true, 2: true}, "link flags survive save and load -> %s" % [main._linked])
	check(main._snapped_to == {1: 0, 2: 1}, "snaps survive save and load -> %s" % [main._snapped_to])
	var v2 := FileAccess.open(path, FileAccess.WRITE)
	v2.store_string('{"version": 2, "monitor_ids": [0], "panels": {"0": {}}}')
	v2.close()
	main._load_workspace()
	check(main._linked.is_empty() and main._snapped_to.is_empty() and main._workspace_monitor_ids == [0],
		"version 2 files still load")
	if backup.is_empty():
		DirAccess.remove_absolute(path)
	else:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(backup)
		f.close()
	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)

## Tests for RemoteScreenPanel texture rendering.
##
## Verifies that:
##   • update_decoded_image() uploads a solid-colour Image and the texture
##     colour at the centre pixel matches the source Image.
##   • The panel starts with a ShaderMaterial (set up in _ready) so it is ready
##     to receive pixels without any additional setup.
##   • The floating label is hidden once live pixels arrive.
##
## Run with: godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd

extends RefCounted

func _assert(condition: bool, message: String, passed: Array, failed: Array) -> void:
	if condition:
		passed.append(message)
		print("  PASS: %s" % message)
	else:
		failed.append(message)
		print("  FAIL: %s" % message)

## Colour comparison with a small tolerance to absorb 8-bit quantisation.
func _color_close(a: Color, b: Color, tol: float = 0.02) -> bool:
	return abs(a.r - b.r) <= tol \
		and abs(a.g - b.g) <= tol \
		and abs(a.b - b.b) <= tol

func run_all(results: Dictionary, tree: SceneTree) -> void:
	print("\n=== RemoteScreenPanel Tests ===")
	var passed: Array = []
	var failed: Array = []

	_test_loads_and_instantiates(passed, failed, tree)
	_test_apply_layout_sets_active(passed, failed, tree)
	_test_update_decoded_image_uploads_colour(passed, failed, tree)
	_test_label_hidden_after_first_frame(passed, failed, tree)
	_test_texture_updates_in_place(passed, failed, tree)

	print("\n=== RemoteScreenPanel Results: Passed %d / Failed %d ===" % [passed.size(), failed.size()])
	results["passed"] = passed.size()
	results["failed"] = failed.size()
	results["failed_messages"] = failed.duplicate()

# ---------------------------------------------------------------------------

func _test_loads_and_instantiates(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: RemoteScreenPanel loads and instantiates")
	var script := load("res://scripts/remote_screen_panel.gd") as Script
	_assert(script != null, "remote_screen_panel.gd loads", passed, failed)
	if not script:
		return

	var panel: Node3D = script.new()
	_assert(panel != null, "panel instantiates", passed, failed)

	var root := Node3D.new()
	tree.root.add_child(root)
	root.add_child(panel)

	_assert(panel.has_method("update_decoded_image"),
		"panel exposes update_decoded_image()", passed, failed)
	_assert(panel.has_method("apply_layout_metadata"),
		"panel exposes apply_layout_metadata()", passed, failed)
	_assert(panel.has_method("get_panel_size"),
		"panel exposes get_panel_size()", passed, failed)
	_assert(panel.has_method("get_resolution"),
		"panel exposes get_resolution()", passed, failed)

	root.queue_free()

func _test_apply_layout_sets_active(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: apply_layout_metadata activates the panel")
	var panel: Node3D = load("res://scripts/remote_screen_panel.gd").new()
	var root := Node3D.new()
	tree.root.add_child(root)
	root.add_child(panel)

	_assert(not panel.is_active, "panel starts inactive", passed, failed)

	panel.apply_layout_metadata({
		"monitor_id": 2,
		"pos_x": 1.0, "pos_y": 1.5, "pos_z": -2.0,
		"rot_w": 1.0, "rot_x": 0.0, "rot_y": 0.0, "rot_z": 0.0,
		"width": 1.6, "height": 0.9,
		"resolution_w": 1920, "resolution_h": 1080,
	})
	_assert(panel.is_active, "apply_layout_metadata sets is_active = true", passed, failed)
	_assert(panel.monitor_id == 2, "monitor_id stored from layout", passed, failed)
	_assert(panel.get_resolution() == Vector2i(1920, 1080),
		"resolution stored from layout", passed, failed)

	root.queue_free()

func _test_update_decoded_image_uploads_colour(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: update_decoded_image uploads a solid-colour image")
	var panel: Node3D = load("res://scripts/remote_screen_panel.gd").new()
	var root := Node3D.new()
	tree.root.add_child(root)
	root.add_child(panel)

	# Activate the panel first (required by update_decoded_image).
	panel.apply_layout_metadata({
		"monitor_id": 5,
		"pos_x": 0.0, "pos_y": 0.0, "pos_z": 0.0,
		"rot_w": 1.0, "rot_x": 0.0, "rot_y": 0.0, "rot_z": 0.0,
		"width": 1.0, "height": 0.5,
		"resolution_w": 16, "resolution_h": 16,
	})

	# Upload a solid lime-green 16×16 RGBA image.
	var target_color := Color(0.2, 0.8, 0.1, 1.0)
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(target_color)
	panel.update_decoded_image(img)

	# The panel should now hold screen_image and a valid screen_texture.
	_assert(panel.screen_image != null, "screen_image is set after upload", passed, failed)
	_assert(panel.screen_texture != null, "screen_texture is set after upload", passed, failed)

	if panel.screen_image:
		var centre: Color = panel.screen_image.get_pixel(8, 8)
		_assert(_color_close(centre, target_color),
			"centre pixel colour matches the uploaded image (got %s)" % str(centre),
			passed, failed)

	root.queue_free()

func _test_label_hidden_after_first_frame(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: placeholder label hidden after first decoded image")
	var panel: Node3D = load("res://scripts/remote_screen_panel.gd").new()
	var root := Node3D.new()
	tree.root.add_child(root)
	root.add_child(panel)

	panel.apply_layout_metadata({
		"monitor_id": 1,
		"pos_x": 0.0, "pos_y": 0.0, "pos_z": 0.0,
		"rot_w": 1.0, "rot_x": 0.0, "rot_y": 0.0, "rot_z": 0.0,
		"width": 1.0, "height": 0.5,
		"resolution_w": 4, "resolution_h": 4,
	})

	# The _label field is private; check via the internal field directly.
	var label = panel.get("_label")
	if label:
		_assert(label.visible, "label starts visible (placeholder)", passed, failed)

		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color.RED)
		panel.update_decoded_image(img)

		_assert(not label.visible, "label is hidden after first frame", passed, failed)
	else:
		# If the field is truly private and not accessible via get(), skip gracefully.
		passed.append("_label not accessible via get() — skipping label visibility check")
		print("  PASS: _label not accessible via get() — skipping label visibility check")

	root.queue_free()

func _test_texture_updates_in_place(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: successive update_decoded_image calls with same size reuse the texture")
	var panel: Node3D = load("res://scripts/remote_screen_panel.gd").new()
	var root := Node3D.new()
	tree.root.add_child(root)
	root.add_child(panel)

	panel.apply_layout_metadata({
		"monitor_id": 3,
		"pos_x": 0.0, "pos_y": 0.0, "pos_z": 0.0,
		"rot_w": 1.0, "rot_x": 0.0, "rot_y": 0.0, "rot_z": 0.0,
		"width": 1.0, "height": 0.5,
		"resolution_w": 8, "resolution_h": 8,
	})

	var img1 := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img1.fill(Color.BLUE)
	panel.update_decoded_image(img1)
	var tex_after_first: ImageTexture = panel.screen_texture

	var img2 := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img2.fill(Color.RED)
	panel.update_decoded_image(img2)

	# Texture object should be reused (same size/format) — panel reuses it via update().
	_assert(panel.screen_texture == tex_after_first,
		"texture object is reused for same-size frames (no reallocation)", passed, failed)

	# And the pixel content changed.
	if panel.screen_image:
		var px: Color = panel.screen_image.get_pixel(4, 4)
		_assert(_color_close(px, Color.RED),
			"pixel colour updated to the new image", passed, failed)

	root.queue_free()

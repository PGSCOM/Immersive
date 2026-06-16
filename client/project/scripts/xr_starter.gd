extends Node

## XR Starter — simplified version of godot-xr-tools/start_xr.
## Handles OpenXR initialization without any addon dependencies.

signal xr_started
signal xr_ended
signal xr_failed_to_initialize

var xr_interface: XRInterface

func _ready() -> void:
	_initialize()

func _initialize() -> bool:
	xr_interface = XRServer.find_interface("OpenXR")
	if not xr_interface:
		print("No XR interface detected")
		xr_failed_to_initialize.emit()
		return false
	return _setup_for_openxr()

func _setup_for_openxr() -> bool:
	print("OpenXR: Configuring interface")
	if not xr_interface.is_initialized():
		print("OpenXR: Initializing interface")
		if not xr_interface.initialize():
			push_error("OpenXR: Failed to initialize")
			xr_failed_to_initialize.emit()
			return false

	# Supersample slightly to fight aliasing ("dientes de sierra"). MSAA can't be
	# used here: it breaks stereo (gray right eye) in the gl_compatibility
	# renderer. Instead OpenXR renders at a higher resolution and downsamples to
	# the headset swapchain, which also sharpens the streamed desktop texture.
	if "render_target_size_multiplier" in xr_interface:
		xr_interface.render_target_size_multiplier = 1.3

	# Connect the OpenXR events
	xr_interface.connect("session_begun", _on_openxr_session_begun)
	xr_interface.connect("session_visible", _on_openxr_visible_state)
	xr_interface.connect("session_focussed", _on_openxr_focused_state)

	# Check for passthrough
	var enable_passthrough: bool = false
	if enable_passthrough and xr_interface.is_passthrough_supported():
		xr_interface.start_passthrough()

	# Disable vsync
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	# Switch the viewport to XR
	get_viewport().transparent_bg = enable_passthrough
	get_viewport().use_xr = true

	print("OpenXR: Initialized successfully")
	return true

func _on_openxr_session_begun() -> void:
	print("OpenXR: Session begun")

func _on_openxr_visible_state() -> void:
	print("OpenXR: Session visible (unfocused — menu open)")
	# No emitir xr_ended: la sesión sigue activa, solo perdió el foco

func _on_openxr_focused_state() -> void:
	print("OpenXR: XR started (focused_state)")
	xr_started.emit()

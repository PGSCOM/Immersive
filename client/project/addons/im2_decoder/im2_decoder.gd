@tool
## Registers the Im2VideoDecoder Android plugin (MediaCodec hardware decode)
## at export time. The AAR must be built from client/android-plugin and
## placed in res://addons/im2_decoder/bin/ — see that folder's README.
extends EditorPlugin

var _export_plugin: AndroidExportPlugin = null

func _enter_tree() -> void:
	_export_plugin = AndroidExportPlugin.new()
	add_export_plugin(_export_plugin)

func _exit_tree() -> void:
	if _export_plugin:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	const PLUGIN_NAME := "Im2VideoDecoder"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_name() -> String:
		return PLUGIN_NAME

	func _get_android_libraries(_platform: EditorExportPlatform,
			debug: bool) -> PackedStringArray:
		# Paths are relative to res://addons/
		var release := "im2_decoder/bin/im2decoder-release.aar"
		var debug_aar := "im2_decoder/bin/im2decoder-debug.aar"

		var preferred := debug_aar if debug else release
		var fallback := release if debug else debug_aar

		if FileAccess.file_exists("res://addons/" + preferred):
			return PackedStringArray([preferred])
		if FileAccess.file_exists("res://addons/" + fallback):
			return PackedStringArray([fallback])

		push_warning("[Im2VideoDecoder] AAR not found in addons/im2_decoder/bin — " +
			"the client will fall back to MJPEG. Build it from client/android-plugin.")
		return PackedStringArray()

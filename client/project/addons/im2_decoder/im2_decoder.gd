@tool
## Registers the Im2VideoDecoder Android plugin (MediaCodec hardware decode)
## and the PICO hand-tracking manifest entries
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

	# Hand tracking. The runtime gates it on what the app declares, and
	# without the full set it reports supportsHandTracking = false, so Godot
	# never even registers /user/hand_tracker/* (openxr_hand_tracking_extension.cpp
	# bails out silently on that flag). Only handtracking=1 was declared and
	# the runtime said no; these are the entries PICO's own SDKs write:
	#   https://sdk.picovr.com/docs/OpenXRMobileSDKv2/en/chapter_four.html
	# They used to sit in export_presets.cfg under "gradle_build/
	# manifest_additions", which is not a Godot option, so they never reached
	# the APK. These are the supported hooks to add manifest entries.
	func _get_android_manifest_element_contents(
			_platform: EditorExportPlatform, _debug: bool) -> String:
		# com.picovr.permission.HAND_TRACKING (PICO's own SDKs) and the Android XR
		# XR_INPUT hand-tracking feature: a runtime permission the app must hold,
		# and the flag Android XR looks at to advertise the capability.
		return "<uses-permission android:name=\"com.picovr.permission.HAND_TRACKING\" />\n" + \
			"<uses-feature android:name=\"android.hardware.xr.input.hand_tracking\" android:required=\"false\" />\n"

	func _get_android_manifest_application_element_contents(
			_platform: EditorExportPlatform, _debug: bool) -> String:
		# handtracking=1 is what tells PICO the app runs without controllers, so
		# it stops demanding them (godot_openxr_vendors#162: "the Pico 4 insists
		# that the program doesn't support running with hand tracking" without it).
		# Alone it is PICO's "hands only" mode; with controller=1 it is
		# "controllers and hands", the one where the system hands over to the
		# hands when the controllers are put down and back when one is picked
		# up (PICO-Unity-OpenXR-SDK, Editor/PICOModifyAndroidManifest.cs).
		# pvr.app.type=vr keeps PICO from treating the APK as a flat 2D app; the
		# rest are what its store submission expects (ALVR ships the same set).
		return "<meta-data android:name=\"handtracking\" android:value=\"1\" />\n" + \
			"<meta-data android:name=\"controller\" android:value=\"1\" />\n" + \
			"<meta-data android:name=\"pvr.app.type\" android:value=\"vr\" />\n" + \
			"<meta-data android:name=\"pvr.sdk.version\" android:value=\"OpenXR\" />\n" + \
			"<meta-data android:name=\"pvr.display.orientation\" android:value=\"180\" />\n" + \
			"<meta-data android:name=\"pxr.sdk.version_code\" android:value=\"5900\" />\n" + \
			"<meta-data android:name=\"enable_vst\" android:value=\"1\" />\n"

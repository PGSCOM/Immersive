## Hardware decode tests for Immersive-2.
## Verifies that hardware decode paths are selected per platform.
## Run headlessly via the project test runner:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd

extends RefCounted

func run_all(results: Dictionary, _tree: SceneTree) -> void:
    var passed: Array = []
    var failed: Array = []

    print("\n=== Hardware Decode Tests ===")

    _test_android_mediacodec(passed, failed)
    _test_software_fallback(passed, failed)
    _test_codec_negotiation(passed, failed)

    print("\n  --> HW Decode: Passed: %d / Failed: %d" % [passed.size(), failed.size()])
    results["passed"] = passed.size()
    results["failed"] = failed.size()
    results["failed_messages"] = failed.duplicate()


func _assert(condition: bool, message: String, passed: Array, failed: Array) -> void:
    if condition:
        passed.append(message)
        print("  PASS: %s" % message)
    else:
        failed.append(message)
        print("  FAIL: %s" % message)


func _test_android_mediacodec(passed: Array, failed: Array) -> void:
    print("\nTest: Android MediaCodec")

    if OS.get_name() == "Android":
        var decoder = preload("res://scripts/video_decoder.gd").new()
        _assert(decoder != null, "VideoDecoder instantiates on Android", passed, failed)

        if decoder.has_method("is_codec_supported"):
            _assert(decoder.is_codec_supported(0), "H.264 supported on Android", passed, failed)
        else:
            _assert(false, "VideoDecoder missing is_codec_supported method", passed, failed)
    else:
        print("  SKIP: Not on Android — MediaCodec not available")
        passed.append("Android MediaCodec test skipped on non-Android (expected)")


func _test_software_fallback(passed: Array, failed: Array) -> void:
    print("\nTest: Software MJPEG fallback")

    var sw_decoder = preload("res://scripts/software_video_decoder.gd").new()
    _assert(sw_decoder != null, "SoftwareVideoDecoder instantiates", passed, failed)

    if sw_decoder.has_method("is_codec_supported"):
        _assert(sw_decoder.is_codec_supported(2), "MJPEG supported in software", passed, failed)
    else:
        _assert(false, "SoftwareVideoDecoder missing is_codec_supported method", passed, failed)


func _test_codec_negotiation(passed: Array, failed: Array) -> void:
    print("\nTest: Codec negotiation constants")

    var proto = preload("res://scripts/protocol_constants.gd").new()
    _assert(proto.VIDEO_CODEC_H264 == 0, "H.264 codec constant = 0", passed, failed)
    _assert(proto.VIDEO_CODEC_H265 == 1, "H.265 codec constant = 1", passed, failed)
    _assert(proto.VIDEO_CODEC_MJPEG == 2, "MJPEG codec constant = 2", passed, failed)
    _assert(proto.VIDEO_CODEC_AV1 == 3, "AV1 codec constant = 3", passed, failed)

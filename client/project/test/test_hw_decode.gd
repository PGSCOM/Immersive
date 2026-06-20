## Hardware decode tests for Immersive-2.
## Verifies that hardware decode paths are selected per platform.

extends SceneTree

var _passed: int = 0
var _failed: int = 0

func _init() -> void:
    print("=== Hardware Decode Tests ===\n")

    test_android_mediacodec()
    test_software_fallback()
    test_codec_negotiation()

    print("\n=== Results ===")
    print("Passed: %d" % _passed)
    print("Failed: %d" % _failed)
    print("Total:  %d" % (_passed + _failed))

    quit(1 if _failed > 0 else 0)

func _assert(condition: bool, message: String) -> void:
    if condition:
        _passed += 1
        print("  PASS: %s" % message)
    else:
        _failed += 1
        print("  FAIL: %s" % message)

func test_android_mediacodec() -> void:
    print("Test: Android MediaCodec")
    
    # Check if we're on Android
    if OS.get_name() == "Android":
        # MediaCodec should be available on Android
        var decoder = preload("res://scripts/video_decoder.gd").new()
        _assert(decoder != null, "VideoDecoder instantiates on Android")
        
        # H.264 should be supported
        if decoder.has_method("is_codec_supported"):
            _assert(decoder.is_codec_supported(0), "H.264 supported on Android")
        else:
            _assert(false, "VideoDecoder missing is_codec_supported method")
    else:
        print("  SKIP: Not on Android")

func test_software_fallback() -> void:
    print("\nTest: Software MJPEG fallback")
    
    # Software decoder should always work
    var sw_decoder = preload("res://scripts/software_video_decoder.gd").new()
    _assert(sw_decoder != null, "SoftwareVideoDecoder instantiates")
    
    if sw_decoder.has_method("is_codec_supported"):
        _assert(sw_decoder.is_codec_supported(2), "MJPEG supported in software")
    else:
        _assert(false, "SoftwareVideoDecoder missing is_codec_supported method")

func test_codec_negotiation() -> void:
    print("\nTest: Codec negotiation")
    
    # Verify codec constants match protocol
    var proto = preload("res://scripts/protocol_constants.gd").new()
    _assert(proto.VIDEO_CODEC_H264 == 0, "H.264 codec constant = 0")
    _assert(proto.VIDEO_CODEC_H265 == 1, "H.265 codec constant = 1")
    _assert(proto.VIDEO_CODEC_MJPEG == 2, "MJPEG codec constant = 2")
    _assert(proto.VIDEO_CODEC_AV1 == 3, "AV1 codec constant = 3")

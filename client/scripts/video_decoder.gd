## Video decoder for Immersive-2 VR Client.
## Handles decoding of H.264/H.265 video frames received from the host.
##
## Note: In the MVP, the host sends stub data. When real GPU encoding
## is implemented, this will use platform-specific video decoders
## (MediaCodec on Android/Quest).

extends RefCounted
class_name VideoDecoder

## Decode state
var _initialized: bool = false
var _width: int = 0
var _height: int = 0
var _codec: int = 0  # 0 = H.264, 1 = H.265

## Initialize the decoder with stream parameters.
func initialize(width: int, height: int, codec: int = 0) -> bool:
	_width = width
	_height = height
	_codec = codec
	_initialized = true
	print("[VideoDecoder] Initialized: %dx%d codec=%d" % [width, height, codec])
	return true

## Decode an encoded frame.
## Returns raw RGBA pixel data, or empty array on failure.
func decode_frame(encoded_data: PackedByteArray) -> PackedByteArray:
	if not _initialized:
		return PackedByteArray()

	# Check for stub encoder magic "IM2E"
	if encoded_data.size() >= 4:
		if (encoded_data[0] == 0x49 and  # 'I'
			encoded_data[1] == 0x4D and  # 'M'
			encoded_data[2] == 0x32 and  # '2'
			encoded_data[3] == 0x45):    # 'E'
			# Stub frame - generate a test pattern
			return _generate_test_pattern()

	# TODO: Use MediaCodec for real H.264/H.265 decoding
	# On Quest/Android, this will use the hardware decoder via
	# the Android MediaCodec API through a GDExtension.
	return PackedByteArray()

## Generate a test pattern for stub decoder.
func _generate_test_pattern() -> PackedByteArray:
	var pixels := PackedByteArray()
	pixels.resize(_width * _height * 4)

	# Simple gradient pattern
	for y in range(_height):
		for x in range(_width):
			var idx: int = (y * _width + x) * 4
			pixels[idx] = x % 256        # R
			pixels[idx + 1] = y % 256    # G
			pixels[idx + 2] = 128        # B
			pixels[idx + 3] = 255        # A

	return pixels

## Check if the decoder is initialized.
func is_initialized() -> bool:
	return _initialized

## Get the stream dimensions.
func get_width() -> int:
	return _width

func get_height() -> int:
	return _height

## Shut down the decoder.
func shutdown() -> void:
	_initialized = false

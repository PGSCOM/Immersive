## Video decoder for Immersive-2 VR Client.
## Handles decoding of MJPEG, H.264, and H.265 frames from the host.
##
## Codec 0 = H.264 (future: MediaCodec on Android/Quest)
## Codec 1 = H.265 (future)
## Codec 2 = MJPEG  — decoded via Godot's built-in Image.load_jpg_from_buffer

extends RefCounted
class_name VideoDecoder

## Decode state
var _initialized: bool = false
var _width: int = 0
var _height: int = 0
var _codec: int = 0  # 0 = H.264, 1 = H.265, 2 = MJPEG

## Initialize the decoder with stream parameters.
func initialize(width: int, height: int, codec: int = 2) -> bool:
	_width = width
	_height = height
	_codec = codec
	_initialized = true
	var codec_name := ["H.264", "H.265", "MJPEG"].get(_codec) if _codec < 3 else "Unknown"
	print("[VideoDecoder] Initialized: %dx%d codec=%d (%s)" % [width, height, codec, codec_name])
	return true

## Decode an encoded frame.
## Returns raw RGBA pixel data, or empty array on failure.
func decode_frame(encoded_data: PackedByteArray) -> PackedByteArray:
	if not _initialized:
		return PackedByteArray()

	# --- MJPEG path (codec=2) ---
	# Also auto-detect JPEG by magic bytes FF D8 FF
	var is_jpeg := (_codec == 2) or \
		(encoded_data.size() >= 3 and
		 encoded_data[0] == 0xFF and
		 encoded_data[1] == 0xD8 and
		 encoded_data[2] == 0xFF)

	if is_jpeg:
		var img := Image.new()
		var err := img.load_jpg_from_buffer(encoded_data)
		if err == OK:
			img.convert(Image.FORMAT_RGBA8)
			return img.get_data()
		else:
			push_warning("[VideoDecoder] JPEG decode failed: %d" % err)
			return PackedByteArray()

	# --- Stub encoder magic "IM2E" (development only) ---
	if encoded_data.size() >= 4:
		if (encoded_data[0] == 0x49 and  # 'I'
			encoded_data[1] == 0x4D and  # 'M'
			encoded_data[2] == 0x32 and  # '2'
			encoded_data[3] == 0x45):    # 'E'
			return _generate_test_pattern()

	# --- H.264/H.265 path (future: GDExtension + MediaCodec) ---
	# TODO: implement hardware decode on Android/Quest via a GDExtension
	push_warning("[VideoDecoder] No decoder for codec=%d, dropping frame" % _codec)
	return PackedByteArray()

## Generate a test pattern for the stub encoder path.
func _generate_test_pattern() -> PackedByteArray:
	var pixels := PackedByteArray()
	pixels.resize(_width * _height * 4)

	for y in range(_height):
		for x in range(_width):
			var idx: int = (y * _width + x) * 4
			pixels[idx]     = x % 256   # R
			pixels[idx + 1] = y % 256   # G
			pixels[idx + 2] = 128       # B
			pixels[idx + 3] = 255       # A

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
	print("[VideoDecoder] Shutdown")

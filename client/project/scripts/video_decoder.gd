## Video decoder for Immersive-2 VR Client.
## Handles decoding of MJPEG, H.264, and H.265 frames from the host.
##
## Codec 0 = H.264  — hardware decode via Android MediaCodec on Quest/Pico,
##                     falls back to MJPEG software path on non-Android.
## Codec 1 = H.265  — future
## Codec 2 = MJPEG  — decoded via Godot's built-in Image.load_jpg_from_buffer

extends RefCounted
class_name VideoDecoder

## Decode state
var _initialized: bool = false
var _width: int = 0
var _height: int = 0
var _codec: int = 0  # 0 = H.264, 1 = H.265, 2 = MJPEG

## MediaCodec decoder (Android only)
var _mediacodec_available: bool = false
var _MediaCodec        = null   # JavaClassWrapper reference
var _codec_instance    = null   # android.media.MediaCodec object
var _codec_mime: String = ""

## -----------------------------------------------------------------
## Inner class: Android MediaCodec H.264 decoder
## -----------------------------------------------------------------

## Tries to initialize Android MediaCodec for H.264/H.265 hardware decode.
## Falls back to the MJPEG software path if unavailable.
func _try_init_mediacodec(width: int, height: int, codec_mime: String) -> bool:
	if not OS.has_feature("android"):
		return false

	# Access android.media.MediaCodec via JavaClassWrapper
	var MediaCodec = JavaClassWrapper.wrap("android.media.MediaCodec")
	if MediaCodec == null:
		push_warning("[VideoDecoder] JavaClassWrapper: android.media.MediaCodec unavailable")
		return false

	var MediaFormat = JavaClassWrapper.wrap("android.media.MediaFormat")
	if MediaFormat == null:
		push_warning("[VideoDecoder] JavaClassWrapper: android.media.MediaFormat unavailable")
		return false

	# Create decoder by codec MIME type
	var codec_instance = MediaCodec.createDecoderByType(codec_mime)
	if codec_instance == null:
		push_warning("[VideoDecoder] MediaCodec.createDecoderByType(%s) returned null" % codec_mime)
		return false

	# Build MediaFormat
	var fmt = MediaFormat.createVideoFormat(codec_mime, width, height)
	if fmt == null:
		push_warning("[VideoDecoder] MediaFormat.createVideoFormat returned null")
		return false

	# Configure and start the codec (surface=null → byte-buffer output mode)
	# configure(format, surface, crypto, flags) — flags=0 means decode
	codec_instance.configure(fmt, null, null, 0)
	codec_instance.start()

	_MediaCodec      = MediaCodec
	_codec_instance  = codec_instance
	_codec_mime      = codec_mime

	print("[VideoDecoder] Android MediaCodec initialized for %s (%dx%d)" % [codec_mime, width, height])
	return true

## Feed one encoded access unit to MediaCodec and collect decoded frames.
## Returns raw RGBA pixel data, or empty array if no frame is ready yet.
func _mediacodec_decode(encoded_data: PackedByteArray) -> PackedByteArray:
	if _codec_instance == null:
		return PackedByteArray()

	# --- Submit input buffer ---
	# dequeueInputBuffer(timeoutUs) — wait up to 5 ms
	var in_idx = _codec_instance.dequeueInputBuffer(5000)
	if in_idx >= 0:
		var input_buf = _codec_instance.getInputBuffer(in_idx)
		# Write bytes into the Java ByteBuffer
		# JavaClassWrapper exposes put(byte[]) on ByteBuffer
		input_buf.put(encoded_data)
		var data_size: int = encoded_data.size()
		# queueInputBuffer(index, offset, size, presentationTimeUs, flags)
		_codec_instance.queueInputBuffer(in_idx, 0, data_size, 0, 0)

	# --- Retrieve output buffer ---
	var BufferInfo = JavaClassWrapper.wrap("android.media.MediaCodec$BufferInfo")
	if BufferInfo == null:
		return PackedByteArray()

	var buf_info = BufferInfo.new()
	# dequeueOutputBuffer(info, timeoutUs)
	var out_idx = _codec_instance.dequeueOutputBuffer(buf_info, 0)
	if out_idx < 0:
		# No frame ready yet (INFO_OUTPUT_FORMAT_CHANGED = -2, etc.)
		return PackedByteArray()

	# Get the output buffer bytes
	var output_buf = _codec_instance.getOutputBuffer(out_idx)
	var out_size: int = buf_info.size  # number of valid bytes

	# Read bytes from Java ByteBuffer into GDScript PackedByteArray
	# The output is typically YUV (COLOR_FormatYUV420Flexible).
	# For simplicity we return the raw bytes; upper layers handle conversion.
	var result := PackedByteArray()
	result.resize(out_size)
	for i in range(out_size):
		result[i] = output_buf.get(i) & 0xFF

	# Release the buffer back to the codec
	_codec_instance.releaseOutputBuffer(out_idx, false)
	return result

## -----------------------------------------------------------------
## Public API
## -----------------------------------------------------------------

## Initialize the decoder with stream parameters.
func initialize(width: int, height: int, codec: int = 2) -> bool:
	_width  = width
	_height = height
	_codec  = codec

	_mediacodec_available = false
	_codec_instance = null

	# Attempt MediaCodec init for H.264 / H.265 on Android
	if codec == 0:
		_mediacodec_available = _try_init_mediacodec(width, height, "video/avc")
	elif codec == 1:
		_mediacodec_available = _try_init_mediacodec(width, height, "video/hevc")

	_initialized = true
	var codec_names: Array[String] = ["H.264", "H.265", "MJPEG"]
	var codec_name: String = codec_names[_codec] if _codec >= 0 and _codec < codec_names.size() else "Unknown"
	var hw_tag: String = " [MediaCodec]" if _mediacodec_available else ""
	print("[VideoDecoder] Initialized: %dx%d codec=%d (%s)%s" % [width, height, codec, codec_name, hw_tag])
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

	# --- H.264 / H.265 via Android MediaCodec ---
	if (_codec == 0 or _codec == 1) and _mediacodec_available:
		return _mediacodec_decode(encoded_data)

	# --- Stub encoder magic "IM2E" (development only) ---
	if encoded_data.size() >= 4:
		if (encoded_data[0] == 0x49 and  # 'I'
			encoded_data[1] == 0x4D and  # 'M'
			encoded_data[2] == 0x32 and  # '2'
			encoded_data[3] == 0x45):    # 'E'
			return _generate_test_pattern()

	# --- H.264/H.265 path — not on Android, no GDExtension decoder available ---
	push_warning("[VideoDecoder] No decoder for codec=%d on this platform, dropping frame" % _codec)
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
	if _codec_instance != null:
		_codec_instance.stop()
		_codec_instance.release()
		_codec_instance = null
	_mediacodec_available = false
	_initialized = false
	print("[VideoDecoder] Shutdown")

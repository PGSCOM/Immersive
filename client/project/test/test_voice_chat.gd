## Tests for multi-user voice chat: the PCM frame codec (voice_chat.gd), the mute
## gate, per-user spatial playback buffering (voice_playback.gd), and the
## topology-aware routing through multiuser_manager.gd. Run headlessly via:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## No microphone or audio device is exercised — the codec/routing/buffer logic is
## pure, and playback is only checked at the queue level (play() is never called).

extends RefCounted

const VoiceChatScript := preload("res://scripts/voice_chat.gd")
const VoicePlaybackScript := preload("res://scripts/voice_playback.gd")
const MgrScript := preload("res://scripts/multiuser_manager.gd")

# ---------------------------------------------------------------------------
# Mocks for the routing tests
# ---------------------------------------------------------------------------

class MockSig extends Node:
	signal voice_frame_received(from_user_id: int, frame: PackedByteArray)
	var sent_voice: Array = []
	func send_voice_frame(frame: PackedByteArray) -> void:
		sent_voice.append(frame)

class MockRtc extends Node:
	signal voice_received(user_id: int, frame: PackedByteArray)
	var voice_broadcasts: Array = []
	var voice_return: int = 0
	func initialize(_signaling: Node, _local_id: int) -> void:
		pass
	func broadcast_voice(frame: PackedByteArray) -> int:
		voice_broadcasts.append(frame)
		return voice_return

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _assert(condition: bool, message: String, passed: Array, failed: Array) -> void:
	if condition:
		passed.append(message)
		print("  PASS: %s" % message)
	else:
		failed.append(message)
		print("  FAIL: %s" % message)

func _ramp(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	for i in range(n):
		a[i] = clampf(-1.0 + 2.0 * float(i) / float(maxi(1, n - 1)), -1.0, 1.0)
	return a

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

func run_all(results: Dictionary, tree: SceneTree) -> void:
	print("\n=== Voice Chat Tests ===")
	var passed: Array = []
	var failed: Array = []

	test_codec_roundtrip(passed, failed)
	test_codec_rejects_malformed(passed, failed)
	test_downmix(passed, failed)
	test_mute_gate(passed, failed, tree)
	test_playback_buffer(passed, failed)
	test_on_remote_voice_routes_to_playback(passed, failed, tree)
	test_broadcast_voice_routing(passed, failed, tree)
	test_inbound_voice_emits_remote(passed, failed, tree)

	print("\n=== Voice Chat Results: Passed %d / Failed %d ===" % [passed.size(), failed.size()])
	results["passed"] = passed.size()
	results["failed"] = failed.size()
	results["failed_messages"] = failed.duplicate()

func test_codec_roundtrip(passed: Array, failed: Array) -> void:
	print("\nTest: PCM frame encode/decode round-trip")
	var mono := _ramp(160)
	var bytes := VoiceChatScript.encode_frame(42, mono)
	_assert(bytes.size() == VoiceChatScript.HEADER_SIZE + 160 * 2,
		"encoded size = header + 2*samples", passed, failed)
	var decoded := VoiceChatScript.decode_frame(bytes)
	_assert(decoded.get("valid", false), "decode reports valid", passed, failed)
	_assert(int(decoded["seq"]) == 42, "seq survives the round-trip", passed, failed)
	var out: PackedFloat32Array = decoded["samples"]
	_assert(out.size() == 160, "sample count survives", passed, failed)
	var max_err := 0.0
	for i in range(out.size()):
		max_err = maxf(max_err, absf(out[i] - mono[i]))
	# PCM-16 quantisation error is ~1/32768.
	_assert(max_err < 0.0001, "samples within PCM-16 quantisation error", passed, failed)

func test_codec_rejects_malformed(passed: Array, failed: Array) -> void:
	print("\nTest: decode rejects malformed frames")
	_assert(not VoiceChatScript.decode_frame(PackedByteArray()).get("valid", false),
		"empty buffer is invalid", passed, failed)
	_assert(not VoiceChatScript.decode_frame(PackedByteArray([1, 2, 3])).get("valid", false),
		"short header is invalid", passed, failed)
	# Header claims 100 samples but no payload follows.
	var truncated := VoiceChatScript.encode_frame(1, _ramp(100))
	truncated.resize(VoiceChatScript.HEADER_SIZE + 10)  # chop the payload
	_assert(not VoiceChatScript.decode_frame(truncated).get("valid", false),
		"truncated payload is invalid", passed, failed)

func test_downmix(passed: Array, failed: Array) -> void:
	print("\nTest: stereo → mono downmix")
	var stereo := PackedVector2Array([Vector2(1.0, -1.0), Vector2(0.5, 0.5), Vector2(0.2, 0.8)])
	var mono := VoiceChatScript.downmix_to_mono(stereo)
	_assert(mono.size() == 3, "mono length matches", passed, failed)
	_assert(absf(mono[0] - 0.0) < 0.0001, "L=1,R=-1 averages to 0", passed, failed)
	_assert(absf(mono[1] - 0.5) < 0.0001, "equal channels preserved", passed, failed)
	_assert(absf(mono[2] - 0.5) < 0.0001, "0.2/0.8 averages to 0.5", passed, failed)

func test_mute_gate(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: mute toggle + signal")
	var vc = VoiceChatScript.new()
	tree.root.add_child(vc)
	var events: Array = []
	vc.mute_changed.connect(func(m): events.append(m))
	_assert(not vc.is_muted(), "starts unmuted", passed, failed)
	vc.toggle_mute()
	_assert(vc.is_muted(), "toggle mutes", passed, failed)
	vc.toggle_mute()
	_assert(not vc.is_muted(), "toggle unmutes", passed, failed)
	vc.set_muted(false)  # no-op (already false) must not emit
	_assert(events.size() == 2, "mute_changed emitted only on real changes", passed, failed)
	vc.queue_free()

func test_playback_buffer(passed: Array, failed: Array) -> void:
	print("\nTest: per-user playback jitter buffer (queue only)")
	var pb = VoicePlaybackScript.new()  # not added to tree → no audio device touched
	pb.push_frame(5, _ramp(80))
	pb.push_frame(3, _ramp(80))
	_assert(pb.buffered_frame_count() == 2, "two frames buffered", passed, failed)
	pb.push_frame(0, PackedFloat32Array())  # empty frame ignored
	_assert(pb.buffered_frame_count() == 2, "empty frame ignored", passed, failed)
	pb.reset()
	_assert(pb.buffered_frame_count() == 0, "reset clears the buffer", passed, failed)
	pb.free()

func test_on_remote_voice_routes_to_playback(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: on_remote_voice decodes + buffers per user")
	var vc = VoiceChatScript.new()
	tree.root.add_child(vc)
	vc.attach_playback(7)
	_assert(vc.playback_count() == 1, "attach_playback registers a playback", passed, failed)
	vc.on_remote_voice(7, VoiceChatScript.encode_frame(1, _ramp(120)))
	var pb = vc.get_playback(7)
	_assert(pb != null and pb.buffered_frame_count() == 1,
		"remote frame buffered on the user's playback", passed, failed)
	vc.on_remote_voice(7, PackedByteArray([0, 1]))  # malformed → dropped
	_assert(pb.buffered_frame_count() == 1, "malformed remote frame dropped", passed, failed)
	vc.remove_playback(7)
	_assert(vc.playback_count() == 0, "remove_playback drops the playback", passed, failed)
	vc.queue_free()

func test_broadcast_voice_routing(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: broadcast_voice picks P2P vs SFU")
	var sig := MockSig.new()
	var rtc := MockRtc.new()
	var mgr = MgrScript.new()
	tree.root.add_child(sig)
	tree.root.add_child(rtc)
	tree.root.add_child(mgr)
	mgr.setup(sig, rtc)

	var frame := VoiceChatScript.encode_frame(1, _ramp(64))

	# Empty frame is a no-op.
	_assert(mgr.broadcast_voice(PackedByteArray()) == "none", "empty frame → none", passed, failed)

	# P2P link open (webrtc returns >0) → goes over the voice channel.
	rtc.voice_return = 1
	_assert(mgr.broadcast_voice(frame) == "p2p", "open P2P link → p2p", passed, failed)
	_assert(rtc.voice_broadcasts.size() == 1 and sig.sent_voice.is_empty(),
		"p2p path does not hit the relay", passed, failed)

	# No open P2P link → falls back to the SFU relay.
	rtc.voice_return = 0
	_assert(mgr.broadcast_voice(frame) == "sfu", "no P2P link → sfu relay", passed, failed)
	_assert(sig.sent_voice.size() == 1, "sfu path sends through signaling", passed, failed)

	mgr.queue_free()
	sig.queue_free()
	rtc.queue_free()

func test_inbound_voice_emits_remote(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: inbound voice (relay + p2p) surfaces as remote_voice")
	var sig := MockSig.new()
	var rtc := MockRtc.new()
	var mgr = MgrScript.new()
	tree.root.add_child(sig)
	tree.root.add_child(rtc)
	tree.root.add_child(mgr)
	mgr.setup(sig, rtc)

	var got: Array = []
	mgr.remote_voice.connect(func(uid, frame): got.append({"uid": uid, "n": frame.size()}))

	sig.voice_frame_received.emit(3, VoiceChatScript.encode_frame(1, _ramp(32)))
	rtc.voice_received.emit(4, VoiceChatScript.encode_frame(2, _ramp(48)))

	_assert(got.size() == 2, "both transports surface remote_voice", passed, failed)
	_assert(got[0]["uid"] == 3, "relay voice carries the sender id", passed, failed)
	_assert(got[1]["uid"] == 4, "p2p voice carries the sender id", passed, failed)

	mgr.queue_free()
	sig.queue_free()
	rtc.queue_free()

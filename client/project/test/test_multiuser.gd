## Tests for the multi-user orchestrator (multiuser_manager.gd) and the WebRTC mesh
## glue (webrtc_manager.gd). Run headlessly via the project test runner:
##   godot --headless --xr-mode off --path client/project -s res://test/run_tests.gd
##
## Uses lightweight mock signaling / WebRTC objects so the topology-aware pose
## routing, presence handling, glare-free offer logic, and SDP/ICE forwarding are
## verified without live sockets.

extends RefCounted

const MgrScript := preload("res://scripts/multiuser_manager.gd")
const WebRTCScript := preload("res://scripts/webrtc_manager.gd")

# ---------------------------------------------------------------------------
# Mocks
# ---------------------------------------------------------------------------

class MockSignaling extends Node:
	signal connected_to_signaling
	signal room_joined(room_id: String, user_id: int, participants: Array)
	signal room_left(user_id: int)
	signal user_presence(user_id: int, display_name: String, is_online: bool)
	signal user_pose_received(user_id: int, head: Dictionary, left_hand: Dictionary, right_hand: Dictionary)
	signal topology_changed(mode: String)
	signal webrtc_offer_received(from_user_id: int, sdp: String)
	signal webrtc_answer_received(from_user_id: int, sdp: String)
	signal ice_candidate_received(from_user_id: int, candidate: String)
	signal whiteboard_stroke_received(from_user_id: int, stroke: Dictionary)
	signal whiteboard_clear_received(from_user_id: int)

	var sent_poses: Array = []
	var joined: Array = []
	var wb_strokes: Array = []
	var wb_clears: int = 0

	func connect_to_signaling(_url: String) -> void:
		pass
	func send_room_join(room_id: String, display_name: String) -> void:
		joined.append({"room": room_id, "name": display_name})
	func send_user_pose(head: Dictionary, left_hand: Dictionary, right_hand: Dictionary) -> void:
		sent_poses.append({"head": head, "left": left_hand, "right": right_hand})
	func send_whiteboard_stroke(stroke: Dictionary) -> void:
		wb_strokes.append(stroke)
	func send_whiteboard_clear() -> void:
		wb_clears += 1
	func disconnect_from_signaling() -> void:
		pass

class MockWebRTC extends Node:
	signal pose_received(user_id: int, payload: String)

	var offers: Array = []
	var closed: Array = []
	var remote_descs: Array = []
	var ice: Array = []
	var broadcasts: Array = []
	var topology: Array = []
	var broadcast_return: int = 0

	func initialize(_signaling: Node, _local_id: int) -> void:
		pass
	func create_offer(user_id: int) -> void:
		offers.append(user_id)
	func close_peer(user_id: int) -> void:
		closed.append(user_id)
	func close_all() -> void:
		pass
	func on_topology_changed(mode: String) -> void:
		topology.append(mode)
	func set_remote_description(user_id: int, type: String, sdp: String) -> void:
		remote_descs.append({"user": user_id, "type": type, "sdp": sdp})
	func handle_ice_candidate(user_id: int, candidate: String) -> void:
		ice.append({"user": user_id, "cand": candidate})
	func broadcast_pose(payload: String) -> int:
		broadcasts.append(payload)
		return broadcast_return

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

func _make(tree: SceneTree) -> Array:
	var sig := MockSignaling.new()
	var rtc := MockWebRTC.new()
	var mgr = MgrScript.new()
	tree.root.add_child(sig)
	tree.root.add_child(rtc)
	tree.root.add_child(mgr)
	mgr.setup(sig, rtc)
	return [mgr, sig, rtc]

func _pose() -> Dictionary:
	return {"pos_x": 0.0, "pos_y": 1.6, "pos_z": -1.0, "rot_w": 1.0, "rot_x": 0.0, "rot_y": 0.0, "rot_z": 0.0}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

func run_all(results: Dictionary, tree: SceneTree) -> void:
	print("\n=== Multi-user / WebRTC Tests ===")
	var passed: Array = []
	var failed: Array = []

	test_room_join_p2p(passed, failed, tree)
	test_room_join_sfu(passed, failed, tree)
	test_offer_glare_avoidance(passed, failed, tree)
	test_pose_routing(passed, failed, tree)
	test_presence_and_leave(passed, failed, tree)
	test_pose_forwarding(passed, failed, tree)
	test_topology_and_signaling_forward(passed, failed, tree)
	test_setup_wires_signals(passed, failed, tree)
	test_whiteboard_sync(passed, failed, tree)
	test_webrtc_helpers(passed, failed, tree)

	print("\n=== Multi-user Results: Passed %d / Failed %d ===" % [passed.size(), failed.size()])
	results["passed"] = passed.size()
	results["failed"] = failed.size()
	results["failed_messages"] = failed.duplicate()

func test_room_join_p2p(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: room join (2 users → P2P)")
	var parts := _make(tree)
	var mgr = parts[0]

	var captured := {"room": "", "id": -1, "mode": ""}
	mgr.room_state.connect(func(r, i, m): captured["room"] = r; captured["id"] = i; captured["mode"] = m)
	var presence: Array = []
	mgr.remote_presence.connect(func(uid, _n, online): presence.append([uid, online]))

	# We are the newcomer (id 2); user 1 already present.
	mgr._on_room_joined("lobby", 2, [
		{"user_id": 1, "display_name": "Alice"},
		{"user_id": 2, "display_name": "Me"},
	])
	_assert(mgr.get_local_user_id() == 2, "local user id set", passed, failed)
	_assert(mgr.get_mode() == "p2p", "2 users → P2P mode", passed, failed)
	_assert(mgr.get_participant_count() == 1, "one remote participant tracked", passed, failed)
	_assert(String(captured["mode"]) == "p2p", "room_state emitted with mode p2p", passed, failed)
	_assert(presence.size() == 1 and int(presence[0][0]) == 1,
		"existing participant surfaced as remote_presence", passed, failed)

	for n in parts:
		n.queue_free()

func test_room_join_sfu(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: room join (3 users → SFU)")
	var parts := _make(tree)
	var mgr = parts[0]
	mgr._on_room_joined("lobby", 3, [
		{"user_id": 1, "display_name": "A"},
		{"user_id": 2, "display_name": "B"},
		{"user_id": 3, "display_name": "Me"},
	])
	_assert(mgr.get_mode() == "sfu", "3 users → SFU mode", passed, failed)
	_assert(mgr.get_participant_count() == 2, "two remote participants tracked", passed, failed)
	for n in parts:
		n.queue_free()

func test_offer_glare_avoidance(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: glare-free offer (lower id offers)")
	# Newcomer (higher id) does NOT offer to existing lower-id peers.
	var parts := _make(tree)
	var mgr = parts[0]
	var rtc = parts[2]
	mgr._on_room_joined("lobby", 5, [{"user_id": 1, "display_name": "A"}, {"user_id": 5, "display_name": "Me"}])
	_assert(rtc.offers.is_empty(), "newcomer (id 5) does not offer to existing id 1", passed, failed)

	# Existing peer (lower id) DOES offer when a higher-id newcomer appears.
	var parts2 := _make(tree)
	var mgr2 = parts2[0]
	var rtc2 = parts2[2]
	mgr2._on_room_joined("lobby", 1, [{"user_id": 1, "display_name": "Me"}])  # alone first
	mgr2._on_user_presence(7, "Newcomer", true)
	_assert(rtc2.offers.has(7), "existing id 1 offers to newcomer id 7", passed, failed)

	for n in parts + parts2:
		n.queue_free()

func test_pose_routing(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: topology-aware pose routing")
	var parts := _make(tree)
	var mgr = parts[0]
	var sig = parts[1]
	var rtc = parts[2]

	# SFU mode → always relay through signaling.
	mgr._on_room_joined("lobby", 3, [{"user_id": 1}, {"user_id": 2}, {"user_id": 3}])
	var path_sfu: String = mgr.broadcast_pose(_pose(), _pose(), _pose())
	_assert(path_sfu == "sfu", "SFU mode routes pose via relay", passed, failed)
	_assert(sig.sent_poses.size() == 1, "relay received one pose", passed, failed)

	# P2P mode with an open data channel → P2P, no relay.
	var parts2 := _make(tree)
	var mgr2 = parts2[0]
	var sig2 = parts2[1]
	var rtc2 = parts2[2]
	rtc2.broadcast_return = 1
	mgr2._on_room_joined("lobby", 2, [{"user_id": 1}, {"user_id": 2}])
	var path_p2p: String = mgr2.broadcast_pose(_pose(), _pose(), _pose())
	_assert(path_p2p == "p2p", "P2P mode with open channel routes pose P2P", passed, failed)
	_assert(sig2.sent_poses.is_empty(), "relay NOT used when P2P channel is open", passed, failed)
	_assert(rtc2.broadcasts.size() == 1, "WebRTC broadcast_pose called once", passed, failed)

	# P2P mode but no open channel yet → fall back to relay.
	rtc2.broadcast_return = 0
	var path_fallback: String = mgr2.broadcast_pose(_pose(), _pose(), _pose())
	_assert(path_fallback == "sfu", "P2P with no open channel falls back to relay", passed, failed)
	_assert(sig2.sent_poses.size() == 1, "relay used as fallback", passed, failed)

	for n in parts + parts2:
		n.queue_free()

func test_presence_and_leave(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: presence offline + room_left close peers")
	var parts := _make(tree)
	var mgr = parts[0]
	var rtc = parts[2]

	var presence_events: Array = []
	mgr.remote_presence.connect(func(uid, _name, online): presence_events.append([uid, online]))

	mgr._on_room_joined("lobby", 1, [{"user_id": 1, "display_name": "Me"}])
	mgr._on_user_presence(2, "Bob", true)
	_assert(mgr.get_participant_count() == 1, "Bob tracked after presence online", passed, failed)

	mgr._on_user_presence(2, "Bob", false)
	_assert(mgr.get_participant_count() == 0, "Bob removed after presence offline", passed, failed)
	_assert(rtc.closed.has(2), "peer 2 closed on presence offline", passed, failed)
	_assert(presence_events.size() == 2, "remote_presence emitted for online + offline", passed, failed)

	mgr._on_user_presence(3, "Cara", true)
	mgr._on_room_left(3)
	_assert(rtc.closed.has(3), "peer 3 closed on room_left", passed, failed)

	for n in parts:
		n.queue_free()

func test_pose_forwarding(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: relay + P2P pose forwarded as remote_pose")
	var parts := _make(tree)
	var mgr = parts[0]
	var rtc = parts[2]

	var got: Array = []
	mgr.remote_pose.connect(func(uid, h, _l, _r): got.append([uid, h]))

	# Relay (SFU) pose.
	mgr._on_relay_pose(9, _pose(), _pose(), _pose())
	_assert(got.size() == 1 and int(got[0][0]) == 9, "relay pose forwarded as remote_pose", passed, failed)

	# P2P pose arrives as a JSON payload over the data channel.
	var payload := JSON.stringify({"head": _pose(), "left": _pose(), "right": _pose()})
	mgr._on_p2p_pose(11, payload)
	_assert(got.size() == 2 and int(got[1][0]) == 11, "P2P JSON pose parsed + forwarded", passed, failed)
	_assert((got[1][1] as Dictionary).has("pos_y"), "parsed head dict carries pose fields", passed, failed)

	for n in parts:
		n.queue_free()

func test_topology_and_signaling_forward(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: topology migration + SDP/ICE forwarding")
	var parts := _make(tree)
	var mgr = parts[0]
	var rtc = parts[2]

	var modes: Array = []
	mgr.mode_changed.connect(func(m): modes.append(m))

	mgr._on_topology_changed("sfu")
	_assert(mgr.get_mode() == "sfu", "topology_changed updates mode to sfu", passed, failed)
	_assert(rtc.topology.has("sfu"), "WebRTC told about sfu migration", passed, failed)
	_assert(modes.has("sfu"), "mode_changed emitted", passed, failed)

	mgr._on_webrtc_offer(4, "sdp-offer")
	mgr._on_webrtc_answer(4, "sdp-answer")
	mgr._on_ice_candidate(4, "audio|0|candidate:abc")
	_assert(rtc.remote_descs.size() == 2, "offer + answer forwarded to WebRTC", passed, failed)
	_assert(rtc.ice.size() == 1, "ICE candidate forwarded to WebRTC", passed, failed)

	for n in parts:
		n.queue_free()

func test_setup_wires_signals(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: setup() actually connects signaling signals")
	var parts := _make(tree)
	var mgr = parts[0]
	var sig = parts[1]

	# Emitting on the mock should drive the manager (proves the wiring).
	sig.room_joined.emit("room", 2, [{"user_id": 1}, {"user_id": 2}])
	_assert(mgr.get_local_user_id() == 2, "emitting room_joined drives the manager", passed, failed)

	for n in parts:
		n.queue_free()

func test_whiteboard_sync(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: whiteboard stroke/clear relay")
	var parts := _make(tree)
	var mgr = parts[0]
	var sig = parts[1]

	# Local strokes are broadcast through the signaling relay.
	mgr.broadcast_whiteboard_stroke({"user_id": 1, "color": [0.0, 0.0, 0.0], "points": [0.1, 0.2]})
	_assert(sig.wb_strokes.size() == 1, "local stroke broadcast via signaling", passed, failed)
	mgr.broadcast_whiteboard_clear()
	_assert(sig.wb_clears == 1, "local clear broadcast via signaling", passed, failed)

	# Remote strokes/clears are surfaced as signals for the scene to apply.
	var strokes: Array = []
	mgr.remote_whiteboard_stroke.connect(func(uid, s): strokes.append([uid, s]))
	sig.whiteboard_stroke_received.emit(9, {"user_id": 9, "points": [0.3, 0.4]})
	_assert(strokes.size() == 1 and int(strokes[0][0]) == 9, "remote stroke forwarded", passed, failed)

	var clears: Array = []
	mgr.remote_whiteboard_clear.connect(func(uid): clears.append(uid))
	sig.whiteboard_clear_received.emit(9)
	_assert(clears.size() == 1, "remote clear forwarded", passed, failed)

	for n in parts:
		n.queue_free()

func test_webrtc_helpers(passed: Array, failed: Array, tree: SceneTree) -> void:
	print("\nTest: WebRTCManager pure helpers")
	# ICE candidate parsing.
	var ok := WebRTCScript.parse_ice_candidate("0|1|candidate:foo bar")
	_assert(ok.get("valid", false), "valid ICE string parses", passed, failed)
	_assert(String(ok.get("media", "")) == "0" and int(ok.get("index", -1)) == 1,
		"ICE media/index parsed", passed, failed)
	_assert(String(ok.get("name", "")) == "candidate:foo bar", "ICE name keeps trailing pipes/spaces", passed, failed)

	_assert(not WebRTCScript.parse_ice_candidate("garbage").get("valid", false),
		"malformed ICE string rejected", passed, failed)
	_assert(not WebRTCScript.parse_ice_candidate("a|notanint|c").get("valid", false),
		"non-integer ICE index rejected", passed, failed)

	# A fresh manager has no open channels and broadcasts to nobody.
	var rtc = WebRTCScript.new()
	tree.root.add_child(rtc)
	_assert(int(rtc.broadcast_pose("{}")) == 0, "broadcast_pose with no peers returns 0", passed, failed)
	_assert(rtc.open_channel_count() == 0, "no open channels initially", passed, failed)
	_assert(rtc.peer_count() == 0, "no peers initially", passed, failed)
	rtc.queue_free()

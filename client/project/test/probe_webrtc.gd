extends SceneTree

func _init() -> void:
	print("=== WebRTC Capability Probe ===")
	print("ClassFound WebRTCPeerConnection: %s" % str(ClassDB.class_exists("WebRTCPeerConnection")))
	print("ClassFound WebRTCMultiplayerPeer: %s" % str(ClassDB.class_exists("WebRTCMultiplayerPeer")))
	var pc := WebRTCPeerConnection.new() if ClassDB.class_exists("WebRTCPeerConnection") else null
	if pc:
		print("WebRTCPeerConnection.new() ok, connection_state=%d" % WebRTCPeerConnection.STATE_NEW)
		var err := pc.initialize({
			"iceServers": [{"urls": ["stun:stun.l.google.com:19302"]}]
		})
		print("initialize err=%d" % err)
		var offer_err := pc.create_offer()
		print("create_offer err=%d" % offer_err)
		print("get_connection_state=%d" % pc.get_connection_state())
	quit(0)

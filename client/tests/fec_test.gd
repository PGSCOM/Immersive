extends SceneTree
## UDP video FEC (protocol.h VideoParityHeader) in network_client.gd, headless:
##   godot --headless --xr-mode off --path client/project \
##       -s "$PWD/client/tests/fec_test.gd"
## Frames are cut into chunks and parity the way server.cpp does, chunks are
## dropped, and what the client delivers must be the frame, byte for byte.
## (smoke_client.py checks the host's parity against the same rule.)
## Prints "RESULT fails=N".

const MON := 3
var fails := 0
var net: Node
var delivered: Array = []
var next_frame := 1
var feed_ms := 0.0

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	net = load("res://scripts/network_client.gd").new()
	net.video_frame_received.connect(func(_m, data, _w, _h): delivered.append(data))
	net._stream_size[MON] = Vector2i(1920, 1080)
	net._first_frame[MON] = 1
	net._last_completed_frame[MON] = 0

	check(send(frame(300), [0]), "one-chunk frame, its chunk lost: rebuilt from the parity copy")
	check(send(frame(50 * 1400 - 333), [0]), "50 chunks, the first lost")
	check(send(frame(50 * 1400 - 333), [49]), "the short last chunk lost: rebuilt at its own length")
	check(send(frame(50 * 1400 - 333), range(20, 30)), "a burst of 10 (= parity count) lost")
	check(send(frame(50 * 1400 - 333), [0, 11, 22, 33, 44, 5, 16, 27, 38, 49]), "one loss in every group")
	check(send(frame(7 * 1400)), "nothing lost: delivered once")
	check(not send(frame(50 * 1400 - 333), [3, 13]), "two lost in one group: not delivered")
	check(send(frame(4000), [1], true), "parity first, the lost chunk rebuilt as the data arrives")
	# 345 chunks, 69 parity: chunks 0, 5, 10... fall in 69 different groups.
	check(send(frame(344 * 1400 + 17), range(0, 345, 5)), "345-chunk IDR (483 KB) with 69 chunks lost")
	print("     (%.1f ms in the client to reassemble it and rebuild them)" % feed_ms)
	check(net._chunks_rebuilt == 1 + 1 + 1 + 10 + 10 + 1 + 69, "rebuilt count %d" % net._chunks_rebuilt)

	print("RESULT fails=%d" % fails)
	net.free()
	quit(1 if fails else 0)

func frame(size: int) -> PackedByteArray:
	var f := PackedByteArray()
	f.resize(size)
	for i in size:
		f[i] = (i * 7 + size) & 0xFF
	return f

## Packets of the next frame as server.cpp makes them, minus `lost` data
## chunks; parity last (or first). True if the client delivered that frame.
func send(data: PackedByteArray, lost: Array = [], parity_first := false) -> bool:
	var n := (data.size() + 1399) / 1400
	var p := maxi(1, (n * 20 + 99) / 100)
	var plen := mini(data.size(), 1400)
	var parity: Array[PackedByteArray] = []
	for j in p:
		var b := PackedByteArray()
		b.resize(plen)
		parity.append(b)
	var packets: Array = []
	for i in n:
		var chunk := data.slice(i * 1400, mini(data.size(), (i + 1) * 1400))
		for k in chunk.size():
			parity[i % p][k] ^= chunk[k]
		if not lost.has(i):
			packets.append(header(i, n) + chunk)
	var tail: Array = []
	for j in p:
		var ph := PackedByteArray()
		ph.resize(6)
		ph.encode_u32(0, data.size())
		ph.encode_u16(4, p)
		tail.append(header(n + j, n) + ph + parity[j])
	if parity_first:
		packets = tail + packets
	else:
		packets.append_array(tail)
	var before := delivered.size()
	var t0 := Time.get_ticks_usec()
	for pkt in packets:
		net._on_video_packet(pkt)
	feed_ms = (Time.get_ticks_usec() - t0) / 1000.0
	next_frame += 1
	return delivered.size() == before + 1 and delivered[-1] == data

func header(index: int, count: int) -> PackedByteArray:
	var h := PackedByteArray()
	h.resize(9)
	h[0] = MON
	h.encode_u32(1, next_frame)
	h.encode_u16(5, index)
	h.encode_u16(7, count)
	return h

extends SceneTree
## Coreografía del vídeo de portfolio: la escena real del cliente recibiendo
## un host real (backend X11 sobre un Xvfb privado, ver desktop.sh) y guiada
## por un puntero con guion a través de las mismas llamadas que usan los
## mandos (main.pick(), LaserDrag, send_mouse_input, el teclado VR, la
## pizarra, el menú). Pensado para grabarse con Movie Maker (record.sh).
##
## Imprime "MARK <frame> <nombre>" al empezar cada escena: edit.py recorta
## con esas marcas. "RESULT fails=N" al final; el código de salida es N.

const TYPED := "// hola desde las gafas"
## Píxel de VS Code (monitor 1) donde se hace clic antes de escribir: la
## línea en blanco 102 de server.cpp tal como la deja desktop.sh.
const CLICK_PX := Vector2(900, 696)

var fails := 0
var main: Node3D
var cam: Camera3D
var pointer: Node3D
var beam: MeshInstance3D
var hand_pos := Vector3.ZERO
var look_goal := Vector3.ZERO
var look_now := Vector3.ZERO
## La cámara mira algo por encima de lo que sigue: deja aire sobre las
## pantallas (más cuando hay una encajada arriba).
var pitch_goal := 6.0
var pitch_now := 6.0
var follow: Node3D = null        ## si no es null, la cabeza lo sigue con la mirada
var trigger := false             ## gatillo del mando guionizado
var holding := false             ## algo agarrado por su barra o esquina
var _ui_pressed := false
var _on_kb := false
var _on_wb := false
var frame := 0                   ## fotogramas de la película (Movie Maker graba uno por frame)

func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	cam = main.get_node("XROrigin3D/XRCamera3D")
	cam.fov = 62.0
	process_frame.connect(func(): frame += 1)
	_build_pointer()
	_run()

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func mark(name: String) -> void:
	print("MARK %d %s" % [frame, name])

func _build_pointer() -> void:
	pointer = Node3D.new()
	root.add_child(pointer)
	beam = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.005, 0.005, 1.0)
	beam.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.93, 0.92, 0.88)
	beam.material_override = mat
	pointer.add_child(beam)
	pointer.visible = false

# ---------------------------------------------------------------------------
# Un fotograma: cabeza, rayo y lo que el rayo toca (como vr_input.gd)
# ---------------------------------------------------------------------------

func _step() -> void:
	if follow:
		look_goal = follow.global_position
	look_now = look_now.lerp(look_goal, 0.06)
	cam.look_at(look_now)
	# Un poco hacia arriba: aire sobre las pantallas.
	pitch_now = lerpf(pitch_now, pitch_goal, 0.04)
	cam.rotate_object_local(Vector3.RIGHT, deg_to_rad(pitch_now))
	pointer.global_position = hand_pos
	_update_beam()
	await process_frame

func _wait(n: int) -> void:
	for i in n:
		await _step()

func _update_beam() -> void:
	if not pointer.visible:
		return
	var o := pointer.global_position
	var d := -pointer.global_basis.z
	var hit: Dictionary = main.pick(o, d)
	var length: float = hit.get("distance", 4.0)
	beam.scale = Vector3(1, 1, length)
	beam.position = Vector3(0, 0, -length / 2.0)
	var kind: String = hit.get("kind", "")
	if kind == "bar":
		hit.bar.mark_hovered()
	if kind == "panel" and not holding:
		var px: Vector2i = hit.panel.uv_to_pixel(hit.uv)
		main.send_mouse_input(hit.monitor_id, px.x, px.y, 1 if trigger else 0, 0)
	if kind == "overlay":
		main.send_ui_pointer_move(hit.uv)
		if trigger != _ui_pressed:
			_ui_pressed = trigger
			main.send_ui_pointer_button(trigger)
	if kind == "keyboard":
		main.send_keyboard_pointer(o, d, trigger)
	elif _on_kb:
		main.leave_keyboard()
	_on_kb = kind == "keyboard"
	if kind == "whiteboard":
		main.send_whiteboard_pointer(o, d, trigger)
	elif _on_wb:
		main.leave_whiteboard()
	_on_wb = kind == "whiteboard"

## Gira el puntero hacia `at` en `n` fotogramas.
func _aim(at: Vector3, n: int) -> void:
	var from := pointer.global_basis.get_rotation_quaternion()
	var to := Basis.looking_at(at - hand_pos).get_rotation_quaternion()
	for i in n:
		pointer.global_basis = Basis(from.slerp(to, smoothstep(0.0, 1.0, float(i + 1) / n)))
		await _step()

func _click(hold: int = 4) -> void:
	trigger = true
	await _wait(hold)
	trigger = false
	await _wait(3)

func _grab_at(at: Vector3) -> Node:
	await _aim(at, 22)
	await _wait(6)
	var hit: Dictionary = main.pick(pointer.global_position, -pointer.global_basis.z)
	if hit.get("kind") != "bar" or not LaserDrag.grab(hit.target, pointer, hit.distance, main):
		return null
	holding = true
	return hit.target

func _drop(thing: Node) -> void:
	LaserDrag.drop(thing, main)
	holding = false

## Gira el puntero sobre su origen para que lo que sujeta en `from` vaya a `to`.
func _swing(from: Vector3, to: Vector3, n: int) -> void:
	var r := Quaternion((from - hand_pos).normalized(), (to - hand_pos).normalized())
	var q0 := pointer.global_basis.get_rotation_quaternion()
	for i in n:
		var t := smoothstep(0.0, 1.0, float(i + 1) / n)
		pointer.global_basis = Basis(Quaternion.IDENTITY.slerp(r, t) * q0)
		await _step()

func _place_facing_head(node: Node3D, dist: float, drop: float) -> void:
	var fwd := -cam.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var pos := cam.global_position + fwd * dist + Vector3(0, -drop, 0)
	node.global_transform = Transform3D(LaserDrag.facing_basis(pos, cam.global_position), pos)

func _hand_from_head() -> void:
	var fwd := -cam.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	hand_pos = cam.global_position + fwd * 0.25 + fwd.cross(Vector3.UP) * 0.2 + Vector3(0, -0.32, 0)

func _ui_point(ui: Node, c: Control) -> Vector3:
	var uv: Vector2 = c.get_global_rect().get_center() / Vector2(ui.VIEW_SIZE)
	return ui._panel_mesh.to_global(Vector3((uv.x - 0.5) * ui.panel_width, (0.5 - uv.y) * ui.panel_height, 0))

func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var b := _find_button(c, text)
		if b:
			return b
	return null

# ---------------------------------------------------------------------------
# Guion
# ---------------------------------------------------------------------------

func _run() -> void:
	var panels: Array = []
	for i in 30 * 40:
		panels = main._live_panels().filter(func(p): return p.is_active)
		if panels.size() == 3:
			break
		await process_frame
	check(panels.size() == 3, "three screens streaming")
	if panels.size() != 3:
		_finish()
		return
	panels.sort_custom(func(a, b): return int(a.get_meta("monitor_id")) < int(b.get_meta("monitor_id")))
	var left: Node3D = panels[0]
	var centre: Node3D = panels[1]
	var right: Node3D = panels[2]
	# Un paso atrás para que quepan los tres; la mano, abajo a la derecha.
	main.get_node("XROrigin3D").position += Vector3(0, 0.12, 1.1)
	look_now = centre.global_position
	look_goal = look_now
	await _wait(45)  # a que lleguen fotogramas nítidos

	# --- 1. Los monitores del PC, en directo --------------------------------
	mark("intro")
	look_goal = left.global_position.lerp(centre.global_position, 0.35)
	await _wait(75)
	look_goal = right.global_position.lerp(centre.global_position, 0.35)
	await _wait(95)
	look_goal = centre.global_position
	await _wait(50)

	_hand_from_head()
	pointer.global_basis = Basis.looking_at(centre.global_position + Vector3(0, -0.6, 0) - hand_pos)
	pointer.visible = true
	await _wait(10)

	# --- 2. Colocar las pantallas: mover, encajar, redimensionar ------------
	mark("layout")
	pitch_goal = 12.0
	var land: Transform3D = centre.landing_beside(load("res://scripts/screen_panel.gd").Side.TOP,
		right.panel_width, right.panel_height, main.SNAP_GAP_M)
	follow = right
	var grabbed := await _grab_at(right.grab_bar.global_position)
	check(grabbed == right, "the right screen is grabbed")
	var o: Vector3 = pointer.global_position
	var reach: float = o.distance_to(land.origin) - o.distance_to(right.global_position)
	await _swing(right.global_position, land.origin, 55)
	for i in 20:
		right.push_pull(reach / 20.0)
		await _step()
	await _wait(18)
	check(not main.snap_target_for(right).is_empty(), "the snap frame shows above the middle screen")
	_drop(right)
	await _wait(25)
	# El de en medio arrastra al que lleva encima.
	follow = null
	look_goal = centre.global_position.lerp(right.global_position, 0.5)
	grabbed = await _grab_at(centre.grab_bar.global_position)
	check(grabbed == centre, "the middle screen is grabbed")
	var bar_at: Vector3 = centre.grab_bar.global_position
	await _swing(bar_at, bar_at + cam.global_basis * Vector3(0.25, 0.05, 0), 40)
	await _swing(bar_at + cam.global_basis * Vector3(0.25, 0.05, 0), bar_at, 40)
	_drop(centre)
	await _wait(15)
	# Más grande por la esquina.
	var corner: Node3D = centre.resize_handles.filter(func(h): return h.corner == Vector2(1, -1))[0]
	var corner_at: Vector3 = corner.to_global(Vector3(1, -1, 0) * ResizeHandle.ZONE_OUT_M)
	var w0: float = centre.panel_width
	grabbed = await _grab_at(corner_at)
	check(grabbed == corner, "the corner handle is picked")
	await _swing(corner_at, corner_at + centre.global_basis * Vector3(0.3, -0.17, 0), 45)
	_drop(corner)
	check(centre.panel_width > w0 + 0.1, "dragging the corner makes it bigger")
	await _wait(40)

	# --- 3. El menú: pestañas y ambiente -------------------------------------
	mark("menu")
	main.toggle_ui_overlay()
	var ui: Node3D = main.ui_overlay
	ui.set_host_label("workstation")  # el nombre real del PC no sale en el vídeo
	_place_facing_head(ui, 0.95, 0.06)
	look_goal = ui.global_position
	await _wait(30)
	for tab in [1, 3, 2]:
		await _aim(_ui_point(ui, ui._tab_buttons[tab]), 16)
		await _wait(4)
		await _click()
		await _wait(26)
	var dusk := _find_button(ui, "Dusk")
	check(dusk != null, "the Dusk look button")
	if dusk:
		await _aim(_ui_point(ui, dusk), 18)
		await _click()
		await _wait(45)
	main.toggle_ui_overlay()
	await _wait(10)

	# --- 4. La pizarra ------------------------------------------------------
	mark("whiteboard")
	main.toggle_whiteboard()
	var wb: Node3D = main.whiteboard
	_place_facing_head(wb, 1.15, -0.01)
	wb.set_panel_width(1.05)
	look_goal = wb.global_position
	await _wait(25)
	var strokes := [
		# Un monitor con su pie
		[[0.10, 0.30], [0.38, 0.30], [0.38, 0.58], [0.10, 0.58], [0.10, 0.30]],
		[[0.24, 0.58], [0.24, 0.68]], [[0.17, 0.68], [0.31, 0.68]],
		# Flecha
		[[0.44, 0.45], [0.58, 0.45]], [[0.545, 0.41], [0.58, 0.45], [0.545, 0.49]],
		# Gafas: visor y dos lentes
		[[0.64, 0.36], [0.92, 0.36], [0.92, 0.56], [0.82, 0.56], [0.78, 0.50], [0.74, 0.56], [0.64, 0.56], [0.64, 0.36]],
	]
	var lens := []
	for c in [Vector2(0.705, 0.455), Vector2(0.855, 0.455)]:
		var ring := []
		for i in 17:
			var a := TAU * i / 16.0
			ring.append([c.x + 0.035 * cos(a), c.y + 0.055 * sin(a)])
		lens.append(ring)
	strokes.append_array(lens)
	for si in strokes.size():
		if si == 3:
			wb._select("ink", UiTheme.CLAY)
		elif si == 5:
			wb._select("ink", UiTheme.SAGE)
		var s: Array = strokes[si]
		var first: Vector3 = wb.to_global(wb.local_point(s[0][0], s[0][1]))
		await _aim(first, 9)
		trigger = true
		for j in range(1, s.size()):
			var a: Vector3 = wb.to_global(wb.local_point(s[j - 1][0], s[j - 1][1]))
			var b: Vector3 = wb.to_global(wb.local_point(s[j][0], s[j][1]))
			var n := maxi(2, int(a.distance_to(b) / 0.012))
			for k in n:
				pointer.global_basis = Basis.looking_at(a.lerp(b, float(k + 1) / n) - hand_pos)
				await _step()
		trigger = false
		await _step()
	check(wb.stroke_count() >= strokes.size() - 1, "the whiteboard has the drawing")
	await _wait(50)
	main.toggle_whiteboard()
	await _wait(8)

	# --- 5. Una pantalla virtual -------------------------------------------
	mark("virtual")
	main.select_monitor(0)  # tres a la vez: deja sitio quitando el portfolio
	await _wait(15)
	main.request_virtual_screen(1920, 1080)
	var virt: Node3D = null
	for i in 30 * 15:
		for p in main._live_panels():
			if int(p.get_meta("monitor_id")) >= 100 and p.is_active:
				virt = p
		if virt:
			break
		await _step()
	check(virt != null, "the virtual screen streams")
	if virt:
		follow = virt
		await _wait(70)
		follow = null
		var vbar: Vector3 = virt.grab_bar.global_position
		grabbed = await _grab_at(vbar)
		if grabbed == virt:
			look_goal = virt.global_position
			await _swing(vbar, vbar + cam.global_basis * Vector3(0.0, 0.12, 0.0), 35)
			_drop(virt)
	# --- 6. Ratón y teclado: escribir en VS Code desde la VR ----------------
	mark("control")
	pitch_goal = 6.0  # el teclado va abajo
	look_goal = centre.global_position
	_hand_from_head()
	pointer.visible = true
	var at: Vector3 = centre.to_global(centre.local_point(CLICK_PX.x / 1920.0, CLICK_PX.y / 1080.0))
	await _aim(at, 30)
	await _wait(8)
	await _click()
	await _wait(10)
	main.toggle_virtual_keyboard()
	var kb: Node3D = main.virtual_keyboard
	check(kb.visible, "the VR keyboard opens")
	_place_facing_head(kb, 0.62, 0.24)
	look_goal = centre.global_position.lerp(kb.global_position, 0.45)
	await _wait(25)
	for ch in TYPED:
		var key: Button = null
		for k in kb._keys:
			if (ch == " " and k.def[2] == 0x20) or (ch != " " and k.def[0] == ch):
				key = k.button
				break
		if key == null:
			check(false, "key for '%s'" % ch)
			continue
		var uv: Vector2 = key.get_global_rect().get_center() / Vector2(kb.VIEW_SIZE)
		var p: Vector3 = kb._quad.to_global(Vector3((uv.x - 0.5) * kb.WIDTH_M, (0.5 - uv.y) * kb.HEIGHT_M, 0))
		await _aim(p, 6)
		await _click(3)
	await _wait(10)
	main.toggle_virtual_keyboard()
	pointer.visible = false
	# Acercarse a leer lo escrito y volver.
	var origin: Node3D = main.get_node("XROrigin3D")
	var o0: Vector3 = origin.position
	var line: Vector3 = centre.to_global(centre.local_point(0.42, CLICK_PX.y / 1080.0))
	var closer: Vector3 = (line - cam.global_position).normalized() * 1.35
	closer.y *= 0.5
	look_goal = line
	for i in 45:
		origin.position = o0 + closer * smoothstep(0.0, 1.0, float(i + 1) / 45)
		await _step()
	await _wait(65)
	look_goal = centre.global_position
	for i in 40:
		origin.position = o0 + closer * (1.0 - smoothstep(0.0, 1.0, float(i + 1) / 40))
		await _step()
	await _wait(10)

	# Plano final
	mark("outro")
	pointer.visible = false
	var c := Vector3.ZERO
	var live: Array = main._live_panels()
	for p in live:
		c += p.global_position
	look_goal = c / maxf(1.0, live.size())
	await _wait(150)
	_finish()

func _finish() -> void:
	mark("end")
	print("RESULT fails=%d" % fails)
	quit(fails)

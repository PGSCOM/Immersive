## Shared collaborative whiteboard for Immersive-2 (Immersed parity: VR whiteboards
## several users can draw on, plus a high-resolution snapshot save).
##
## Drawn as a flat panel; strokes are stored in UV space so they are resolution
## independent and trivially serialisable for network sharing (each stroke carries
## the author's user_id + colour). Multiple users can draw at once (one in-progress
## stroke per user_id). snapshot() rasterises the board to a high-res Image.
##
## The geometry (ray → UV) and stroke bookkeeping are independent of the scene tree
## so they are unit-testable headlessly.

extends MeshInstance3D
class_name Whiteboard

## Board size in metres and backing texture resolution.
const BOARD_SIZE := Vector2(1.6, 0.9)
const TEX_W := 1024
const TEX_H := 576

const BG_COLOR := Color(0.97, 0.97, 0.98)
const DEFAULT_INK := Color(0.10, 0.12, 0.16)
const STROKE_THICKNESS := 3

## Finished strokes: { user_id:int, color:Color, points:PackedVector2Array (UV) }.
var _strokes: Array = []

## In-progress strokes keyed by author user_id.
var _active: Dictionary = {}

var _image: Image
var _texture: ImageTexture

func _ready() -> void:
	_build_surface()

func _build_surface() -> void:
	var plane := PlaneMesh.new()
	plane.orientation = PlaneMesh.FACE_Z
	plane.size = BOARD_SIZE
	mesh = plane
	_ensure_image()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _texture
	material_override = mat

func _ensure_image() -> void:
	if _image == null:
		_image = Image.create(TEX_W, TEX_H, false, Image.FORMAT_RGBA8)
		_image.fill(BG_COLOR)
		_texture = ImageTexture.create_from_image(_image)

# ---------------------------------------------------------------------------
# Drawing API (driven by the controller / hand pointer)
# ---------------------------------------------------------------------------

## Begin a stroke for `user_id` at `uv` with `color`.
func begin_stroke(user_id: int, uv: Vector2, color: Color = DEFAULT_INK) -> void:
	_active[user_id] = {
		"user_id": user_id,
		"color": color,
		"points": PackedVector2Array([_clamp_uv(uv)]),
	}

## Append a point to `user_id`'s active stroke, drawing the new segment live.
func append_point(user_id: int, uv: Vector2) -> void:
	if not _active.has(user_id):
		begin_stroke(user_id, uv)
		return
	var stroke: Dictionary = _active[user_id]
	var pts: PackedVector2Array = stroke["points"]
	var last := pts[pts.size() - 1]
	var p := _clamp_uv(uv)
	pts.append(p)
	stroke["points"] = pts
	_ensure_image()
	_draw_segment(last, p, stroke["color"])
	_texture.update(_image)

## Finish `user_id`'s active stroke and commit it to the board.
func end_stroke(user_id: int) -> void:
	if not _active.has(user_id):
		return
	_strokes.append(_active[user_id])
	_active.erase(user_id)

## Add a completed stroke received from another user (network share) and draw it.
func apply_remote_stroke(stroke: Dictionary) -> void:
	var pts: PackedVector2Array = stroke.get("points", PackedVector2Array())
	if pts.is_empty():
		return
	_strokes.append(stroke)
	_ensure_image()
	var color: Color = stroke.get("color", DEFAULT_INK)
	for i in range(1, pts.size()):
		_draw_segment(pts[i - 1], pts[i], color)
	if pts.size() == 1:
		_draw_segment(pts[0], pts[0], color)
	_texture.update(_image)

## Erase everything.
func clear_board() -> void:
	_strokes.clear()
	_active.clear()
	_ensure_image()
	_image.fill(BG_COLOR)
	_texture.update(_image)

# ---------------------------------------------------------------------------
# Queries / serialisation
# ---------------------------------------------------------------------------

func get_stroke_count() -> int:
	return _strokes.size()

func get_active_count() -> int:
	return _active.size()

## Serialise a finished stroke to a JSON-friendly dict (flat point list).
static func stroke_to_dict(stroke: Dictionary) -> Dictionary:
	var flat: Array = []
	var pts: PackedVector2Array = stroke.get("points", PackedVector2Array())
	for p in pts:
		flat.append(p.x)
		flat.append(p.y)
	var c: Color = stroke.get("color", DEFAULT_INK)
	return {
		"user_id": stroke.get("user_id", 0),
		"color": [c.r, c.g, c.b],
		"points": flat,
	}

## Rebuild a stroke dict from its serialised form.
static func stroke_from_dict(data: Dictionary) -> Dictionary:
	var pts := PackedVector2Array()
	var flat: Array = data.get("points", [])
	var i := 0
	while i + 1 < flat.size():
		pts.append(Vector2(flat[i], flat[i + 1]))
		i += 2
	var c: Array = data.get("color", [DEFAULT_INK.r, DEFAULT_INK.g, DEFAULT_INK.b])
	return {
		"user_id": int(data.get("user_id", 0)),
		"color": Color(c[0], c[1], c[2]) if c.size() >= 3 else DEFAULT_INK,
		"points": pts,
	}

## The most recently finished stroke, serialised for sharing (or {} if none).
func last_stroke_serialized() -> Dictionary:
	if _strokes.is_empty():
		return {}
	return stroke_to_dict(_strokes[_strokes.size() - 1])

# ---------------------------------------------------------------------------
# Snapshot (high-resolution save)
# ---------------------------------------------------------------------------

## A copy of the current board image (high-res capture of all strokes).
func snapshot() -> Image:
	_ensure_image()
	return _image.duplicate()

## Save a PNG snapshot of the board. Returns true on success.
func save_snapshot(path: String) -> bool:
	return snapshot().save_png(path) == OK

# ---------------------------------------------------------------------------
# Geometry — ray → board UV (pure, unit-tested)
# ---------------------------------------------------------------------------

## Intersect a world ray with this board, returning { valid, uv, distance }.
func ray_to_uv(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	return ray_to_board_uv(global_transform, BOARD_SIZE, ray_origin, ray_direction)

## Pure ray → UV for a board rectangle of `size` centred on `xform` (local Z
## normal). UV (0,0) is the top-left. Returns { valid, uv, distance }.
static func ray_to_board_uv(xform: Transform3D, size: Vector2,
		ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	var normal: Vector3 = xform.basis.z.normalized()
	var denom: float = ray_direction.dot(normal)
	if absf(denom) < 0.0001:
		return {"valid": false}
	var t: float = (xform.origin - ray_origin).dot(normal) / denom
	if t < 0.0:
		return {"valid": false}
	var local: Vector3 = xform.affine_inverse() * (ray_origin + ray_direction * t)
	if absf(local.x) > size.x * 0.5 or absf(local.y) > size.y * 0.5:
		return {"valid": false}
	var u := local.x / size.x + 0.5
	var v := 0.5 - local.y / size.y
	return {"valid": true, "uv": Vector2(u, v), "distance": t}

# ---------------------------------------------------------------------------
# Internal raster
# ---------------------------------------------------------------------------

func _clamp_uv(uv: Vector2) -> Vector2:
	return Vector2(clampf(uv.x, 0.0, 1.0), clampf(uv.y, 0.0, 1.0))

func _draw_segment(uv_a: Vector2, uv_b: Vector2, color: Color) -> void:
	var a := Vector2i(int(uv_a.x * (TEX_W - 1)), int(uv_a.y * (TEX_H - 1)))
	var b := Vector2i(int(uv_b.x * (TEX_W - 1)), int(uv_b.y * (TEX_H - 1)))
	# Bresenham with a square brush for thickness.
	var dx := absi(b.x - a.x)
	var dy := -absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx + dy
	var x := a.x
	var y := a.y
	while true:
		_plot_brush(x, y, color)
		if x == b.x and y == b.y:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy

func _plot_brush(cx: int, cy: int, color: Color) -> void:
	var r := STROKE_THICKNESS / 2
	for oy in range(-r, r + 1):
		for ox in range(-r, r + 1):
			var px := cx + ox
			var py := cy + oy
			if px >= 0 and px < TEX_W and py >= 0 and py < TEX_H:
				_image.set_pixel(px, py, color)

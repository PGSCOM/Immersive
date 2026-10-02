## The white frame that shows where a dragged screen would land when released
## beside another one (main.gd drives it). A thin flat outline, drawn over
## everything so it never hides behind the screen being moved; on a curved
## screen it follows the arc.

extends MeshInstance3D
class_name SnapFrame

const LINE_M := 0.008
const COLUMNS := 24

var _built := Vector3(-1.0, -1.0, -1.0)  ## width, height, arc the mesh was built for

func _init() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.92)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = 1
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false

## Outline a `w` x `h` metre screen of arc `arc` radians (0 = flat) at `xform`.
func show_at(xform: Transform3D, w: float, h: float, arc: float) -> void:
	if _built != Vector3(w, h, arc):
		_built = Vector3(w, h, arc)
		mesh = _ring(w, h, arc)
	global_transform = xform
	visible = true

func clear() -> void:
	visible = false

## A point on the screen's surface: `s` metres along its width from the
## centre, height `y`.
static func _point(s: float, y: float, w: float, arc: float) -> Vector3:
	if arc < 0.001:
		return Vector3(s, y, 0.0)
	var r := w / arc
	return Vector3(r * sin(s / r), y, r * (1.0 - cos(s / r)))

## The border as one flat ribbon, LINE_M wide, inside the screen's edge.
static func _ring(w: float, h: float, arc: float) -> ArrayMesh:
	var n := COLUMNS if arc >= 0.001 else 1
	var outer := PackedVector3Array()
	var inner := PackedVector3Array()
	var hw := w / 2.0
	var hh := h / 2.0
	# Along the bottom edge left to right, then the top edge right to left;
	# the vertical edges are the two joins.
	for top in [false, true]:
		var y := hh if top else -hh
		var yi := hh - LINE_M if top else -hh + LINE_M
		for i in range(n + 1):
			var f := float(i) / n
			if top:
				f = 1.0 - f
			outer.append(_point(lerpf(-hw, hw, f), y, w, arc))
			inner.append(_point(lerpf(-hw + LINE_M, hw - LINE_M, f), yi, w, arc))
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	var count := outer.size()
	for i in range(count):
		verts.append(outer[i])
		verts.append(inner[i])
	for i in range(count):
		var a := i * 2
		var b := ((i + 1) % count) * 2
		indices.append_array([a, b, a + 1, a + 1, b, b + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m

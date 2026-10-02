## The space around the screens: sky, floor and ambient light.
##
## A few hand-tuned looks ("night", "dusk", "void") share one sky shader and
## one floor. Passthrough turns both off so the room shows through.

extends Node3D

const LOOKS := {
	"night": {
		"zenith": Color(0.018, 0.021, 0.021), "horizon": Color(0.078, 0.064, 0.054),
		"ground": Color(0.012, 0.012, 0.011), "glow": Color(0.40, 0.20, 0.11),
		"glow_strength": 0.30, "glow_height": 16.0, "sun_strength": 0.0,
		"stars": 0.012, "star_brightness": 0.55,
		"floor": Color(0.022, 0.022, 0.020), "pool": Color(0.050, 0.047, 0.040),
		"ambient": 0.25, "has_floor": true,
	},
	"dusk": {
		"zenith": Color(0.055, 0.095, 0.105), "horizon": Color(0.40, 0.25, 0.165),
		"ground": Color(0.03, 0.025, 0.022), "glow": Color(0.85, 0.40, 0.17),
		"glow_strength": 0.55, "glow_height": 9.0, "sun_strength": 1.0,
		"stars": 0.004, "star_brightness": 0.25,
		"floor": Color(0.050, 0.041, 0.036), "pool": Color(0.075, 0.066, 0.056),
		"ambient": 0.45, "has_floor": true,
	},
	"void": {
		"zenith": Color(0, 0, 0), "horizon": Color(0, 0, 0), "ground": Color(0, 0, 0),
		"glow": Color(0, 0, 0), "glow_strength": 0.0, "glow_height": 10.0,
		"sun_strength": 0.0, "stars": 0.0, "star_brightness": 0.0,
		"floor": Color(0, 0, 0), "pool": Color(0, 0, 0), "ambient": 0.2, "has_floor": false,
	},
}
const DEFAULT_LOOK := "night"
## A local (not stage) reference space puts y=0 at head height; the floor
## then goes this far under the head instead.
const STANDING_EYE_HEIGHT := 1.55

var look: String = DEFAULT_LOOK
var passthrough: bool = false

var _env: Environment
var _sky_mat: ShaderMaterial
var _floor: MeshInstance3D
var _floor_mat: ShaderMaterial
var _floor_fitted_s: float = 0.0

func _ready() -> void:
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = load("res://shaders/sky.gdshader")
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_QUALITY  # static sky: bake once
	_env = Environment.new()
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_env := WorldEnvironment.new()
	world_env.environment = _env
	add_child(world_env)

	_floor_mat = ShaderMaterial.new()
	_floor_mat.shader = load("res://shaders/floor.gdshader")
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	_floor = MeshInstance3D.new()
	_floor.mesh = plane
	_floor.material_override = _floor_mat
	_floor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_floor)
	_apply()

## During the first seconds of tracking, and after a recenter, sit the floor
## on the real one: y=0 on a stage space, a standing height under the head on
## a local one.
func _process(delta: float) -> void:
	if _floor_fitted_s > 3.0:
		return
	_floor_fitted_s += delta
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var head_y := camera.global_position.y
	_floor.position.y = 0.0 if head_y > 0.8 else head_y - STANDING_EYE_HEIGHT

func refit_floor() -> void:
	_floor_fitted_s = 0.0

func set_look(name: String) -> void:
	look = name if LOOKS.has(name) else DEFAULT_LOOK
	_apply()

func set_passthrough(enabled: bool) -> void:
	passthrough = enabled
	_apply()

func _apply() -> void:
	if _env == null:
		return
	var l: Dictionary = LOOKS[look]
	if passthrough:
		_env.background_mode = Environment.BG_COLOR
		_env.background_color = Color(0, 0, 0, 0)
	else:
		_env.background_mode = Environment.BG_SKY
	_env.ambient_light_color = Color(0.9, 0.87, 0.8)
	_env.ambient_light_energy = l.ambient
	_sky_mat.set_shader_parameter("zenith_color", l.zenith)
	_sky_mat.set_shader_parameter("horizon_color", l.horizon)
	_sky_mat.set_shader_parameter("ground_color", l.ground)
	_sky_mat.set_shader_parameter("glow_color", l.glow)
	_sky_mat.set_shader_parameter("glow_strength", l.glow_strength)
	_sky_mat.set_shader_parameter("glow_height", l.glow_height)
	_sky_mat.set_shader_parameter("sun_strength", l.sun_strength)
	_sky_mat.set_shader_parameter("star_density", l.stars)
	_sky_mat.set_shader_parameter("star_brightness", l.star_brightness)
	_floor_mat.set_shader_parameter("floor_color", l.floor)
	_floor_mat.set_shader_parameter("pool_color", l.pool)
	_floor_mat.set_shader_parameter("horizon_color", l.horizon)
	_floor.visible = l.has_floor and not passthrough

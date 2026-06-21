## Themed virtual environments for Immersive-2 (Immersed parity: café, space
## lounge, mountain lodge, starship, …). Builds a Godot Environment per theme and
## applies it to a WorldEnvironment node. Also models Immersed's "weekly rotating
## environments" (Starter sees 2, Pro sees 5) as a deterministic subset.
##
## Pure builders (build_environment / weekly_rotation) are side-effect-free so the
## catalogue and rotation are unit-testable without a live viewport.

extends Node
class_name EnvironmentManager

## Emitted after the active environment changes (index, id).
signal environment_changed(index: int, id: String)

## Catalogue of themed environments. `sky_top`/`sky_horizon` drive a procedural
## sky; `ambient` + `energy` set the ambient light; `fog` toggles distance fog.
const ENVIRONMENTS := [
	{
		"id": "void", "name": "Void",
		"sky_top": Color(0.02, 0.03, 0.08), "sky_horizon": Color(0.05, 0.06, 0.12),
		"ambient": Color(0.05, 0.05, 0.12), "energy": 0.4, "fog": false,
	},
	{
		"id": "cafe", "name": "Café",
		"sky_top": Color(0.20, 0.16, 0.13), "sky_horizon": Color(0.45, 0.36, 0.28),
		"ambient": Color(0.35, 0.28, 0.22), "energy": 0.9, "fog": true,
	},
	{
		"id": "space", "name": "Space Lounge",
		"sky_top": Color(0.01, 0.01, 0.03), "sky_horizon": Color(0.06, 0.04, 0.14),
		"ambient": Color(0.10, 0.10, 0.20), "energy": 0.5, "fog": false,
	},
	{
		"id": "lodge", "name": "Mountain Lodge",
		"sky_top": Color(0.30, 0.45, 0.70), "sky_horizon": Color(0.75, 0.82, 0.92),
		"ambient": Color(0.45, 0.50, 0.58), "energy": 1.1, "fog": true,
	},
	{
		"id": "starship", "name": "Starship",
		"sky_top": Color(0.03, 0.05, 0.08), "sky_horizon": Color(0.10, 0.16, 0.22),
		"ambient": Color(0.14, 0.18, 0.24), "energy": 0.7, "fog": false,
	},
]

## Seconds in a week, for the rotation schedule.
const WEEK_SECONDS := 7 * 24 * 60 * 60

var _current_index: int = 0
var _world_env: WorldEnvironment = null

# ---------------------------------------------------------------------------
# Catalogue queries
# ---------------------------------------------------------------------------

func get_environment_count() -> int:
	return ENVIRONMENTS.size()

func get_environment_names() -> Array:
	var names: Array = []
	for e in ENVIRONMENTS:
		names.append(e["name"])
	return names

func get_environment_ids() -> Array:
	var ids: Array = []
	for e in ENVIRONMENTS:
		ids.append(e["id"])
	return ids

func get_current_index() -> int:
	return _current_index

func get_current_id() -> String:
	return ENVIRONMENTS[_current_index]["id"]

func get_current_name() -> String:
	return ENVIRONMENTS[_current_index]["name"]

func index_of_id(id: String) -> int:
	for i in range(ENVIRONMENTS.size()):
		if ENVIRONMENTS[i]["id"] == id:
			return i
	return -1

# ---------------------------------------------------------------------------
# Switching
# ---------------------------------------------------------------------------

## Bind the WorldEnvironment node this manager drives (optional; without it the
## manager still tracks state and can build Environments for the caller).
func set_world_environment(world_env: WorldEnvironment) -> void:
	_world_env = world_env
	_apply_current()

## Activate an environment by index. Returns false if out of range.
func set_environment(index: int) -> bool:
	if index < 0 or index >= ENVIRONMENTS.size():
		return false
	_current_index = index
	_apply_current()
	environment_changed.emit(_current_index, get_current_id())
	return true

## Activate an environment by id. Returns false if unknown.
func set_environment_by_id(id: String) -> bool:
	var idx := index_of_id(id)
	if idx < 0:
		return false
	return set_environment(idx)

## Advance to the next environment (wraps). Returns the new index.
func next_environment() -> int:
	set_environment((_current_index + 1) % ENVIRONMENTS.size())
	return _current_index

## Go to the previous environment (wraps). Returns the new index.
func previous_environment() -> int:
	set_environment((_current_index - 1 + ENVIRONMENTS.size()) % ENVIRONMENTS.size())
	return _current_index

# ---------------------------------------------------------------------------
# Weekly rotation (Immersed: Starter = 2, Pro = 5 rotating each week)
# ---------------------------------------------------------------------------

## Deterministic rotating subset of `count` environment indices for a given week.
## `week` defaults to the real ISO-ish week number derived from the system clock;
## pass an explicit value in tests. The window slides by one environment per week
## and wraps around the catalogue.
func weekly_rotation(count: int, week: int = -1) -> Array:
	var total := ENVIRONMENTS.size()
	var n: int = clampi(count, 0, total)
	if n == 0:
		return []
	var wk := week if week >= 0 else int(Time.get_unix_time_from_system()) / WEEK_SECONDS
	var start := ((wk % total) + total) % total
	var result: Array = []
	for i in range(n):
		result.append((start + i) % total)
	return result

# ---------------------------------------------------------------------------
# Environment building / application
# ---------------------------------------------------------------------------

## Build a Godot Environment resource for the given catalogue index (pure).
func build_environment(index: int) -> Environment:
	var data: Dictionary = ENVIRONMENTS[clampi(index, 0, ENVIRONMENTS.size() - 1)]
	var env := Environment.new()

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = data["sky_top"]
	sky_mat.sky_horizon_color = data["sky_horizon"]
	sky_mat.ground_bottom_color = data["sky_top"].darkened(0.3)
	sky_mat.ground_horizon_color = data["sky_horizon"].darkened(0.2)
	var sky := Sky.new()
	sky.sky_material = sky_mat

	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = data["ambient"]
	env.ambient_light_energy = data["energy"]
	env.fog_enabled = bool(data["fog"])
	if bool(data["fog"]):
		env.fog_light_color = data["sky_horizon"]
		env.fog_density = 0.01
	return env

var _passthrough: bool = false

## Switch the bound WorldEnvironment to a transparent (clear) background for
## passthrough/mixed reality, or back to the themed sky when disabled. Without
## this the opaque themed sky would occlude the real-world passthrough feed.
func set_passthrough(enabled: bool) -> void:
	_passthrough = enabled
	if not is_instance_valid(_world_env):
		return
	if enabled:
		_world_env.environment = build_passthrough_environment()
	else:
		_apply_current()

## A minimal environment with no drawn background, for passthrough compositing.
func build_passthrough_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.5)
	env.ambient_light_energy = 1.0
	return env

func is_passthrough() -> bool:
	return _passthrough

func _apply_current() -> void:
	if is_instance_valid(_world_env):
		if _passthrough:
			_world_env.environment = build_passthrough_environment()
		else:
			_world_env.environment = build_environment(_current_index)

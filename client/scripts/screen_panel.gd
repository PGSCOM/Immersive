## Virtual screen panel for displaying streamed desktop content.
## Attached to a MeshInstance3D (PlaneMesh) in the VR scene.

extends MeshInstance3D

## Screen texture that receives decoded frames.
var screen_texture: ImageTexture
## Current screen image.
var screen_image: Image

## Video decoder instance.
var decoder: VideoDecoder

## Screen dimensions.
var screen_width: int = 1920
var screen_height: int = 1080

## Panel dimensions in meters (16:9 aspect ratio).
var panel_width: float = 1.6
var panel_height: float = 0.9

## Whether the screen is currently receiving frames.
var is_active: bool = false

func _ready() -> void:
	decoder = VideoDecoder.new()
	_create_placeholder_texture()

## Set the resolution and update the panel aspect ratio.
func set_resolution(width: int, height: int) -> void:
	screen_width = width
	screen_height = height

	# Update panel aspect ratio
	var aspect: float = float(width) / float(height)
	panel_height = panel_width / aspect

	# Update the mesh size
	if mesh is PlaneMesh:
		(mesh as PlaneMesh).size = Vector2(panel_width, panel_height)

	# Initialize decoder
	decoder.initialize(width, height)

	# Create a properly-sized texture
	screen_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	screen_image.fill(Color(0.1, 0.1, 0.1, 1.0))
	screen_texture = ImageTexture.create_from_image(screen_image)
	_apply_texture()

	is_active = true
	print("[ScreenPanel] Resolution set: %dx%d, panel: %.2f x %.2f m" %
		[width, height, panel_width, panel_height])

## Update the screen texture with new video frame data.
func update_texture(frame_data: PackedByteArray, width: int, height: int) -> void:
	if not is_active:
		return

	# Decode the video frame
	var pixels: PackedByteArray = decoder.decode_frame(frame_data)
	if pixels.is_empty():
		return

	# Update the image and texture
	screen_image = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, pixels)
	screen_texture.update(screen_image)

## Create a placeholder texture (shown before streaming starts).
func _create_placeholder_texture() -> void:
	screen_image = Image.create(screen_width, screen_height, false, Image.FORMAT_RGBA8)

	# Draw a dark background with "Waiting for connection..." text hint
	screen_image.fill(Color(0.05, 0.05, 0.08, 1.0))

	# Draw a simple border
	for x in range(screen_width):
		screen_image.set_pixel(x, 0, Color(0.3, 0.3, 0.5, 1.0))
		screen_image.set_pixel(x, screen_height - 1, Color(0.3, 0.3, 0.5, 1.0))
	for y in range(screen_height):
		screen_image.set_pixel(0, y, Color(0.3, 0.3, 0.5, 1.0))
		screen_image.set_pixel(screen_width - 1, y, Color(0.3, 0.3, 0.5, 1.0))

	screen_texture = ImageTexture.create_from_image(screen_image)
	_apply_texture()

## Apply the current texture to the material.
func _apply_texture() -> void:
	var mat := material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("screen_texture", screen_texture)

## Convert a 3D world position to screen UV coordinates.
## Returns Vector2(-1, -1) if the point is not on the screen.
func world_to_screen_uv(world_pos: Vector3) -> Vector2:
	var local_pos: Vector3 = global_transform.affine_inverse() * world_pos

	# Check if point is on the panel plane (z ≈ 0)
	if abs(local_pos.z) > 0.01:
		return Vector2(-1, -1)

	# Convert to UV (0..1)
	var u: float = (local_pos.x / panel_width) + 0.5
	var v: float = 0.5 - (local_pos.y / panel_height)

	if u < 0 or u > 1 or v < 0 or v > 1:
		return Vector2(-1, -1)

	return Vector2(u, v)

## Convert UV coordinates to pixel coordinates on the screen.
func uv_to_pixel(uv: Vector2) -> Vector2i:
	return Vector2i(
		int(uv.x * screen_width),
		int(uv.y * screen_height)
	)

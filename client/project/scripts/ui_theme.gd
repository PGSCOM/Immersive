## Colours, type and box styles shared by the in-VR menu and keyboard.
## Same tokens as the web control page (web/client/styles.css), so the whole
## product reads as one: warm charcoal surfaces, bone ink, no loud accent —
## the only saturated colour is the red "live" tally.

extends RefCounted
class_name UiTheme

const GROUND := Color("13110f")
const SURFACE := Color("1c1a17")
const SURFACE_HI := Color("25221e")
const SURFACE_HOVER := Color("302c27")
const WELL := Color("0b0a09")
const EDGE := Color(0.925, 0.902, 0.863, 0.07)
const EDGE_HI := Color(0.925, 0.902, 0.863, 0.16)
const INK := Color("ece6dc")
const INK_2 := Color("b4ac9f")
## Lighter than the web's #847c71: a headset resolves ~20 px per degree, and
## small hints need more contrast there than on a monitor (5.9:1 on GROUND).
const INK_3 := Color("9a9184")
const TALLY := Color("d9533b")
const CLAY := Color("e39a7f")
const SAGE := Color("a9bf9c")
const OCHRE := Color("d6b36e")
## One per person in a multiplayer room (avatar, name in the menu): quiet
## tints off the bone ink, light enough to read on GROUND.
const PEOPLE := [Color("a9bf9c"), Color("d6b36e"), Color("e39a7f"), Color("8fb8b0"),
	Color("c2c98f"), Color("cdb8a0"), Color("9fb7cf"), Color("d9a3b0")]

const DISPLAY_FONT_PATH := "res://fonts/Grotesk-04Gras.woff2"

static var _display_font: Font = null

## Grotesk (Velvetyne, SIL OFL) for headings; body text and key caps keep
## Godot's neutral default.
static func display_font() -> Font:
	if _display_font == null:
		_display_font = load(DISPLAY_FONT_PATH) as Font
		if _display_font == null:
			_display_font = ThemeDB.fallback_font
	return _display_font

## Rounded box with an optional self-coloured edge (a lip, not an outline).
static func box(bg: Color, radius: int = 10, pad_h: int = 14, pad_v: int = 10,
		edge: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.corner_detail = 6
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	s.anti_aliasing = true
	if edge.a > 0.0:
		s.border_color = edge
		s.set_border_width_all(1)
	return s

static func empty() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()

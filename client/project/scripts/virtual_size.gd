## Sizes of the virtual screens a headset asks its PC for: the shapes and
## sizes the menu offers, the 1:1 size, how big a new one hangs and what an
## H.264 stream of it carries. Pure maths, shared by main.gd and the menu.

extends RefCounted
class_name VirtualSize

## What the host makes (host/src/main.cpp clamps requests to this).
const MIN := Vector2i(640, 480)
const MAX := Vector2i(7680, 4320)
## Shapes offered, landscape: [label, aspect, three common sizes].
const SHAPES := [
	["16:9", 16.0 / 9.0, [Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]],
	["16:10", 1.6, [Vector2i(1920, 1200), Vector2i(2560, 1600), Vector2i(3840, 2400)]],
	["21:9", 64.0 / 27.0, [Vector2i(2560, 1080), Vector2i(3440, 1440), Vector2i(5120, 2160)]],
	["32:9", 32.0 / 9.0, [Vector2i(3840, 1080), Vector2i(5120, 1440), Vector2i(7680, 2160)]],
	["4:3", 4.0 / 3.0, [Vector2i(1600, 1200), Vector2i(2048, 1536), Vector2i(3200, 2400)]],
	["3:2", 1.5, [Vector2i(2160, 1440), Vector2i(3000, 2000), Vector2i(3840, 2560)]],
]
## A new screen covers the default 16:9 one's area (1.6 x 0.9 m, 1.25 m
## away), within these bounds: a portrait one is not 2.8 m tall.
const AREA_M2 := 1.44
const MAX_W_M := 2.4
const MAX_H_M := 1.2

## Index into SHAPES of the shape w x h has (either way up), -1 for none.
static func shape_of(w: int, h: int) -> int:
	var a := float(maxi(w, h)) / float(maxi(1, mini(w, h)))
	for i in SHAPES.size():
		if absf(a / SHAPES[i][1] - 1.0) < 0.012:
			return i
	return -1

## Pixels for a w x h shaped screen: aspect kept, scaled into what the host
## makes and to at most `cap` a side, multiples of 8.
static func fit(w: float, h: float, cap: int = MAX.x) -> Vector2i:
	var s := maxf(MIN.x / w, MIN.y / h)
	if s < 1.0:
		s = minf(1.0, minf(mini(MAX.x, cap) / w, mini(MAX.y, cap) / h))
	return Vector2i(clampi(roundi(w * s / 8.0) * 8, MIN.x, mini(MAX.x, cap)),
		clampi(roundi(h * s / 8.0) * 8, MIN.y, mini(MAX.y, cap)))

## Degrees a screen `width_m` wide spans from `distance_m` away.
static func angle_deg(width_m: float, distance_m: float) -> float:
	return rad_to_deg(2.0 * atan(width_m / (2.0 * maxf(0.3, distance_m))))

## Pixels that make a screen `width_m` wide, `distance_m` away, 1:1 with a
## headset resolving `ppd` pixels per degree; at most 3840 a side, which H.264
## carries whole.
static func one_to_one(width_m: float, distance_m: float, aspect: float, ppd: float) -> Vector2i:
	var w := ppd * angle_deg(width_m, distance_m)
	return fit(w, w / maxf(aspect, 0.1), 3840)

## Metres wide a new screen of this aspect hangs (AREA_M2 within the bounds).
static func default_width_m(aspect: float) -> float:
	return minf(sqrt(AREA_M2 * aspect), minf(MAX_W_M, MAX_H_M * aspect))

## Metres wide a screen `width_m` wide stays when its pixels change shape:
## the same for the same shape, else scaled as it was from its own default.
static func replaced_width_m(width_m: float, old_aspect: float, new_aspect: float) -> float:
	if absf(new_aspect / old_aspect - 1.0) < 0.012:
		return width_m
	return width_m * default_width_m(new_aspect) / default_width_m(old_aspect)

## What an H.264 stream of a w x h screen carries: the host keeps H.264 in
## Level 5.2 (4096 a side, 36864 macroblocks); fit_h264 in host/src/main.cpp.
static func h264_size(w: int, h: int) -> Vector2i:
	var mbs := float(ceili(w / 16.0) * ceili(h / 16.0))
	var s := minf(minf(1.0, 4096.0 / w), minf(4096.0 / h, sqrt(36864.0 / mbs)))
	if s >= 1.0:
		return Vector2i(w, h)
	return Vector2i(int(w * s + 0.5) & ~15, int(h * s + 0.5) & ~15)

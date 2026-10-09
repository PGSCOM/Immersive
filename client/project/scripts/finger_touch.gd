## One fingertip at a time touching a flat 2D panel (whiteboard, keyboard,
## menu): which hand owns it and whether it presses. The panel feeds it the
## tip's depth in front of its plane every frame and calls tick() once a frame.
##
## A tip within HOVER_M in front owns the panel (hover, ring); within
## CONTACT_M it presses, and lets go above RELEASE_M (the gap keeps tracking
## noise from stuttering). It must arrive from the front: behind the plane it
## only keeps a panel it already owns (pushed through by more than BEHIND_M it
## is reaching round, not touching). The other hand takes over by touching
## while the owner is not pressing, so two index fingers can type in turn.
##
## Owning is not yet touching: the pointing hand keeps its ray until the tip
## comes within REST_M (`resting`), and then until it leaves the panel. A hand
## pointing past a panel near it (the keyboard sits at chest height, within
## arm's reach) keeps pointing.

extends RefCounted
class_name FingerTouch

const HOVER_M := 0.08
const CONTACT_M := 0.008
const RELEASE_M := 0.02
const BEHIND_M := 0.06
const REST_M := 0.03

var owner := -1        ## which hand owns the panel, -1 none
var pressed := false
var depth := 0.0       ## the owner's tip in front of the plane, metres
var resting := false   ## the owner came within REST_M: its hand's ray rests
var _frames := 0

## Hand `who`'s tip `d` metres in front of the plane, `inside` its outline.
## True while `who` owns the panel; `pressed` then says whether it presses.
func touch(who: int, d: float, inside: bool) -> bool:
	var near := inside and d <= HOVER_M and d >= (-BEHIND_M if who == owner else 0.0)
	if who != owner:
		if not near or (owner >= 0 and (pressed or d >= CONTACT_M)):
			return false
		owner = who
		pressed = false
		resting = false
	elif not near:
		release()
		return false
	_frames = 3
	depth = d
	pressed = d < (RELEASE_M if pressed else CONTACT_M)
	resting = resting or pressed or d < REST_M
	return true

## Once a frame: true when the owner just went unheard for a few frames.
func tick() -> bool:
	if _frames <= 0:
		return false
	_frames -= 1
	if _frames == 0:
		release()
		return true
	return false

func release() -> void:
	owner = -1
	pressed = false
	resting = false
	_frames = 0

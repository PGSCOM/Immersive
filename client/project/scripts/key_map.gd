## Godot keycode → Windows virtual-key code (what the host expects in
## INPUT_KEYBOARD, on every OS). Physical keycodes are layout-independent, so
## this is a US-layout position map; the PC applies its own layout.

extends RefCounted
class_name KeyMap

const _SPECIAL := {
	KEY_BACKSPACE: 0x08, KEY_TAB: 0x09, KEY_ENTER: 0x0D, KEY_KP_ENTER: 0x0D,
	KEY_SHIFT: 0x10, KEY_CTRL: 0x11, KEY_ALT: 0x12, KEY_PAUSE: 0x13,
	KEY_CAPSLOCK: 0x14, KEY_ESCAPE: 0x1B, KEY_SPACE: 0x20, KEY_PAGEUP: 0x21,
	KEY_PAGEDOWN: 0x22, KEY_END: 0x23, KEY_HOME: 0x24, KEY_LEFT: 0x25,
	KEY_UP: 0x26, KEY_RIGHT: 0x27, KEY_DOWN: 0x28, KEY_PRINT: 0x2C,
	KEY_INSERT: 0x2D, KEY_DELETE: 0x2E, KEY_META: 0x5B, KEY_MENU: 0x5D,
	KEY_KP_MULTIPLY: 0x6A, KEY_KP_ADD: 0x6B, KEY_KP_SUBTRACT: 0x6D,
	KEY_KP_PERIOD: 0x6E, KEY_KP_DIVIDE: 0x6F, KEY_NUMLOCK: 0x90,
	KEY_SCROLLLOCK: 0x91, KEY_SEMICOLON: 0xBA, KEY_EQUAL: 0xBB, KEY_COMMA: 0xBC,
	KEY_MINUS: 0xBD, KEY_PERIOD: 0xBE, KEY_SLASH: 0xBF, KEY_QUOTELEFT: 0xC0,
	KEY_BRACKETLEFT: 0xDB, KEY_BACKSLASH: 0xDC, KEY_BRACKETRIGHT: 0xDD,
	KEY_APOSTROPHE: 0xDE,
}

## 0 when the key has no VK equivalent.
static func to_vk(keycode: int) -> int:
	if keycode >= KEY_A and keycode <= KEY_Z:
		return keycode            # 'A'..'Z' match their VK codes
	if keycode >= KEY_0 and keycode <= KEY_9:
		return keycode            # '0'..'9' too
	if keycode >= KEY_F1 and keycode <= KEY_F12:
		return 0x70 + (keycode - KEY_F1)
	if keycode >= KEY_KP_0 and keycode <= KEY_KP_9:
		return 0x60 + (keycode - KEY_KP_0)
	return _SPECIAL.get(keycode, 0)

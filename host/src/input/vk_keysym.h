#pragma once

/// Windows virtual-key code (what the client sends in InputKeyboard.scancode)
/// to X11 keysym. Shared by the X11 (XTest) and Wayland (portal
/// NotifyKeyboardKeysym) injectors. Letters map to the lowercase keysym:
/// uppercase comes from the Shift that main.cpp presses around the key.

#include <cstdint>

namespace immersive {

/// Returns 0 for a VK with no keysym.
constexpr uint32_t vk_to_keysym(uint16_t vk) {
    if (vk >= 0x30 && vk <= 0x39) return vk;                 // '0'..'9'
    if (vk >= 0x41 && vk <= 0x5A) return vk + 0x20;          // 'a'..'z'
    if (vk >= 0x60 && vk <= 0x69) return 0xFFB0 + (vk - 0x60);  // KP_0..KP_9
    if (vk >= 0x70 && vk <= 0x87) return 0xFFBE + (vk - 0x70);  // F1..F24
    switch (vk) {
    case 0x08: return 0xFF08;  // BackSpace
    case 0x09: return 0xFF09;  // Tab
    case 0x0D: return 0xFF0D;  // Return
    case 0x10: return 0xFFE1;  // Shift_L
    case 0x11: return 0xFFE3;  // Control_L
    case 0x12: return 0xFFE9;  // Alt_L
    case 0x13: return 0xFF13;  // Pause
    case 0x14: return 0xFFE5;  // Caps_Lock
    case 0x1B: return 0xFF1B;  // Escape
    case 0x20: return 0x0020;  // space
    case 0x21: return 0xFF55;  // Prior (Page Up)
    case 0x22: return 0xFF56;  // Next (Page Down)
    case 0x23: return 0xFF57;  // End
    case 0x24: return 0xFF50;  // Home
    case 0x25: return 0xFF51;  // Left
    case 0x26: return 0xFF52;  // Up
    case 0x27: return 0xFF53;  // Right
    case 0x28: return 0xFF54;  // Down
    case 0x2C: return 0xFF61;  // Print
    case 0x2D: return 0xFF63;  // Insert
    case 0x2E: return 0xFFFF;  // Delete
    case 0x5B: return 0xFFEB;  // Super_L
    case 0x5C: return 0xFFEC;  // Super_R
    case 0x5D: return 0xFF67;  // Menu
    case 0x6A: return 0xFFAA;  // KP_Multiply
    case 0x6B: return 0xFFAB;  // KP_Add
    case 0x6C: return 0xFFAC;  // KP_Separator
    case 0x6D: return 0xFFAD;  // KP_Subtract
    case 0x6E: return 0xFFAE;  // KP_Decimal
    case 0x6F: return 0xFFAF;  // KP_Divide
    case 0x90: return 0xFF7F;  // Num_Lock
    case 0x91: return 0xFF14;  // Scroll_Lock
    case 0xA0: return 0xFFE1;  // Shift_L
    case 0xA1: return 0xFFE2;  // Shift_R
    case 0xA2: return 0xFFE3;  // Control_L
    case 0xA3: return 0xFFE4;  // Control_R
    case 0xA4: return 0xFFE9;  // Alt_L
    case 0xA5: return 0xFFEA;  // Alt_R
    case 0xAD: return 0x1008FF12;  // XF86AudioMute
    case 0xAE: return 0x1008FF11;  // XF86AudioLowerVolume
    case 0xAF: return 0x1008FF13;  // XF86AudioRaiseVolume
    case 0xB0: return 0x1008FF17;  // XF86AudioNext
    case 0xB1: return 0x1008FF16;  // XF86AudioPrev
    case 0xB2: return 0x1008FF15;  // XF86AudioStop
    case 0xB3: return 0x1008FF14;  // XF86AudioPlay
    case 0xBA: return ';';
    case 0xBB: return '=';
    case 0xBC: return ',';
    case 0xBD: return '-';
    case 0xBE: return '.';
    case 0xBF: return '/';
    case 0xC0: return '`';
    case 0xDB: return '[';
    case 0xDC: return '\\';
    case 0xDD: return ']';
    case 0xDE: return '\'';
    default:   return 0;
    }
}

static_assert(vk_to_keysym(0x41) == 'a' && vk_to_keysym(0x5A) == 'z');
static_assert(vk_to_keysym(0x70) == 0xFFBE && vk_to_keysym(0x7B) == 0xFFC9);  // F1, F12

}  // namespace immersive

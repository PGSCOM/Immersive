# Writes OUT: a C++ header with the settings panel page and its font as byte
# arrays (run at build time, see CMakeLists.txt). No NUL is appended.
function(embed var file)
  file(READ "${file}" hex HEX)
  string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," bytes "${hex}")
  string(REGEX REPLACE "(0x..,0x..,0x..,0x..,0x..,0x..,0x..,0x..,0x..,0x..,0x..,0x..,0x..,0x..,0x..,0x..,)" "\\1\n" bytes "${bytes}")
  file(APPEND "${OUT}.tmp" "inline constexpr unsigned char ${var}[] = {\n${bytes}\n};\n")
endfunction()
file(WRITE "${OUT}.tmp" "#pragma once\n// Generated from host/src/ui/panel.html and the Grotesk font. Do not edit.\n")
embed(kPanelHtml "${HTML}")
embed(kPanelFont "${FONT}")
file(RENAME "${OUT}.tmp" "${OUT}")

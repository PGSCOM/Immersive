cmake_minimum_required(VERSION 3.20)
# macOS: ScreenCaptureKit audio needs 13.0. Must be set before project().
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version")
project(Immersive2Host VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)

# Options
option(ENABLE_NVENC "Enable NVIDIA NVENC encoder" ON)
option(ENABLE_AMF  "Enable AMD AMF encoder" ON)
option(ENABLE_QSV  "Enable Intel QuickSync encoder" ON)

# Protocol headers (shared with client)
set(PROTOCOL_DIR "${CMAKE_SOURCE_DIR}/../protocol")

# Sources (platform capture/input/audio backends are added further down)
set(CAPTURE_SOURCES
    src/capture/stub_capture.cpp
)

set(ENCODER_SOURCES
    src/encoder/encoder.cpp
)

set(NETWORK_SOURCES
    src/network/server.cpp
    src/network/tls.cpp
    src/usb/adb_reverse.cpp
)

# mbedTLS (TLS on the control channel, the UDP media key: docs/SECURITY.md).
# The 3.6 LTS release, checked against its published SHA-256. To build
# offline, unpack it somewhere and pass -DFETCHCONTENT_SOURCE_DIR_MBEDTLS=<dir>.
include(FetchContent)
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON CACHE BOOL "" FORCE)
FetchContent_Declare(mbedtls
    URL https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.7/mbedtls-3.6.7.tar.bz2
    URL_HASH SHA256=a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(mbedtls)

set(DRIVER_SOURCES
    src/driver/idd_manager.cpp
)

set(MAIN_SOURCE
    src/main.cpp
)

# Tray icon + settings panel (src/ui). The page and its font are compiled in.
set(PANEL_ASSETS ${CMAKE_BINARY_DIR}/generated/panel_assets.h)
add_custom_command(
    OUTPUT ${PANEL_ASSETS}
    COMMAND ${CMAKE_COMMAND} -DOUT=${PANEL_ASSETS}
            -DHTML=${CMAKE_SOURCE_DIR}/src/ui/panel.html
            -DFONT=${CMAKE_SOURCE_DIR}/../client/project/fonts/Grotesk-04Gras.woff2
            -P ${CMAKE_SOURCE_DIR}/src/ui/embed.cmake
    DEPENDS src/ui/panel.html src/ui/embed.cmake
            ${CMAKE_SOURCE_DIR}/../client/project/fonts/Grotesk-04Gras.woff2
    COMMENT "Embedding the settings panel"
)
set(UI_SOURCES
    src/ui/panel.cpp
    src/ui/ui_common.cpp
    src/ui/ui_platform.cpp
    ${PANEL_ASSETS}
)

# Host executable
add_executable(immersive2_host
    ${MAIN_SOURCE}
    ${CAPTURE_SOURCES}
    ${ENCODER_SOURCES}
    ${NETWORK_SOURCES}
    ${DRIVER_SOURCES}
    ${UI_SOURCES}
)

target_include_directories(immersive2_host PRIVATE
    include
    src                 # private headers shared between backends
    ${CMAKE_BINARY_DIR}/generated
    ${PROTOCOL_DIR}
)

target_link_libraries(immersive2_host PRIVATE
    Threads::Threads
    mbedtls mbedx509 mbedcrypto
)

# Platform-specific backends
if(WIN32)
    target_sources(immersive2_host PRIVATE
        src/capture/dxgi_capture.cpp
        src/capture/wgc_capture.cpp
        src/input/input_injector.cpp
        src/audio/audio_capture.cpp
        src/encoder/mf_encoder.cpp
        src/ui/tray_win.cpp
    )
    target_link_libraries(immersive2_host PRIVATE
        shell32             # tray icon, opening the settings window
        user32
        gdi32
        advapi32            # start at login (HKCU Run key)
        d3d11
        dxgi
        ws2_32
        mf
        mfuuid
        mfplat
        strmiids
        ole32
        avrt
        setupapi
        windowsapp          # Windows.Graphics.Capture (WGC) WinRT API
    )
    target_compile_definitions(immersive2_host PRIVATE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
        UNICODE
        _UNICODE
        _CRT_SECURE_NO_WARNINGS   # Suppress fopen/sprintf deprecation (stb_image_write)
        _WIN32_WINNT=0x0A00       # Windows 10+ required for WGC (1803/build 17134)
        WINVER=0x0A00
    )
    # C++/WinRT uses standard C++20 coroutines by default.
    # The Windows SDK ships winrt/ headers under Include/<ver>/cppwinrt; MSVC
    # finds them automatically via SDK integration — no extra include_dirs needed.
endif()

if(APPLE)
    # ScreenCaptureKit (video + system audio) and CGEvent input.
    enable_language(OBJCXX)
    target_sources(immersive2_host PRIVATE
        src/capture/mac_capture.mm
        src/input/mac_input.mm
        src/audio/mac_audio_capture.mm
        src/encoder/vt_encoder.mm
        src/ui/tray_mac.mm
    )
    set_source_files_properties(
        src/ui/tray_mac.mm
        src/capture/mac_capture.mm
        src/input/mac_input.mm
        src/audio/mac_audio_capture.mm
        src/encoder/vt_encoder.mm
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    target_link_libraries(immersive2_host PRIVATE
        "-framework ScreenCaptureKit"
        "-framework CoreGraphics"
        "-framework CoreMedia"
        "-framework CoreVideo"
        "-framework CoreFoundation"
        "-framework Foundation"
        "-framework ApplicationServices"
        "-framework IOSurface"
        "-framework VideoToolbox"
        "-framework Cocoa"   # menu-bar item
    )
elseif(UNIX)
    # Linux / BSD. Each backend is optional so the host always builds; the
    # ones found decide what works at runtime (without any, only --stub).
    #   X11:     libx11-dev libxext-dev libxrandr-dev libxtst-dev libxfixes-dev
    #   Wayland: libdbus-1-dev libpipewire-0.3-dev (xdg-desktop-portal)
    #   Audio:   libpulse-dev (works on PipeWire through pipewire-pulse)
    #   Tray:    libdbus-1-dev (StatusNotifierItem icon; also used by Wayland)
    #   H.264/HEVC/AV1: libavcodec-dev libavutil-dev libswscale-dev (FFmpeg:
    #            NVENC, VAAPI, libx264). Without it Linux streams MJPEG only.
    find_package(PkgConfig)
    if(PKG_CONFIG_FOUND)
        pkg_check_modules(IM2_X11 IMPORTED_TARGET x11 xext xrandr xtst xfixes)
        pkg_check_modules(IM2_PORTAL IMPORTED_TARGET dbus-1 libpipewire-0.3)
        pkg_check_modules(IM2_PULSE IMPORTED_TARGET libpulse-simple)
        pkg_check_modules(IM2_FFMPEG IMPORTED_TARGET libavcodec libavutil libswscale)
        pkg_check_modules(IM2_DBUS IMPORTED_TARGET dbus-1)
    endif()

    target_sources(immersive2_host PRIVATE src/capture/linux_backends.cpp)
    if(IM2_X11_FOUND)
        target_sources(immersive2_host PRIVATE
            src/capture/x11_capture.cpp
            src/input/x11_input.cpp
        )
        target_link_libraries(immersive2_host PRIVATE PkgConfig::IM2_X11)
        target_compile_definitions(immersive2_host PRIVATE IMMERSIVE_HAVE_X11=1)
    endif()
    if(IM2_PORTAL_FOUND)
        target_sources(immersive2_host PRIVATE
            src/capture/portal_session.cpp
            src/capture/pipewire_capture.cpp
            src/capture/mutter_virtual.cpp
            src/input/portal_input.cpp
        )
        target_link_libraries(immersive2_host PRIVATE PkgConfig::IM2_PORTAL)
        target_compile_definitions(immersive2_host PRIVATE IMMERSIVE_HAVE_PORTAL=1)
    endif()
    if(IM2_PULSE_FOUND)
        target_sources(immersive2_host PRIVATE src/audio/pulse_audio_capture.cpp)
        target_link_libraries(immersive2_host PRIVATE PkgConfig::IM2_PULSE)
        target_compile_definitions(immersive2_host PRIVATE IMMERSIVE_HAVE_PULSE=1)
    endif()

    if(IM2_DBUS_FOUND)  # tray icon (StatusNotifierItem); without it the panel opens instead
        target_sources(immersive2_host PRIVATE src/ui/tray_linux.cpp)
        target_link_libraries(immersive2_host PRIVATE PkgConfig::IM2_DBUS)
        target_compile_definitions(immersive2_host PRIVATE IMMERSIVE_HAVE_DBUS=1)
    endif()

    if(IM2_FFMPEG_FOUND)
        target_sources(immersive2_host PRIVATE src/encoder/ffmpeg_encoder.cpp)
        target_link_libraries(immersive2_host PRIVATE PkgConfig::IM2_FFMPEG)
        target_compile_definitions(immersive2_host PRIVATE IMMERSIVE_HAVE_FFMPEG=1)
    endif()

    message(STATUS "Linux backends: X11=${IM2_X11_FOUND} "
                   "Wayland-portal=${IM2_PORTAL_FOUND} PulseAudio=${IM2_PULSE_FOUND} "
                   "FFmpeg=${IM2_FFMPEG_FOUND} Tray=${IM2_DBUS_FOUND}")
    if(NOT IM2_X11_FOUND AND NOT IM2_PORTAL_FOUND)
        message(WARNING "No X11 or Wayland capture libraries found: this host "
                        "can only run with --stub. See the comment above.")
    endif()
endif()

# Encoder flags
if(ENABLE_NVENC)
    target_compile_definitions(immersive2_host PRIVATE IMMERSIVE_NVENC=1)
endif()
if(ENABLE_AMF)
    target_compile_definitions(immersive2_host PRIVATE IMMERSIVE_AMF=1)
endif()
if(ENABLE_QSV)
    target_compile_definitions(immersive2_host PRIVATE IMMERSIVE_QSV=1)
endif()

# Suppress MSVC warnings from third-party headers (stb_image_write)
if(MSVC)
    target_compile_options(immersive2_host PRIVATE
        /wd4996   # 'function': was declared deprecated
        /wd4244   # conversion, possible loss of data (stb casts)
        /wd4267   # conversion from 'size_t' to 'int'
        /wd4100   # unreferenced formal parameter
    )
endif()

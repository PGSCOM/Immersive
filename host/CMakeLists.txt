cmake_minimum_required(VERSION 3.20)
project(Immersive2Host VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)

# Options
option(ENABLE_NVENC "Enable NVIDIA NVENC encoder" ON)
option(ENABLE_AMF  "Enable AMD AMF encoder" ON)
option(ENABLE_QSV  "Enable Intel QuickSync encoder" ON)

# Protocol headers (shared with client)
set(PROTOCOL_DIR "${CMAKE_SOURCE_DIR}/../protocol")

# Sources
set(CAPTURE_SOURCES
    src/capture/dxgi_capture.cpp
)

set(ENCODER_SOURCES
    src/encoder/encoder.cpp
    src/encoder/mf_encoder.cpp
)

set(NETWORK_SOURCES
    src/network/server.cpp
    src/network/tcp_control.cpp
    src/network/udp_stream.cpp
)

set(INPUT_SOURCES
    src/input/input_injector.cpp
)

set(DRIVER_SOURCES
    src/driver/idd_manager.cpp
)

set(AUDIO_SOURCES
    src/audio/audio_capture.cpp
)

set(MAIN_SOURCE
    src/main.cpp
)

# Host executable
add_executable(immersive2_host
    ${MAIN_SOURCE}
    ${CAPTURE_SOURCES}
    ${ENCODER_SOURCES}
    ${NETWORK_SOURCES}
    ${INPUT_SOURCES}
    ${DRIVER_SOURCES}
    ${AUDIO_SOURCES}
)

target_include_directories(immersive2_host PRIVATE
    include
    ${PROTOCOL_DIR}
)

target_link_libraries(immersive2_host PRIVATE
    Threads::Threads
)

# Platform-specific settings (Windows)
if(WIN32)
    target_link_libraries(immersive2_host PRIVATE
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
    )
    target_compile_definitions(immersive2_host PRIVATE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
        UNICODE
        _UNICODE
        _CRT_SECURE_NO_WARNINGS   # Suppress fopen/sprintf deprecation (stb_image_write)
        _WIN32_WINNT=0x0602       # Windows 8+ for MFTEnumEx, WASAPI loopback
        WINVER=0x0602
    )
endif()

if(NOT WIN32)
    target_compile_definitions(immersive2_host PRIVATE
        IMMERSIVE_PORTABLE_HOST=1
    )
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

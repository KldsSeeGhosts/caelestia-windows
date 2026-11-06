find_package(Qt6 REQUIRED COMPONENTS ShaderTools Core Qml Gui Quick QuickControls2 Concurrent Network)
if(NOT CAELESTIA_PORTABLE_UI)
    find_package(Qt6 REQUIRED COMPONENTS Sql DBus Multimedia)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(Qalculate IMPORTED_TARGET libqalculate REQUIRED)
    pkg_check_modules(Pipewire IMPORTED_TARGET libpipewire-0.3 REQUIRED)
    pkg_check_modules(Aubio IMPORTED_TARGET aubio REQUIRED)
    pkg_check_modules(Cava IMPORTED_TARGET libcava QUIET)
    if(NOT Cava_FOUND)
        pkg_check_modules(Cava IMPORTED_TARGET cava REQUIRED)
    endif()
    include(cmake/sensorslib.cmake)
endif()

# Preserve the upstream GLSL-only bundle on Linux; Windows Qt Quick needs HLSL.
set(CAELESTIA_SHADER_OPTIONS BATCHABLE NOMSL)
if(NOT WIN32)
    list(APPEND CAELESTIA_SHADER_OPTIONS OPTIMIZED NOHLSL)
endif()

set(QT_QML_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/qml")
qt_standard_project_setup(REQUIRES 6.9)

include(cmake/pch.cmake)
include(cmake/qml-module.cmake)

# Header only helpers
add_library(caelestia-util INTERFACE)
target_include_directories(caelestia-util INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")

if(NOT CAELESTIA_PORTABLE_UI)
    add_subdirectory(3rdparty/rgbcx)
endif()
add_subdirectory(src/Caelestia)

qml_module(caelestia-windows
    URI Caelestia.Windows
    SOURCES
        windowsfocusguard.hpp
        windowsfocusguard.cpp
        windowsfontfallback.hpp
        windowsfontfallback.cpp
        windowsfiles.hpp
        windowsprocess.hpp
        knownfolders.hpp
        Clipboard/clipboardcache.hpp
        Clipboard/clipboardlogic.hpp
        Clipboard/clipboardstate.hpp
        Clipboard/windowsclipboard.hpp
        Clipboard/windowsclipboard.cpp
        Clipboard/windowsclipboardworker.hpp
        Clipboard/windowsclipboardworker.cpp
        DisplayPower/displaypower.hpp
        DisplayPower/displaypower.cpp
        Focus/focusfollowsmouse.hpp
        Focus/focusfollowsmouse.cpp
        Focus/windowsfocusfollowsmouse.hpp
        Focus/windowsfocusfollowsmouse.cpp
    LIBRARIES
        Qt::Gui
        Qt::Quick
        user32
        ole32
        shell32
        windowsapp
)

# Windows.ApplicationModel.DataTransfer.Clipboard history needs C++/WinRT and
# the WindowsApp umbrella library. The worker keeps every WinRT call off the
# GUI thread.
target_compile_definitions(caelestia-windows PRIVATE
    NOMINMAX
    WIN32_LEAN_AND_MEAN
)

# The generated QML type registration includes <windowsclipboard.hpp>, so the
# clipboard sources must be reachable from the module's include path.
target_include_directories(caelestia-windows PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/Clipboard"
    "${CMAKE_CURRENT_SOURCE_DIR}/DisplayPower"
    "${CMAKE_CURRENT_SOURCE_DIR}/Focus"
)

# Keep obsolete private-harness requests explicit, not silently skipped.
option(CAELESTIA_WINDOWS_TESTS "Build Caelestia Windows plugin tests" OFF)
if(CAELESTIA_WINDOWS_TESTS)
    message(FATAL_ERROR "Private test sources are not shipped. Configure with CAELESTIA_WINDOWS_TESTS=OFF.")
endif()

# WASAPI loopback analysis: CavaProvider/BeatTracker/ServiceRef for the
# original visualiser and media components.
add_subdirectory(Audio)

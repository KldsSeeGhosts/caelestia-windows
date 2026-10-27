qml_module(caelestia-windows
    URI Caelestia.Windows
    SOURCES
        windowsfocusguard.hpp
        windowsfocusguard.cpp
        windowsfontfallback.hpp
        windowsfontfallback.cpp
        Clipboard/clipboardlogic.hpp
        Clipboard/windowsclipboard.hpp
        Clipboard/windowsclipboard.cpp
        Clipboard/windowsclipboardworker.hpp
        Clipboard/windowsclipboardworker.cpp
    LIBRARIES
        Qt::Gui
        Qt::Quick
        user32
        ole32
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
)

# The clipboard's WinRT-free decisions are checked by a small Qt Test
# executable. windows/scripts/Test-ClipboardHistory.ps1 runs it alongside the
# QML smoke.
find_package(Qt6 QUIET COMPONENTS Test)
if(Qt6Test_FOUND)
    add_executable(clipboard-logic-tests
        Clipboard/test/clipboardlogic_test.cpp
    )
    target_include_directories(clipboard-logic-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/Clipboard"
    )
    target_link_libraries(clipboard-logic-tests PRIVATE Qt::Core Qt::Test)
endif()

# WASAPI loopback analysis: CavaProvider/BeatTracker/ServiceRef for the
# original visualiser and media components.
add_subdirectory(Audio)

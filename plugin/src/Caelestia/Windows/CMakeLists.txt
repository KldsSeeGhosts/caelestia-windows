qml_module(caelestia-windows
    URI Caelestia.Windows
    SOURCES
        windowsfocusguard.hpp
        windowsfocusguard.cpp
        windowsfontfallback.hpp
        windowsfontfallback.cpp
        windowsfiles.hpp
        windowsprocess.hpp
        capturehost.hpp
        capturehost.cpp
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

if(CAELESTIA_WINDOWS_TESTS)
    include(test/capturehost-fixtures.cmake)
    add_executable(clipboard-logic-tests Clipboard/test/clipboardlogic_test.cpp)
    target_include_directories(clipboard-logic-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/Clipboard")
    target_link_libraries(clipboard-logic-tests PRIVATE Qt::Core Qt::Test)

    add_executable(clipboard-qml-tests Clipboard/test/clipboardqml_test.cpp)
    target_compile_definitions(clipboard-qml-tests PRIVATE
        CLIPBOARD_SERVICE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../../../windows/services/clipboard")
    target_link_libraries(clipboard-qml-tests PRIVATE Qt::Core Qt::Qml Qt::Test)

    add_executable(displaypower-tests DisplayPower/test/displaypower_test.cpp DisplayPower/displaypower.cpp)
    target_include_directories(displaypower-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/DisplayPower")
    target_compile_definitions(displaypower-tests PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
    target_link_libraries(displaypower-tests PRIVATE Qt::Core Qt::Qml Qt::Test user32)

    add_executable(focus-follows-mouse-tests Focus/test/focusfollowsmouse_test.cpp Focus/focusfollowsmouse.cpp)
    target_include_directories(focus-follows-mouse-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/Focus")
    target_link_libraries(focus-follows-mouse-tests PRIVATE Qt::Core Qt::Test)

    add_executable(knownfolders-tests test/knownfolders_test.cpp knownfolders.hpp)
    target_include_directories(knownfolders-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(knownfolders-tests PRIVATE Qt::Core Qt::Qml Qt::Test shell32 ole32)

    add_executable(windowsfocusguard-tests test/windowsfocusguard_test.cpp windowsfocusguard.hpp)
    target_include_directories(windowsfocusguard-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_compile_definitions(windowsfocusguard-tests PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
    target_link_libraries(windowsfocusguard-tests PRIVATE Qt::Core Qt::Gui Qt::Quick Qt::Qml Qt::Test user32)

    add_executable(wasapi-format-tests Audio/test/wasapiformat_test.cpp Audio/wasapiformat.cpp Audio/wasapiformat.hpp)
    target_include_directories(wasapi-format-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/Audio")
    target_compile_definitions(wasapi-format-tests PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
    target_link_libraries(wasapi-format-tests PRIVATE Qt::Core Qt::Test)

    # The thumbnail's drag: what it offers and the picture under the pointer.
    # The source file is shared with the plugin (caelestia-core).
    add_executable(imagedrag-tests test/imagedrag_test.cpp ../imagedrag.cpp ../imagedrag.hpp)
    target_include_directories(imagedrag-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
    target_compile_definitions(imagedrag-tests PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
    target_link_libraries(imagedrag-tests PRIVATE Qt::Core Qt::Gui Qt::Test user32)

    foreach(fixture clipboard-logic clipboard-qml displaypower focus-follows-mouse knownfolders windowsfocusguard wasapi-format imagedrag)
        add_test(NAME ${fixture} COMMAND ${fixture}-tests)
        set_tests_properties(${fixture} PROPERTIES TIMEOUT 60 ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    endforeach()

    # The Windows data object that the drag hands a target, read back through
    # OLE: CF_HDROP, PNG, CF_DIB and the rest. It needs Qt's real windows platform
    # plugin and replaces the clipboard content, so it is off by default and never
    # registered with CTest. No CI gate runs it. After building with it on, run
    # lib\imagedrag-desktop-tests.exe from the build directory (the Qt bin
    # directory on PATH, QT_QPA_PLATFORM unset).
    option(CAELESTIA_WINDOWS_DESKTOP_TESTS "Build the interactive desktop drag test" OFF)
    if(CAELESTIA_WINDOWS_DESKTOP_TESTS)
        add_executable(imagedrag-desktop-tests test/imagedrag_desktop_test.cpp ../imagedrag.cpp ../imagedrag.hpp)
        target_include_directories(imagedrag-desktop-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
        target_compile_definitions(imagedrag-desktop-tests PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
        target_link_libraries(imagedrag-desktop-tests PRIVATE Qt::Core Qt::Gui Qt::Test user32 ole32 shell32)
    endif()
endif()

# WASAPI loopback analysis: CavaProvider/BeatTracker/ServiceRef for the
# original visualiser and media components.
add_subdirectory(Audio)

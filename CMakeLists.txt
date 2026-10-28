cmake_minimum_required(VERSION 3.19)

if(NOT DEFINED VERSION)
    execute_process(COMMAND git describe --tags --abbrev=0
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        OUTPUT_VARIABLE VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE GIT_DESCRIBE_RESULT
        ERROR_QUIET
    )

    # Windows: clones without a reachable tag (only archive/* tags exist here) must
    # still configure; fall back instead of failing (#114).
    if(NOT GIT_DESCRIBE_RESULT EQUAL 0 OR "${VERSION}" STREQUAL "")
        set(VERSION "0.0.0")
    endif()
endif()

if(NOT DEFINED GIT_REVISION)
    execute_process(COMMAND git rev-parse HEAD
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        OUTPUT_VARIABLE GIT_REVISION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )

    # Windows: fall back when the source tree is not a git checkout (#114).
    if("${GIT_REVISION}" STREQUAL "")
        set(GIT_REVISION "unknown")
    endif()
endif()

string(REGEX REPLACE "^v" "" VERSION "${VERSION}")

project(caelestia-shell VERSION ${VERSION} LANGUAGES CXX)

include(GNUInstallDirs)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")

set(DISTRIBUTOR "Unset" CACHE STRING "Distributor")
if(WIN32)
    set(CAELESTIA_DEFAULT_MODULES "plugin")
    set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON)
else()
    set(CAELESTIA_DEFAULT_MODULES "extras;plugin;shell")
endif()
set(ENABLE_MODULES "${CAELESTIA_DEFAULT_MODULES}" CACHE STRING "Modules to build/install")
option(CAELESTIA_PORTABLE_UI "Build UI plugins without Linux platform services or the calculator" ${WIN32})
if(WIN32 AND NOT CAELESTIA_PORTABLE_UI)
    message(FATAL_ERROR "Windows currently supports only CAELESTIA_PORTABLE_UI. Platform services are not ported.")
endif()
if(WIN32 AND "shell" IN_LIST ENABLE_MODULES)
    message(FATAL_ERROR "The upstream shell entry point is not Windows-ready. Use windows/scripts/Start-Prototype.ps1.")
endif()
set(INSTALL_LIBDIR "${CMAKE_INSTALL_LIBDIR}/caelestia" CACHE STRING "Library install dir")
set(INSTALL_QMLDIR "${CMAKE_INSTALL_LIBDIR}/qt6/qml" CACHE STRING "QML install dir")
set(INSTALL_QSCONFDIR "${CMAKE_INSTALL_SYSCONFDIR}/xdg/quickshell/caelestia" CACHE STRING "Quickshell config install dir")

add_compile_definitions(
    QT_NO_CAST_FROM_ASCII
    QT_NO_CAST_TO_ASCII
    QT_NO_CAST_FROM_BYTEARRAY
)

if(MSVC)
    add_compile_options(/W4 /bigobj /utf-8)
else()
    add_compile_options(
        -Wall -Wextra -Wpedantic -Wshadow -Wconversion
        -Wold-style-cast -Wnull-dereference -Wdouble-promotion
        -Wformat=2 -Wfloat-equal -Woverloaded-virtual
        -Wsign-conversion -Wredundant-decls -Wswitch
        -Wunreachable-code
    )
endif()

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    add_compile_options(-Wunused-lambda-capture -Wno-nonportable-include-path)
endif()

if("extras" IN_LIST ENABLE_MODULES)
    add_subdirectory(extras)
endif()

if("plugin" IN_LIST ENABLE_MODULES)
    add_subdirectory(plugin)
endif()

if("shell" IN_LIST ENABLE_MODULES)
    foreach(dir assets components daemons modules services utils)
        install(DIRECTORY ${dir} DESTINATION "${INSTALL_QSCONFDIR}")
    endforeach()

    install(PROGRAMS assets/wrap_term_launch.sh DESTINATION "${INSTALL_QSCONFDIR}/assets")

    file(READ shell.qml SHELL_QML)
    string(REPLACE "settings.watchFiles: true" "settings.watchFiles: false" SHELL_QML "${SHELL_QML}")
    file(WRITE "${CMAKE_BINARY_DIR}/qml/shell.qml" "${SHELL_QML}")
    install(FILES "${CMAKE_BINARY_DIR}/qml/shell.qml" DESTINATION "${INSTALL_QSCONFDIR}")

    install(FILES LICENSE DESTINATION "${INSTALL_QSCONFDIR}")
endif()

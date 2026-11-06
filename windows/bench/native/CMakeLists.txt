cmake_minimum_required(VERSION 3.20)
project(caelestia_cost_probe LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
find_package(Qt6 6.11 REQUIRED COMPONENTS Core Gui Qml)
set(CMAKE_AUTOMOC ON)
if(NOT BACKEND_ROOT)
    message(FATAL_ERROR "BACKEND_ROOT must be the measured revision's backend checkout")
endif()
set(src "${BACKEND_ROOT}/src/windows")
add_executable(native-bench
    main.cpp "${src}/tiling_layout.cpp"
    "${src}/foreground_observer.cpp" "${src}/foreground_observer.hpp"
    "${src}/window_tracker.hpp")
target_compile_definitions(native-bench PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(native-bench PRIVATE "${src}")
target_link_libraries(native-bench PRIVATE Qt6::Core Qt6::Gui Qt6::Qml user32)

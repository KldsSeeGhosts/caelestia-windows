# Focused standalone build, using the exact production registry/facade source.
cmake_minimum_required(VERSION 3.24)
project(capture-host-fixtures LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick Test)
enable_testing()
include(capturehost-fixtures.cmake)

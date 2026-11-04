cmake_minimum_required(VERSION 3.24)
project(apps_reload_test LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
find_package(Qt6 6.11 REQUIRED COMPONENTS Quick Qml Test)
qt_standard_project_setup(REQUIRES 6.11)

qt_add_executable(apps_reload_test apps_reload_test.cpp)
target_link_libraries(apps_reload_test PRIVATE Qt6::Quick Qt6::Qml Qt6::Test)
target_compile_definitions(apps_reload_test PRIVATE
    APPS_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../services/apps")

# Match the backend fixtures: replace Qt's merged manifest with plain asInvoker.
find_program(SDK_MT mt.exe HINTS "$ENV{WindowsSdkVerBinPath}x64" REQUIRED)
add_custom_command(TARGET apps_reload_test POST_BUILD
    COMMAND "${SDK_MT}" -nologo
        -manifest "${CMAKE_CURRENT_SOURCE_DIR}/../../deps/quickshell/src/windows/test/test-as-invoker.manifest"
        "-outputresource:$<TARGET_FILE:apps_reload_test>;#1"
    VERBATIM)

enable_testing()
add_test(NAME apps_reload COMMAND apps_reload_test)
set_tests_properties(apps_reload PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

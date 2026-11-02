qml_module(caelestia-settings
    URI Caelestia.Settings
    INCLUDE_PREFIX settings
    SOURCES
        common.cpp
        schema.cpp
        codecs.cpp
        quarantine.cpp
        node.cpp
        objectnode.cpp
        listnode.cpp
        rootnode.cpp
        settingsfile.cpp
        changebatcher.cpp
        redact.cpp
    LIBRARIES
        caelestia-util
)
target_link_libraries(caelestia-settings PUBLIC caelestia-util)

# Legacy per-monitor settings compatibility when two identical monitors gain a
# collision suffix. Uses a temporary directory, never the real profile.
find_package(Qt6 QUIET COMPONENTS Test)
if(Qt6Test_FOUND)
    add_executable(layer-registry-tests test/layerregistry_test.cpp)
    target_include_directories(layer-registry-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}"
    )
    target_link_libraries(layer-registry-tests PRIVATE caelestia-settings Qt::Qml Qt::Test)

    add_executable(plugin-log-redaction-guard test/log_redaction_guard_test.cpp)
    target_compile_definitions(plugin-log-redaction-guard PRIVATE
        CAELESTIA_PLUGIN_SRC="${CMAKE_CURRENT_SOURCE_DIR}/.."
    )
    target_link_libraries(plugin-log-redaction-guard PRIVATE Qt::Core Qt::Test)
endif()

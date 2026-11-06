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

if(CAELESTIA_WINDOWS_TESTS)
    add_executable(layer-registry-tests test/layerregistry_test.cpp)
    target_include_directories(layer-registry-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(layer-registry-tests PRIVATE caelestia-settings Qt::Qml Qt::Test)
    add_test(NAME layer-registry COMMAND layer-registry-tests)

    add_executable(plugin-log-redaction-guard test/log_redaction_guard_test.cpp)
    target_compile_definitions(plugin-log-redaction-guard PRIVATE
        CAELESTIA_PLUGIN_SRC="${CMAKE_CURRENT_SOURCE_DIR}/..")
    target_link_libraries(plugin-log-redaction-guard PRIVATE Qt::Core Qt::Test)
    add_test(NAME plugin-log-redaction COMMAND plugin-log-redaction-guard)
endif()

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

set(caelestia_core_sources cutils.cpp requests.cpp toaster.cpp circularbuffer.cpp)
set(caelestia_core_libraries Qt::Gui Qt::Quick Qt::Concurrent Qt::Network)
if(NOT CAELESTIA_PORTABLE_UI)
    list(APPEND caelestia_core_sources qalculator.cpp)
    list(APPEND caelestia_core_libraries PkgConfig::Qalculate)
endif()

qml_module(caelestia-core
    URI Caelestia
    INCLUDE_PREFIX core
    SOURCES
        ${caelestia_core_sources}
    LIBRARIES
        ${caelestia_core_libraries}
)
target_link_libraries(caelestia-core PUBLIC caelestia-util)

# Bake the shell version in so CUtils can expose it without spawning a process
target_compile_definitions(caelestia-core PRIVATE CAELESTIA_VERSION="${VERSION}")

# Node macros expand to Q_OBJECT, automoc can't see it otherwise
list(APPEND CMAKE_AUTOMOC_MACRO_NAMES
    SETTINGS_NODE SETTINGS_NODE_NO_CTOR SETTINGS_LIST_TYPE SETTINGS_SINGLETON_DECL
    CONFIG_NODE CONFIG_NODE_NO_CTOR CONFIG_LIST_TYPE
    STATE_NODE_NO_CTOR
)

add_subdirectory(Settings)
add_subdirectory(Components)
add_subdirectory(Config)
add_subdirectory(State)
if(NOT CAELESTIA_PORTABLE_UI)
    add_subdirectory(Models)
    add_subdirectory(Services)
endif()
add_subdirectory(Blobs)
if(NOT CAELESTIA_PORTABLE_UI)
    add_subdirectory(Images)
endif()
add_subdirectory(I18n)
if(NOT CAELESTIA_PORTABLE_UI)
    add_subdirectory(Multimedia)
endif()
add_subdirectory(Shaders)

# Windows: retain the portable filesystem model, without Linux appdb/Multimedia.
set(model_sources filesystemmodel.cpp)
set(model_libraries Qt::Gui Qt::Concurrent)
if(NOT CAELESTIA_PORTABLE_UI)
    list(APPEND model_sources appdb.cpp)
    list(APPEND model_libraries Qt::Multimedia Qt::Sql)
endif()
qml_module(caelestia-models
    URI Caelestia.Models
    SOURCES
        ${model_sources}
    LIBRARIES
        ${model_libraries}
)
if(CAELESTIA_PORTABLE_UI)
    target_compile_definitions(caelestia-models PRIVATE CAELESTIA_PORTABLE_UI)
endif()

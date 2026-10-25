qml_module(caelestia-components
    URI Caelestia.Components
    SOURCES
        animatedrepeater.cpp
        lazylistview.cpp
        wavyline.cpp
        buttonrow.cpp
        circularindicatormanager.cpp
        linearindicatormanager.cpp
        sparklineitem.cpp
        visualiserbars.cpp
        roundedmask.cpp
    LIBRARIES
        Qt::Gui
        Qt::Quick
        caelestia-core
    DEPENDENCIES
        Caelestia
)

qt_add_shaders(caelestia-components "components_shaders"
    ${CAELESTIA_SHADER_OPTIONS}
    GLSL "300es,330"
    PREFIX "/"
    FILES
        shaders/roundedmask.frag
        shaders/roundedmask.vert
)

qml_module(caelestia-windows
    URI Caelestia.Windows
    SOURCES
        windowsfocusguard.hpp
        windowsfocusguard.cpp
    LIBRARIES
        Qt::Gui
        Qt::Quick
        user32
)

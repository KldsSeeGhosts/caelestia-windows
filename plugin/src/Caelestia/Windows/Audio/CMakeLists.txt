# Windows audio analysis. libcava, aubio and PipeWire are Linux-only in this
# toolchain, so the upstream AudioCollector/AudioProvider/CavaProvider/
# BeatTracker sources are compiled here against the Windows WASAPI loopback
# capture and the in-module FFT/onset implementations instead. The QML types
# (ServiceRef, CavaProvider, BeatTracker) keep the upstream names and contract.
qml_module(caelestia-windows-audio
    URI Caelestia.Windows.Audio
    SOURCES
        cavaplan.hpp
        cavaplan.cpp
        onsetdetector.hpp
        onsetdetector.cpp
        serviceref.hpp
        serviceref.cpp
        wasapiloopback.hpp
        wasapiloopback.cpp
        ../../Services/service.hpp
        ../../Services/service.cpp
        ../../Services/audioprovider.hpp
        ../../Services/audioprovider.cpp
        ../../Services/audiocollector.hpp
        ../../Services/audiocollector.cpp
        ../../Services/cavaprovider.hpp
        ../../Services/cavaprovider.cpp
        ../../Services/beattracker.hpp
        ../../Services/beattracker.cpp
    LIBRARIES
        Qt::Gui
        Qt::Quick
        caelestia-util
        ole32
        mmdevapi
    DEPENDENCIES
        Caelestia
)

target_compile_definitions(caelestia-windows-audio PRIVATE
    CAELESTIA_WINDOWS_AUDIO=1
    NOMINMAX
    WIN32_LEAN_AND_MEAN
)

# The upstream audio services live in ../Services; cavaplan/onsetdetector live
# in this directory. Both are compiled into this module.
target_include_directories(caelestia-windows-audio PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Services"
)

qml_module(caelestia-blobs
    URI Caelestia.Blobs
    SOURCES
        blobgroup.cpp
        blobshape.cpp
        blobrect.cpp
        blobinvertedrect.cpp
        blobmaterial.cpp
    LIBRARIES
        Qt::Quick
)

qt_add_shaders(caelestia-blobs "blob_shaders"
    ${CAELESTIA_SHADER_OPTIONS}
    GLSL "300es,330"
    PREFIX "/"
    FILES
        shaders/blob.frag
        shaders/blob.vert
)

if(CAELESTIA_WINDOWS_TESTS)
    add_executable(blobs-animation-tests test/blobsanimation_test.cpp)
    target_include_directories(blobs-animation-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(blobs-animation-tests PRIVATE caelestia-blobs Qt::Quick Qt::Test)
    add_test(NAME blobs-animation COMMAND blobs-animation-tests)
    set_tests_properties(blobs-animation PROPERTIES TIMEOUT 60 ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
endif()

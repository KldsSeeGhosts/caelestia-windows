add_executable(capture-host-tests
    "${CMAKE_CURRENT_LIST_DIR}/capturehost_test.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../capturehost.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../capturehost.hpp")
target_compile_definitions(capture-host-tests PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN QT_NO_CAST_FROM_ASCII QT_NO_CAST_TO_ASCII QT_NO_CAST_FROM_BYTEARRAY
    CAPTURE_SERVICE_DIR="${CMAKE_CURRENT_LIST_DIR}/../../../../../windows/shell/adapters/services")
target_link_libraries(capture-host-tests PRIVATE Qt::Core Qt::Gui Qt::Quick Qt::Qml Qt::Test user32)
add_executable(capture-host-child WIN32 "${CMAKE_CURRENT_LIST_DIR}/capturehost_child.cpp")
target_compile_definitions(capture-host-child PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(capture-host-child PRIVATE Qt::Core user32 shell32)
add_dependencies(capture-host-tests capture-host-child)
add_test(NAME capture-host COMMAND capture-host-tests)
set_tests_properties(capture-host PROPERTIES TIMEOUT 90 ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

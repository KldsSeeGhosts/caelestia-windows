# Shared by normal configure and the SDK-free version-reader regression.
find_package(Python3 REQUIRED COMPONENTS Interpreter)
execute_process(
    COMMAND "${Python3_EXECUTABLE}" -I -B "${CMAKE_CURRENT_LIST_DIR}/../windows/ci/history_version.py"
    RESULT_VARIABLE CAELESTIA_VERSION_RESULT
    OUTPUT_VARIABLE CAELESTIA_VERSION
    OUTPUT_STRIP_TRAILING_WHITESPACE)
if(NOT CAELESTIA_VERSION_RESULT EQUAL 0)
    message(FATAL_ERROR "Cannot compute version from complete first-parent history")
endif()
if(DEFINED VERSION AND NOT VERSION STREQUAL CAELESTIA_VERSION)
    message(FATAL_ERROR "VERSION must match the history-derived version")
endif()
set(VERSION "${CAELESTIA_VERSION}")

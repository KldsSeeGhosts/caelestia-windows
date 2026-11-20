cmake_minimum_required(VERSION 3.24)
project(blob_motion_probe LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Quick)
set(BLOB_SRC "${CMAKE_CURRENT_LIST_DIR}/../../../plugin/src/Caelestia/Blobs" CACHE PATH
    "Blob sources to measure, including an archived baseline")
add_executable(blob_motion_probe main.cpp
    "${BLOB_SRC}/blobgroup.cpp" "${BLOB_SRC}/blobrect.cpp" "${BLOB_SRC}/blobshape.cpp"
    "${BLOB_SRC}/blobmaterial.cpp" "${BLOB_SRC}/blobinvertedrect.cpp")
target_include_directories(blob_motion_probe PRIVATE "${BLOB_SRC}")
target_link_libraries(blob_motion_probe PRIVATE Qt6::Quick)

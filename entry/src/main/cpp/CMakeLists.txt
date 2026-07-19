cmake_minimum_required(VERSION 3.5.0)
project(libspawn)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(spawn SHARED spawn.cpp)

target_link_libraries(spawn PUBLIC libace_napi.z.so)

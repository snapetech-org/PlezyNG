cmake_minimum_required(VERSION 3.15)
project(runner LANGUAGES CXX)

include(${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/webos_build.cmake)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../packages/plezy_torrent/src" "${CMAKE_CURRENT_BINARY_DIR}/torrent")
install(TARGETS plezy_torrent LIBRARY DESTINATION lib)

# webOS does not provide player-owned PCM, but it can run local WAV analysis
# with the same CPU Whisper FFI bridge as the other native Linux targets.
# build_ipk.sh prepares this checksum-verified source tree before CMake runs.
set(PLEZY_WHISPER_SOURCE_DIR "$ENV{PLEZY_WHISPER_SOURCE_DIR}")
if(NOT IS_DIRECTORY "${PLEZY_WHISPER_SOURCE_DIR}/src" OR
   NOT EXISTS "${PLEZY_WHISPER_SOURCE_DIR}/whisper/v1.9.2/include/whisper.h")
  message(FATAL_ERROR "The checksum-verified Whisper source was not prepared by tools/webos/build_ipk.sh")
endif()

set(FLUTTER_WHISPER_CPP_DIR "${PLEZY_WHISPER_SOURCE_DIR}/whisper/v1.9.2" CACHE PATH "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_RPC OFF CACHE BOOL "" FORCE)
set(GGML_SYCL OFF CACHE BOOL "" FORCE)
set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
set(GGML_CUDA OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_ACCELERATE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
add_subdirectory("${PLEZY_WHISPER_SOURCE_DIR}/src" "${CMAKE_CURRENT_BINARY_DIR}/flutter-whisper")
install(TARGETS flutter_whisper_plugin LIBRARY DESTINATION lib)

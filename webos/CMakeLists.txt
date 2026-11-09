cmake_minimum_required(VERSION 3.15)
project(runner LANGUAGES CXX)

include(${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/webos_build.cmake)
target_link_libraries(${BINARY_NAME} PRIVATE flutter)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../packages/plezy_torrent/src" "${CMAKE_CURRENT_BINARY_DIR}/torrent")
install(TARGETS plezy_torrent LIBRARY DESTINATION lib)

# Older TV kernels use a descriptor-only, default-deny worker.
set(PLEZY_ROMM_DESCRIPTOR_SANDBOX ON CACHE BOOL "Isolate webOS bundled cores" FORCE)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../native/games/romm" "${CMAKE_CURRENT_BINARY_DIR}/romm_native")
install(TARGETS plezy_retro LIBRARY DESTINATION lib)
install(TARGETS plezy_retro_worker RUNTIME DESTINATION lib)
if(PLEZY_ROMM_BUILD_CORES)
  install(TARGETS gambatte_libretro mgba_libretro fceumm_libretro LIBRARY DESTINATION lib)
  install(DIRECTORY "${ROMM_NOTICES_DIR}/" DESTINATION lib/romm-notices)
endif()

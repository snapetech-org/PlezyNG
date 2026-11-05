cmake_minimum_required(VERSION 3.22)
project(plezy_retro LANGUAGES C CXX)
include(FetchContent)
# Immutable inputs, fetched only by an authorized build, never at runtime.
FetchContent_Declare(romm_libretro_common GIT_REPOSITORY https://github.com/libretro/libretro-common.git GIT_TAG d9597c359a5ca8399a4e244f816e7e975a92a2aa SOURCE_SUBDIR _plezy_headers_only)
FetchContent_Declare(romm_miniaudio GIT_REPOSITORY https://github.com/mackron/miniaudio.git GIT_TAG 2da2b23eb2fc2966e76196b7dce98766e219c257 SOURCE_SUBDIR _plezy_headers_only)
FetchContent_MakeAvailable(romm_libretro_common romm_miniaudio)
add_library(plezy_retro SHARED retro_host.cpp)
target_compile_features(plezy_retro PRIVATE cxx_std_17)
target_include_directories(plezy_retro PRIVATE "${romm_libretro_common_SOURCE_DIR}/include" "${romm_miniaudio_SOURCE_DIR}")
set_target_properties(plezy_retro PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN YES)
if(WIN32)
  target_link_libraries(plezy_retro PRIVATE winmm ole32)
elseif(APPLE)
  target_link_libraries(plezy_retro PRIVATE "-framework CoreAudio" "-framework AudioToolbox" "-framework CoreFoundation")
elseif(ANDROID)
  target_link_libraries(plezy_retro PRIVATE log android dl m)
  target_link_options(plezy_retro PRIVATE "-Wl,-z,max-page-size=16384")
else()
  find_package(Threads REQUIRED)
  target_link_libraries(plezy_retro PRIVATE Threads::Threads ${CMAKE_DL_LIBS} m)
endif()
# Normal builds include the pinned software cores, corresponding source and
# notices. Capability probing still admits only libraries that actually load.
option(PLEZY_ROMM_BUILD_CORES "Build the bundled software emulator cores" ON)
if(PLEZY_ROMM_BUILD_CORES)
  add_subdirectory(cores)
endif()

# Call from the top-level app AFTER its clean-bundle install step. Registering
# this in linux/runner would install the host before that step deletes it.
function(plezy_install_romm)
  install(TARGETS plezy_retro
    RUNTIME DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime
    LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
  if(PLEZY_ROMM_BUILD_CORES)
    install(TARGETS gambatte_libretro mgba_libretro fceumm_libretro
      RUNTIME DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime
      LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
    install(DIRECTORY "${ROMM_NOTICES_DIR}/"
      DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/romm-notices" COMPONENT Runtime)
  endif()
endfunction()
if(APPLE)
  set_target_properties(plezy_retro PROPERTIES
    FRAMEWORK TRUE FRAMEWORK_VERSION A OUTPUT_NAME PlezyRetro
    MACOSX_FRAMEWORK_IDENTIFIER org.plezy.romm.retro
    MACOSX_FRAMEWORK_BUNDLE_VERSION 1.0.0
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING 1.0.0
    INSTALL_NAME_DIR "@rpath")
endif()

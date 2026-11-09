cmake_minimum_required(VERSION 3.22)
project(plezy_retro LANGUAGES C CXX)
if(APPLE)
  # miniaudio's Apple audio-session implementation imports Objective-C APIs.
  # Keep the portable host source, but compile it as Objective-C++ on Apple.
  enable_language(OBJCXX)
  set_source_files_properties(retro_host.cpp retro_proxy.cpp PROPERTIES LANGUAGE OBJCXX)
endif()
include(FetchContent)
# Immutable inputs, fetched only by an authorized build, never at runtime.
FetchContent_Declare(romm_libretro_common GIT_REPOSITORY https://github.com/libretro/libretro-common.git GIT_TAG d9597c359a5ca8399a4e244f816e7e975a92a2aa SOURCE_SUBDIR _plezy_headers_only)
FetchContent_Declare(romm_miniaudio GIT_REPOSITORY https://github.com/mackron/miniaudio.git GIT_TAG 2da2b23eb2fc2966e76196b7dce98766e219c257 SOURCE_SUBDIR _plezy_headers_only)
FetchContent_MakeAvailable(romm_libretro_common romm_miniaudio)
# Apple mobile and TV runtimes cannot spawn this desktop helper. Keep their
# explicit in-process backend; never silently fall back on a desktop failure.
set(romm_isolated_default OFF)
if(WIN32 OR (APPLE AND CMAKE_SYSTEM_NAME STREQUAL "Darwin") OR
   (CMAKE_SYSTEM_NAME STREQUAL "Linux" AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64|aarch64|arm64)$"))
  set(romm_isolated_default ON)
endif()
option(PLEZY_ROMM_ISOLATED "Use the sandboxed desktop emulator worker" ${romm_isolated_default})
if(PLEZY_ROMM_ISOLATED)
  add_library(plezy_retro SHARED retro_proxy.cpp)
  add_executable(plezy_retro_worker retro_worker.cpp retro_host.cpp)
  target_compile_features(plezy_retro_worker PRIVATE cxx_std_17)
  target_compile_definitions(plezy_retro_worker PRIVATE PLEZY_RETRO_REMOTE_AUDIO)
  target_include_directories(plezy_retro_worker PRIVATE "${romm_libretro_common_SOURCE_DIR}/include")
  add_dependencies(plezy_retro plezy_retro_worker)
  if(WIN32)
    target_compile_definitions(plezy_retro PRIVATE NOMINMAX _WIN32_WINNT=0x0A00)
    target_compile_definitions(plezy_retro_worker PRIVATE NOMINMAX _WIN32_WINNT=0x0A00)
    target_link_libraries(plezy_retro PRIVATE bcrypt userenv advapi32)
    target_link_libraries(plezy_retro_worker PRIVATE advapi32)
    if(MSVC)
      set_property(TARGET plezy_retro_worker PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    endif()
  elseif(APPLE)
    target_compile_options(plezy_retro_worker PRIVATE -Wno-deprecated-declarations)
    set_target_properties(plezy_retro_worker PROPERTIES OBJCXX_STANDARD 17 OBJCXX_STANDARD_REQUIRED YES)
  else()
    target_compile_definitions(plezy_retro PRIVATE _GNU_SOURCE)
    target_compile_definitions(plezy_retro_worker PRIVATE _GNU_SOURCE)
    find_package(Threads REQUIRED)
    target_link_libraries(plezy_retro_worker PRIVATE Threads::Threads ${CMAKE_DL_LIBS} m)
  endif()
else()
  add_library(plezy_retro SHARED retro_host.cpp)
endif()
target_compile_features(plezy_retro PRIVATE cxx_std_17)
target_include_directories(plezy_retro PRIVATE "${romm_libretro_common_SOURCE_DIR}/include" "${romm_miniaudio_SOURCE_DIR}")
set_target_properties(plezy_retro PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN YES)
if(WIN32)
  target_link_libraries(plezy_retro PRIVATE winmm ole32)
elseif(APPLE)
  set_target_properties(plezy_retro PROPERTIES OBJCXX_STANDARD 17
    OBJCXX_STANDARD_REQUIRED YES OBJCXX_VISIBILITY_PRESET hidden)
  target_link_libraries(plezy_retro PRIVATE "-framework CoreAudio" "-framework AudioToolbox"
    "-framework CoreFoundation" "-framework Foundation" "-framework AVFoundation")
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
  if(PLEZY_ROMM_ISOLATED)
    install(TARGETS plezy_retro_worker RUNTIME DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
  endif()
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

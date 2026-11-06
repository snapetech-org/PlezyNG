cmake_minimum_required(VERSION 3.22)

# These software cores are part of the normal application build. They inherit
# the app's compiler, architecture and SDK; no runtime executable download occurs.
include(FetchContent)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
file(READ "${CMAKE_CURRENT_LIST_DIR}/../core-sources.json" ROMM_CORE_PINS)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_LIST_DIR}/../core-sources.json")
foreach(core gambatte mgba fceumm)
  string(JSON revision GET "${ROMM_CORE_PINS}" "${core}" commit)
  string(JSON repository GET "${ROMM_CORE_PINS}" "${core}" repository)
  FetchContent_Declare(romm_${core}
    GIT_REPOSITORY "https://github.com/libretro/${repository}.git"
    GIT_TAG "${revision}"
    SOURCE_SUBDIR _plezy_source_only)
endforeach()
FetchContent_MakeAvailable(romm_gambatte romm_mgba romm_fceumm)
execute_process(
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/../../../../scripts/games/package_romm_cores.py"
    --verify-sources
    --source "gambatte=${romm_gambatte_SOURCE_DIR}"
    --source "mgba=${romm_mgba_SOURCE_DIR}"
    --source "fceumm=${romm_fceumm_SOURCE_DIR}"
  COMMAND_ERROR_IS_FATAL ANY)

# Keep mGBA's directory-scoped configuration away from the Flutter runner.
# In particular BINARY_NAME must not inherit the application's executable name.
function(plezy_add_mgba)
  set(BINARY_NAME mgba)
  set(LIBMGBA_ONLY ON)
  set(BUILD_LIBRETRO ON)
  set(LIBRETRO_STATIC OFF)
  set(SKIP_LIBRARY ON)
  set(BUILD_QT OFF)
  set(BUILD_SDL OFF)
  set(BUILD_TEST OFF)
  set(BUILD_SUITE OFF)
  set(DISABLE_DEPS ON)
  if(APPLE)
    # Upstream lowers its function probes to macOS 10.6, rejected by current
    # SDKs. Detect the SDK declaration before that override; otherwise its
    # fallback strlcpy declaration collides with Apple's fortified macro.
    include(CheckSymbolExists)
    check_symbol_exists(strlcpy "string.h" PLEZY_MGBA_HAVE_STRLCPY)
    set(HAVE_STRLCPY "${PLEZY_MGBA_HAVE_STRLCPY}")
  endif()
  add_subdirectory("${romm_mgba_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/mgba" EXCLUDE_FROM_ALL)
endfunction()
plezy_add_mgba()

# Source selections and defines mirror the pinned upstream Makefile.common
# files. CMake supplies portable MSVC, Android and Apple shared-library links.
set(common_units
  compat/compat_posix_string.c compat/compat_snprintf.c
  compat/compat_strcasestr.c compat/compat_strl.c compat/fopen_utf8.c
  encodings/encoding_utf.c file/file_path.c file/file_path_io.c
  streams/file_stream.c streams/file_stream_transforms.c
  string/stdstring.c time/rtime.c vfs/vfs_implementation.c)

set(gambatte "${romm_gambatte_SOURCE_DIR}/libgambatte")
file(GLOB gambatte_cpp CONFIGURE_DEPENDS
  "${gambatte}/src/*.cpp" "${gambatte}/src/mem/*.cpp"
  "${gambatte}/src/sound/*.cpp" "${gambatte}/src/video/*.cpp")
set(gambatte_sources ${gambatte_cpp}
  "${gambatte}/libretro/libretro.cpp"
  "${gambatte}/libretro/gambatte_log.c"
  "${gambatte}/libretro/blipper.c"
  "${gambatte}/libretro/cc_resampler.c")
foreach(unit IN LISTS common_units)
  list(APPEND gambatte_sources "${gambatte}/libretro-common/${unit}")
endforeach()
add_library(gambatte_libretro SHARED ${gambatte_sources})
target_include_directories(gambatte_libretro PRIVATE
  "${gambatte}/src" "${gambatte}/include" "${romm_gambatte_SOURCE_DIR}/common"
  "${romm_gambatte_SOURCE_DIR}/common/resample" "${gambatte}/libretro"
  "${gambatte}/libretro-common/include")
target_compile_definitions(gambatte_libretro PRIVATE
  __LIBRETRO__ HAVE_STDINT_H HAVE_INTTYPES_H CC_RESAMPLER_NO_HIGHPASS VIDEO_RGB565)
set_target_properties(gambatte_libretro PROPERTIES CXX_STANDARD 98 CXX_EXTENSIONS ON)

set(fceumm "${romm_fceumm_SOURCE_DIR}/src")
set(fceumm_common "${fceumm}/drivers/libretro/libretro-common")
file(GLOB fceumm_sources CONFIGURE_DEPENDS "${fceumm}/boards/*.c" "${fceumm}/input/*.c")
foreach(unit cart cheat crc32 fceu-endian fceu-memory fceu fds fds_apu file
    filter general input md5 nsf palette ppu sound state video vsuni ines unif x6502)
  list(APPEND fceumm_sources "${fceumm}/${unit}.c")
endforeach()
list(APPEND fceumm_sources "${fceumm}/ntsc/nes_ntsc.c"
  "${fceumm}/drivers/libretro/libretro.c"
  "${fceumm}/drivers/libretro/libretro_dipswitch.c")
foreach(unit hdpack_load hdpack_image hdpack_ppu hdpack_render hdpack_audio hdpack_patch)
  list(APPEND fceumm_sources "${fceumm}/hdpack/${unit}.c")
endforeach()
foreach(unit IN LISTS common_units)
  list(APPEND fceumm_sources "${fceumm_common}/${unit}")
endforeach()
foreach(unit formats/png/rpng.c formats/dds/rdds.c formats/webp/rwebp.c
    formats/vp8/rvp8.c formats/vorbis/rvorbis.c formats/wav/rwav.c
    streams/trans_stream.c streams/trans_stream_pipe.c streams/trans_stream_deflate.c
    encodings/encoding_deflate.c streams/memory_stream.c)
  list(APPEND fceumm_sources "${fceumm_common}/${unit}")
endforeach()
add_library(fceumm_libretro SHARED ${fceumm_sources})
target_include_directories(fceumm_libretro PRIVATE
  "${fceumm}/drivers/libretro" "${fceumm_common}/include"
  "${fceumm}" "${fceumm}/input" "${fceumm}/boards" "${fceumm}/ntsc")
target_compile_definitions(fceumm_libretro PRIVATE
  __LIBRETRO__ PATH_MAX=1024 FCEU_VERSION_NUMERIC=9900
  FRONTEND_SUPPORTS_RGB888 HAVE_NTSC_FILTER HAVE_HDPACK)
set_target_properties(fceumm_libretro PROPERTIES C_STANDARD 99 C_EXTENSIONS ON)

foreach(core gambatte mgba fceumm)
  set(target ${core}_libretro)
  set_target_properties(${target} PROPERTIES PREFIX "" C_VISIBILITY_PRESET hidden
    CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN YES)
  if(ANDROID)
    set_target_properties(${target} PROPERTIES PREFIX "lib")
    target_link_options(${target} PRIVATE "-Wl,-z,max-page-size=16384")
  elseif(APPLE)
    set_target_properties(${target} PROPERTIES FRAMEWORK TRUE FRAMEWORK_VERSION A
      OUTPUT_NAME "${target}" INSTALL_NAME_DIR "@rpath"
      MACOSX_FRAMEWORK_IDENTIFIER "org.snapetech.pleazyng.romm.${core}"
      MACOSX_FRAMEWORK_BUNDLE_VERSION 1.0.0
      MACOSX_FRAMEWORK_SHORT_VERSION_STRING 1.0.0)
  endif()
  if(MSVC)
    target_compile_definitions(${target} PRIVATE _CRT_SECURE_NO_WARNINGS)
  elseif(NOT APPLE)
    if(core STREQUAL "mgba")
      # The pinned upstream target uses the plain link signature.
      target_link_libraries(${target} m)
    else()
      target_link_libraries(${target} PRIVATE m)
    endif()
  endif()
endforeach()

if(ANDROID AND PLEZY_ROMM_NOTICES_ROOT)
  set(romm_notices "${PLEZY_ROMM_NOTICES_ROOT}/romm-notices/${ANDROID_ABI}")
else()
  set(romm_notices "${CMAKE_CURRENT_BINARY_DIR}/notices")
endif()
set(ROMM_NOTICES_DIR "${romm_notices}" CACHE INTERNAL "RomM corresponding source" FORCE)
set(romm_architecture "${CMAKE_SYSTEM_PROCESSOR}")
if(APPLE)
  string(REPLACE ";" "," romm_architecture "${CMAKE_OSX_ARCHITECTURES}")
elseif(ANDROID)
  set(romm_architecture "${ANDROID_ABI}")
endif()
add_custom_target(plezy_romm_notices
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/../../../../scripts/games/package_romm_cores.py"
    --output "${ROMM_NOTICES_DIR}"
    --source "gambatte=${romm_gambatte_SOURCE_DIR}"
    --source "mgba=${romm_mgba_SOURCE_DIR}"
    --source "fceumm=${romm_fceumm_SOURCE_DIR}"
    --library "gambatte=$<TARGET_FILE:gambatte_libretro>"
    --library "mgba=$<TARGET_FILE:mgba_libretro>"
    --library "fceumm=$<TARGET_FILE:fceumm_libretro>"
    --host-source "libretro_common=${romm_libretro_common_SOURCE_DIR}"
    --host-source "miniaudio=${romm_miniaudio_SOURCE_DIR}"
    --platform "${CMAKE_SYSTEM_NAME}" --architecture "${romm_architecture}"
  DEPENDS gambatte_libretro mgba_libretro fceumm_libretro
  VERBATIM)
add_dependencies(plezy_retro plezy_romm_notices)

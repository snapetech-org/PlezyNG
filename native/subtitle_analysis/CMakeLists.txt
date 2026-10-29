cmake_minimum_required(VERSION 3.15)
project(plezy_subtitle_analysis LANGUAGES C)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(PLEZY_SUBTITLE_FFMPEG_SOURCE_DIR "$ENV{PLEZY_SUBTITLE_FFMPEG_SOURCE_DIR}" CACHE PATH "Pinned FFmpeg source checkout")
if(NOT CMAKE_CROSSCOMPILING OR NOT EXISTS "${PLEZY_SUBTITLE_FFMPEG_SOURCE_DIR}/configure")
  message(FATAL_ERROR "Supply the pinned source checkout and an explicit TV cross toolchain")
endif()
set(analysis_sysroot "${CMAKE_SYSROOT}")
if(NOT analysis_sysroot)
  set(analysis_sysroot "$ENV{SDKTARGETSYSROOT}")
endif()
if(NOT IS_DIRECTORY "${analysis_sysroot}")
  message(FATAL_ERROR "A target SDK sysroot is required; host fallback is forbidden")
endif()
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm|armv7|armv7l|armv7-a)$")
  set(analysis_arch arm)
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  set(analysis_arch aarch64)
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|x64)$")
  set(analysis_arch x86_64)
else()
  message(FATAL_ERROR "Unsupported TV decoder processor: ${CMAKE_SYSTEM_PROCESSOR}")
endif()
set(analysis_output "${CMAKE_CURRENT_BINARY_DIR}/audio-ffmpeg")
add_custom_command(OUTPUT "${analysis_output}/plezy-subtitle-ffmpeg" "${analysis_output}/subtitle-analysis-build.json"
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/build.py" build
    --source "${PLEZY_SUBTITLE_FFMPEG_SOURCE_DIR}" --output "${analysis_output}"
    --cc "${CMAKE_C_COMPILER}" --ar "${CMAKE_AR}" --sysroot "${analysis_sysroot}" --arch "${analysis_arch}"
    "--cflags=${CMAKE_C_FLAGS} ${CMAKE_C_FLAGS_RELEASE} $ENV{CFLAGS}" "--ldflags=${CMAKE_EXE_LINKER_FLAGS} $ENV{LDFLAGS}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/build.py" "${CMAKE_CURRENT_SOURCE_DIR}/ffmpeg.lock.json"
  VERBATIM)
add_custom_target(plezy_subtitle_ffmpeg ALL DEPENDS "${analysis_output}/plezy-subtitle-ffmpeg" "${analysis_output}/subtitle-analysis-build.json")
install(PROGRAMS "${analysis_output}/plezy-subtitle-ffmpeg" DESTINATION lib)
install(FILES "${analysis_output}/subtitle-analysis-build.json" "${analysis_output}/COPYING.LGPLv2.1" "${analysis_output}/FFmpeg-LICENSE.md"
  "${CMAKE_CURRENT_SOURCE_DIR}/ffmpeg.lock.json" "${CMAKE_CURRENT_SOURCE_DIR}/build.py" "${CMAKE_CURRENT_SOURCE_DIR}/CMakeLists.txt"
  DESTINATION share/subtitle_analysis)

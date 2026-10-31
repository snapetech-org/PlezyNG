cmake_minimum_required(VERSION 3.16)
project(plezy_motion_engine LANGUAGES CXX)

set(ONNXRUNTIME_ROOT "" CACHE PATH "ONNX Runtime SDK root with C API v27 or newer")
set(PME_ORT_RUNTIME_LIBRARY "" CACHE FILEPATH "ONNX Runtime shared library to bundle")
set(PME_PROVIDER_LIBRARIES "" CACHE STRING "ONNX Runtime provider shared libraries to bundle")
set(PME_PROVIDER_DEPENDENCY_LIBRARIES "" CACHE STRING "Non-ORT shared libraries required by execution providers")
set(PME_PROVIDER_NOTICE_FILES "" CACHE STRING "Provider licenses and third-party notices to bundle")
set(PME_PROVIDER_RUNTIME_FILES "" CACHE STRING "Non-library runtime data files required by providers")
option(PME_BUILD_RUNTIME_PROBE "Build the standalone PME provider/inference diagnostic" OFF)
set(PLEZY_ORT_LINUX_VARIANT "cpu" CACHE STRING "Linux ONNX Runtime bundle: cpu, amd-migraphx, openvino, or webgpu")
set_property(CACHE PLEZY_ORT_LINUX_VARIANT PROPERTY STRINGS cpu amd-migraphx openvino webgpu)

if(UNIX AND NOT APPLE)
  if(NOT PLEZY_ORT_LINUX_VARIANT STREQUAL "cpu" AND
     NOT PLEZY_ORT_LINUX_VARIANT STREQUAL "amd-migraphx" AND
     NOT PLEZY_ORT_LINUX_VARIANT STREQUAL "openvino" AND
     NOT PLEZY_ORT_LINUX_VARIANT STREQUAL "webgpu")
    message(FATAL_ERROR "PLEZY_ORT_LINUX_VARIANT must be 'cpu', 'amd-migraphx', 'openvino', or 'webgpu'")
  endif()
endif()

set(PME_ORT_RUNTIME_USER_SUPPLIED FALSE)

find_package(Threads REQUIRED)
if(WIN32)
  if(NOT TARGET WindowsML::Api)
    if(NOT PLEZY_WINML_PACKAGE_ROOT OR NOT EXISTS "${PLEZY_WINML_PACKAGE_ROOT}/build/cmake")
      message(FATAL_ERROR "PLEZY_WINML_PACKAGE_ROOT must point to the extracted Windows ML NuGet package")
    endif()
    find_package(microsoft.windows.ai.machinelearning CONFIG REQUIRED
      PATHS "${PLEZY_WINML_PACKAGE_ROOT}/build/cmake"
      NO_DEFAULT_PATH
    )
  endif()
  if(NOT WINML_INCLUDE_DIR OR NOT WINML_BINARY_DIR OR NOT WINML_DIRECTML_DLL)
    message(FATAL_ERROR "PLEZY_WINML_PACKAGE_ROOT must point to the extracted Windows ML NuGet package")
  endif()
  set(ONNXRUNTIME_ROOT "${PLEZY_WINML_PACKAGE_ROOT}")
  set(ONNXRUNTIME_INCLUDE_DIR "${WINML_INCLUDE_DIR}/winml")
  set(PME_ORT_RUNTIME_LIBRARY "${WINML_BINARY_DIR}/onnxruntime.dll")
endif()

if(NOT WIN32 AND NOT ONNXRUNTIME_ROOT AND DEFINED ENV{ONNXRUNTIME_ROOT})
  set(ONNXRUNTIME_ROOT "$ENV{ONNXRUNTIME_ROOT}")
endif()
if(NOT PME_ORT_RUNTIME_LIBRARY AND DEFINED ENV{PME_ORT_RUNTIME_LIBRARY})
  set(PME_ORT_RUNTIME_LIBRARY "$ENV{PME_ORT_RUNTIME_LIBRARY}")
  set(PME_ORT_RUNTIME_USER_SUPPLIED TRUE)
elseif(PME_ORT_RUNTIME_LIBRARY)
  set(PME_ORT_RUNTIME_USER_SUPPLIED TRUE)
endif()

# Linux app builds get a reproducible SDK/runtime by default. AMD's MIGraphX
# mode keeps the official API-v27 SDK for compilation but stages AMD's pinned
# ORT 1.23 runtime and built-in provider from the matching ROCm wheel.
if(UNIX AND NOT APPLE)
  if(FLUTTER_TARGET_PLATFORM STREQUAL "linux-arm64")
    set(PLEZY_ORT_PLATFORM "linux-aarch64")
    set(PLEZY_ORT_SHA256 "33c67e33d1e25b816878366ea276589a024f71f000e7ff955c4b33224d639edd")
  elseif(FLUTTER_TARGET_PLATFORM STREQUAL "linux-x64")
    set(PLEZY_ORT_PLATFORM "linux-x64")
    set(PLEZY_ORT_SHA256 "25b1ef1fea1acd210d63f8f24dc870ad6e077795ce1f54876252c6d3803c15af")
  elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
    set(PLEZY_ORT_PLATFORM "linux-aarch64")
    set(PLEZY_ORT_SHA256 "33c67e33d1e25b816878366ea276589a024f71f000e7ff955c4b33224d639edd")
  elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64)$")
    set(PLEZY_ORT_PLATFORM "linux-x64")
    set(PLEZY_ORT_SHA256 "25b1ef1fea1acd210d63f8f24dc870ad6e077795ce1f54876252c6d3803c15af")
  else()
    message(FATAL_ERROR "No pinned ONNX Runtime package for Linux target '${FLUTTER_TARGET_PLATFORM}' (${CMAKE_SYSTEM_PROCESSOR})")
  endif()
endif()

if(UNIX AND NOT APPLE AND NOT ONNXRUNTIME_ROOT)
  set(PLEZY_ORT_VERSION "1.27.1")
  set(PLEZY_ORT_ARCHIVE_NAME "onnxruntime-${PLEZY_ORT_PLATFORM}-${PLEZY_ORT_VERSION}.tgz")
  set(PLEZY_ORT_CACHE_DIR "${CMAKE_BINARY_DIR}/onnxruntime/${PLEZY_ORT_VERSION}")
  set(PLEZY_ORT_DOWNLOAD_DIR "${PLEZY_ORT_CACHE_DIR}/downloads")
  set(PLEZY_ORT_EXTRACT_DIR "${PLEZY_ORT_CACHE_DIR}/sdk")
  set(PLEZY_ORT_ROOT "${PLEZY_ORT_EXTRACT_DIR}/onnxruntime-${PLEZY_ORT_PLATFORM}-${PLEZY_ORT_VERSION}")
  set(PLEZY_ORT_ARCHIVE "${PLEZY_ORT_DOWNLOAD_DIR}/${PLEZY_ORT_ARCHIVE_NAME}")
  file(MAKE_DIRECTORY "${PLEZY_ORT_DOWNLOAD_DIR}" "${PLEZY_ORT_EXTRACT_DIR}")

  if(EXISTS "${PLEZY_ORT_ARCHIVE}")
    file(SHA256 "${PLEZY_ORT_ARCHIVE}" PLEZY_ORT_CACHED_SHA256)
    if(NOT PLEZY_ORT_CACHED_SHA256 STREQUAL PLEZY_ORT_SHA256)
      file(REMOVE "${PLEZY_ORT_ARCHIVE}")
    endif()
  endif()
  if(NOT EXISTS "${PLEZY_ORT_ARCHIVE}")
    message(STATUS "Downloading pinned ONNX Runtime ${PLEZY_ORT_VERSION} for ${PLEZY_ORT_PLATFORM}")
    file(DOWNLOAD
      "https://github.com/microsoft/onnxruntime/releases/download/v${PLEZY_ORT_VERSION}/${PLEZY_ORT_ARCHIVE_NAME}"
      "${PLEZY_ORT_ARCHIVE}"
      EXPECTED_HASH "SHA256=${PLEZY_ORT_SHA256}"
      STATUS PLEZY_ORT_DOWNLOAD_STATUS
    )
    list(GET PLEZY_ORT_DOWNLOAD_STATUS 0 PLEZY_ORT_DOWNLOAD_RESULT)
    if(NOT PLEZY_ORT_DOWNLOAD_RESULT EQUAL 0)
      file(REMOVE "${PLEZY_ORT_ARCHIVE}")
      message(FATAL_ERROR "Could not download the verified ONNX Runtime package: ${PLEZY_ORT_DOWNLOAD_STATUS}")
    endif()
  endif()
  if(NOT EXISTS "${PLEZY_ORT_ROOT}/include/onnxruntime_c_api.h")
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E tar xzf "${PLEZY_ORT_ARCHIVE}"
      WORKING_DIRECTORY "${PLEZY_ORT_EXTRACT_DIR}"
      RESULT_VARIABLE PLEZY_ORT_EXTRACT_RESULT
    )
    if(NOT PLEZY_ORT_EXTRACT_RESULT EQUAL 0 OR NOT EXISTS "${PLEZY_ORT_ROOT}/include/onnxruntime_c_api.h")
      message(FATAL_ERROR "Could not extract the pinned ONNX Runtime SDK")
    endif()
  endif()
  set(ONNXRUNTIME_ROOT "${PLEZY_ORT_ROOT}")
  if(NOT PME_ORT_RUNTIME_LIBRARY_USER_SUPPLIED AND NOT PLEZY_ORT_LINUX_VARIANT STREQUAL "amd-migraphx")
    set(PME_ORT_RUNTIME_LIBRARY "${PLEZY_ORT_ROOT}/lib/libonnxruntime.so")
  endif()
endif()

set(PME_ORT_LICENSE_FILE "${ONNXRUNTIME_ROOT}/LICENSE")
set(PME_ORT_THIRD_PARTY_NOTICES_FILE "${ONNXRUNTIME_ROOT}/ThirdPartyNotices.txt")
set(PME_LINUX_PROVIDER_MANIFEST "${CMAKE_CURRENT_LIST_DIR}/providers.linux.tsv")

if(UNIX AND NOT APPLE AND PLEZY_ORT_LINUX_VARIANT STREQUAL "amd-migraphx")
  if(NOT PLEZY_ORT_PLATFORM STREQUAL "linux-x64")
    message(FATAL_ERROR "The pinned AMD ROCm 7.2.1 MIGraphX package requires the linux-x64 target")
  endif()
  if(PME_ORT_RUNTIME_USER_SUPPLIED)
    message(FATAL_ERROR "PLEZY_ORT_LINUX_VARIANT=amd-migraphx pins its own ORT runtime; unset PME_ORT_RUNTIME_LIBRARY")
  endif()

  set(PLEZY_AMD_ORT_VERSION "1.23.2")
  set(PLEZY_AMD_ROCM_VERSION "7.2.1")
  set(PLEZY_AMD_ORT_WHEEL_NAME "onnxruntime_migraphx-${PLEZY_AMD_ORT_VERSION}-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl")
  set(PLEZY_AMD_ORT_WHEEL_SHA256 "663bff4dc3f72582d69f12ad073eb5695dfb526d574376cc8e5b161c7d2f0f08")
  set(PLEZY_AMD_ORT_CACHE_DIR "${CMAKE_BINARY_DIR}/onnxruntime/rocm-${PLEZY_AMD_ROCM_VERSION}")
  set(PLEZY_AMD_ORT_DOWNLOAD_DIR "${PLEZY_AMD_ORT_CACHE_DIR}/downloads")
  set(PLEZY_AMD_ORT_EXTRACT_DIR "${PLEZY_AMD_ORT_CACHE_DIR}/runtime")
  set(PLEZY_AMD_ORT_WHEEL "${PLEZY_AMD_ORT_DOWNLOAD_DIR}/${PLEZY_AMD_ORT_WHEEL_NAME}")
  file(MAKE_DIRECTORY "${PLEZY_AMD_ORT_DOWNLOAD_DIR}" "${PLEZY_AMD_ORT_EXTRACT_DIR}")

  if(EXISTS "${PLEZY_AMD_ORT_WHEEL}")
    file(SHA256 "${PLEZY_AMD_ORT_WHEEL}" PLEZY_AMD_ORT_CACHED_SHA256)
    if(NOT PLEZY_AMD_ORT_CACHED_SHA256 STREQUAL PLEZY_AMD_ORT_WHEEL_SHA256)
      file(REMOVE "${PLEZY_AMD_ORT_WHEEL}")
    endif()
  endif()
  if(NOT EXISTS "${PLEZY_AMD_ORT_WHEEL}")
    message(STATUS "Downloading pinned AMD ROCm ${PLEZY_AMD_ROCM_VERSION} ONNX Runtime ${PLEZY_AMD_ORT_VERSION} MIGraphX package")
    file(DOWNLOAD
      "https://repo.radeon.com/rocm/manylinux/rocm-rel-${PLEZY_AMD_ROCM_VERSION}/${PLEZY_AMD_ORT_WHEEL_NAME}"
      "${PLEZY_AMD_ORT_WHEEL}"
      EXPECTED_HASH "SHA256=${PLEZY_AMD_ORT_WHEEL_SHA256}"
      STATUS PLEZY_AMD_ORT_DOWNLOAD_STATUS
    )
    list(GET PLEZY_AMD_ORT_DOWNLOAD_STATUS 0 PLEZY_AMD_ORT_DOWNLOAD_RESULT)
    if(NOT PLEZY_AMD_ORT_DOWNLOAD_RESULT EQUAL 0)
      file(REMOVE "${PLEZY_AMD_ORT_WHEEL}")
      message(FATAL_ERROR "Could not download the verified AMD ONNX Runtime package: ${PLEZY_AMD_ORT_DOWNLOAD_STATUS}")
    endif()
  endif()

  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  execute_process(
    COMMAND "${Python3_EXECUTABLE}"
      "${CMAKE_CURRENT_LIST_DIR}/../../../scripts/motion/extract_amd_ort_wheel.py"
      "${PLEZY_AMD_ORT_WHEEL}"
      "${PLEZY_AMD_ORT_EXTRACT_DIR}"
      "${PLEZY_AMD_ORT_WHEEL_SHA256}"
    RESULT_VARIABLE PLEZY_AMD_ORT_EXTRACT_RESULT
    OUTPUT_VARIABLE PLEZY_AMD_ORT_EXTRACT_OUTPUT
    ERROR_VARIABLE PLEZY_AMD_ORT_EXTRACT_ERROR
  )
  if(NOT PLEZY_AMD_ORT_EXTRACT_RESULT EQUAL 0)
    message(FATAL_ERROR "Could not extract the pinned AMD ONNX Runtime package: ${PLEZY_AMD_ORT_EXTRACT_ERROR}")
  endif()

  set(PLEZY_AMD_ORT_RUNTIME "${PLEZY_AMD_ORT_EXTRACT_DIR}/libonnxruntime.so.1.23.2")
  set(PME_ORT_RUNTIME_LIBRARY "${PLEZY_AMD_ORT_RUNTIME}")
  list(APPEND PME_PROVIDER_LIBRARIES
    "${PLEZY_AMD_ORT_EXTRACT_DIR}/libonnxruntime_providers_migraphx.so"
    "${PLEZY_AMD_ORT_EXTRACT_DIR}/libonnxruntime_providers_shared.so"
  )
  set(PME_ORT_LICENSE_FILE "${PLEZY_AMD_ORT_EXTRACT_DIR}/ONNXRuntime-License.txt")
  set(PME_ORT_THIRD_PARTY_NOTICES_FILE "${PLEZY_AMD_ORT_EXTRACT_DIR}/ONNXRuntime-ThirdPartyNotices.txt")
  set(PME_LINUX_PROVIDER_MANIFEST "${CMAKE_CURRENT_LIST_DIR}/providers.linux.migraphx.tsv")
endif()

if(UNIX AND NOT APPLE AND PLEZY_ORT_LINUX_VARIANT STREQUAL "openvino")
  if(NOT PLEZY_ORT_PLATFORM STREQUAL "linux-x64")
    message(FATAL_ERROR "The pinned OpenVINO Plugin EP wheel requires Linux x86_64")
  endif()

  set(PLEZY_OPENVINO_EP_VERSION "1.8.1")
  set(PLEZY_OPENVINO_EP_WHEEL_NAME "onnxruntime_ep_openvino-${PLEZY_OPENVINO_EP_VERSION}-py3-none-manylinux_2_28_x86_64.whl")
  set(PLEZY_OPENVINO_EP_WHEEL_SHA256 "3832643158c8c187fcab6db661cde2a8c06a2b3559d95d0f2411ac0e51c5e924")
  set(PLEZY_OPENVINO_EP_WHEEL_URL "https://files.pythonhosted.org/packages/88/01/4e72a8a65b584f01d6e59eb453bae397b82b2e51df1b5c94efa05e17800b/${PLEZY_OPENVINO_EP_WHEEL_NAME}")
  set(PLEZY_OPENVINO_EP_CACHE_DIR "${CMAKE_BINARY_DIR}/onnxruntime/openvino-${PLEZY_OPENVINO_EP_VERSION}")
  set(PLEZY_OPENVINO_EP_DOWNLOAD_DIR "${PLEZY_OPENVINO_EP_CACHE_DIR}/downloads")
  set(PLEZY_OPENVINO_EP_EXTRACT_DIR "${PLEZY_OPENVINO_EP_CACHE_DIR}/runtime")
  set(PLEZY_OPENVINO_EP_WHEEL "${PLEZY_OPENVINO_EP_DOWNLOAD_DIR}/${PLEZY_OPENVINO_EP_WHEEL_NAME}")
  file(MAKE_DIRECTORY "${PLEZY_OPENVINO_EP_DOWNLOAD_DIR}" "${PLEZY_OPENVINO_EP_EXTRACT_DIR}")

  if(EXISTS "${PLEZY_OPENVINO_EP_WHEEL}")
    file(SHA256 "${PLEZY_OPENVINO_EP_WHEEL}" PLEZY_OPENVINO_EP_CACHED_SHA256)
    if(NOT PLEZY_OPENVINO_EP_CACHED_SHA256 STREQUAL PLEZY_OPENVINO_EP_WHEEL_SHA256)
      file(REMOVE "${PLEZY_OPENVINO_EP_WHEEL}")
    endif()
  endif()
  if(NOT EXISTS "${PLEZY_OPENVINO_EP_WHEEL}")
    message(STATUS "Downloading pinned OpenVINO Plugin EP ${PLEZY_OPENVINO_EP_VERSION}")
    file(DOWNLOAD
      "${PLEZY_OPENVINO_EP_WHEEL_URL}"
      "${PLEZY_OPENVINO_EP_WHEEL}"
      EXPECTED_HASH "SHA256=${PLEZY_OPENVINO_EP_WHEEL_SHA256}"
      STATUS PLEZY_OPENVINO_EP_DOWNLOAD_STATUS
    )
    list(GET PLEZY_OPENVINO_EP_DOWNLOAD_STATUS 0 PLEZY_OPENVINO_EP_DOWNLOAD_RESULT)
    if(NOT PLEZY_OPENVINO_EP_DOWNLOAD_RESULT EQUAL 0)
      file(REMOVE "${PLEZY_OPENVINO_EP_WHEEL}")
      message(FATAL_ERROR "Could not download the verified OpenVINO Plugin EP wheel: ${PLEZY_OPENVINO_EP_DOWNLOAD_STATUS}")
    endif()
  endif()

  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  execute_process(
    COMMAND "${Python3_EXECUTABLE}"
      "${CMAKE_CURRENT_LIST_DIR}/../../../scripts/motion/extract_openvino_ep_wheel.py"
      "${PLEZY_OPENVINO_EP_WHEEL}"
      "${PLEZY_OPENVINO_EP_EXTRACT_DIR}"
      "${PLEZY_OPENVINO_EP_WHEEL_SHA256}"
    RESULT_VARIABLE PLEZY_OPENVINO_EP_EXTRACT_RESULT
    OUTPUT_VARIABLE PLEZY_OPENVINO_EP_EXTRACT_OUTPUT
    ERROR_VARIABLE PLEZY_OPENVINO_EP_EXTRACT_ERROR
  )
  if(NOT PLEZY_OPENVINO_EP_EXTRACT_RESULT EQUAL 0)
    message(FATAL_ERROR "Could not extract the pinned OpenVINO Plugin EP wheel: ${PLEZY_OPENVINO_EP_EXTRACT_ERROR}")
  endif()

  set(PLEZY_OPENVINO_EP_PLUGIN "${PLEZY_OPENVINO_EP_EXTRACT_DIR}/libonnxruntime_providers_openvino_plugin.so")
  if(NOT EXISTS "${PLEZY_OPENVINO_EP_PLUGIN}")
    message(FATAL_ERROR "The OpenVINO Plugin EP wheel did not produce its provider library")
  endif()
  list(APPEND PME_PROVIDER_LIBRARIES "${PLEZY_OPENVINO_EP_PLUGIN}")
  file(GLOB PLEZY_OPENVINO_EP_DEPENDENCIES
    "${PLEZY_OPENVINO_EP_EXTRACT_DIR}/*.so"
    "${PLEZY_OPENVINO_EP_EXTRACT_DIR}/*.so.*"
  )
  list(REMOVE_ITEM PLEZY_OPENVINO_EP_DEPENDENCIES "${PLEZY_OPENVINO_EP_PLUGIN}")
  list(APPEND PME_PROVIDER_DEPENDENCY_LIBRARIES ${PLEZY_OPENVINO_EP_DEPENDENCIES})
  list(APPEND PME_PROVIDER_NOTICE_FILES
    "${PLEZY_OPENVINO_EP_EXTRACT_DIR}/OpenVINO-Plugin-ThirdPartyNotices.txt"
    "${PLEZY_OPENVINO_EP_EXTRACT_DIR}/OpenVINO-Plugin-METADATA.txt"
    "${CMAKE_CURRENT_LIST_DIR}/licenses/OpenVINO-Plugin-LICENSE.txt"
  )
  list(APPEND PME_PROVIDER_RUNTIME_FILES "${PLEZY_OPENVINO_EP_EXTRACT_DIR}/OpenVINO-Plugin-cache.json")
endif()

if(UNIX AND NOT APPLE AND PLEZY_ORT_LINUX_VARIANT STREQUAL "webgpu")
  if(PLEZY_ORT_PLATFORM STREQUAL "linux-x64")
    set(PLEZY_WEBGPU_EP_WHEEL_NAME "onnxruntime_ep_webgpu-0.5.0-py3-none-manylinux_2_28_x86_64.whl")
    set(PLEZY_WEBGPU_EP_WHEEL_SHA256 "b6baa3e223d9a679023388b1179e5597b6bc0d282ba72f2afe38d46ef37deeb4")
    set(PLEZY_WEBGPU_EP_WHEEL_URL "https://files.pythonhosted.org/packages/e2/1d/ac0ccbe8bd6435b6e1946fea964790ffa3d73ee2513775e90958fd6b860e/${PLEZY_WEBGPU_EP_WHEEL_NAME}")
  elseif(PLEZY_ORT_PLATFORM STREQUAL "linux-aarch64")
    set(PLEZY_WEBGPU_EP_WHEEL_NAME "onnxruntime_ep_webgpu-0.5.0-py3-none-manylinux_2_28_aarch64.whl")
    set(PLEZY_WEBGPU_EP_WHEEL_SHA256 "d39e0769f8b2ff7a4b04a492ef882510474d52cf722408d393569b36558b2829")
    set(PLEZY_WEBGPU_EP_WHEEL_URL "https://files.pythonhosted.org/packages/93/ca/71f305dc822d62ef33d7f3862ba7058a0099086112d9ab679d8252e7b77d/${PLEZY_WEBGPU_EP_WHEEL_NAME}")
  else()
    message(FATAL_ERROR "The pinned WebGPU Plugin EP wheel requires Linux x86_64 or ARM64")
  endif()

  set(PLEZY_WEBGPU_EP_VERSION "0.5.0")
  set(PLEZY_WEBGPU_EP_CACHE_DIR "${CMAKE_BINARY_DIR}/onnxruntime/webgpu-${PLEZY_WEBGPU_EP_VERSION}")
  set(PLEZY_WEBGPU_EP_DOWNLOAD_DIR "${PLEZY_WEBGPU_EP_CACHE_DIR}/downloads")
  set(PLEZY_WEBGPU_EP_EXTRACT_DIR "${PLEZY_WEBGPU_EP_CACHE_DIR}/runtime")
  set(PLEZY_WEBGPU_EP_WHEEL "${PLEZY_WEBGPU_EP_DOWNLOAD_DIR}/${PLEZY_WEBGPU_EP_WHEEL_NAME}")
  file(MAKE_DIRECTORY "${PLEZY_WEBGPU_EP_DOWNLOAD_DIR}" "${PLEZY_WEBGPU_EP_EXTRACT_DIR}")

  if(EXISTS "${PLEZY_WEBGPU_EP_WHEEL}")
    file(SHA256 "${PLEZY_WEBGPU_EP_WHEEL}" PLEZY_WEBGPU_EP_CACHED_SHA256)
    if(NOT PLEZY_WEBGPU_EP_CACHED_SHA256 STREQUAL PLEZY_WEBGPU_EP_WHEEL_SHA256)
      file(REMOVE "${PLEZY_WEBGPU_EP_WHEEL}")
    endif()
  endif()
  if(NOT EXISTS "${PLEZY_WEBGPU_EP_WHEEL}")
    message(STATUS "Downloading pinned ONNX Runtime WebGPU Plugin EP ${PLEZY_WEBGPU_EP_VERSION}")
    file(DOWNLOAD
      "${PLEZY_WEBGPU_EP_WHEEL_URL}"
      "${PLEZY_WEBGPU_EP_WHEEL}"
      EXPECTED_HASH "SHA256=${PLEZY_WEBGPU_EP_WHEEL_SHA256}"
      STATUS PLEZY_WEBGPU_EP_DOWNLOAD_STATUS
    )
    list(GET PLEZY_WEBGPU_EP_DOWNLOAD_STATUS 0 PLEZY_WEBGPU_EP_DOWNLOAD_RESULT)
    if(NOT PLEZY_WEBGPU_EP_DOWNLOAD_RESULT EQUAL 0)
      file(REMOVE "${PLEZY_WEBGPU_EP_WHEEL}")
      message(FATAL_ERROR "Could not download the verified WebGPU Plugin EP wheel: ${PLEZY_WEBGPU_EP_DOWNLOAD_STATUS}")
    endif()
  endif()

  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  execute_process(
    COMMAND "${Python3_EXECUTABLE}"
      "${CMAKE_CURRENT_LIST_DIR}/../../../scripts/motion/extract_webgpu_ep_wheel.py"
      "${PLEZY_WEBGPU_EP_WHEEL}"
      "${PLEZY_WEBGPU_EP_EXTRACT_DIR}"
      "${PLEZY_WEBGPU_EP_WHEEL_SHA256}"
    RESULT_VARIABLE PLEZY_WEBGPU_EP_EXTRACT_RESULT
    OUTPUT_VARIABLE PLEZY_WEBGPU_EP_EXTRACT_OUTPUT
    ERROR_VARIABLE PLEZY_WEBGPU_EP_EXTRACT_ERROR
  )
  if(NOT PLEZY_WEBGPU_EP_EXTRACT_RESULT EQUAL 0)
    message(FATAL_ERROR "Could not extract the pinned WebGPU Plugin EP wheel: ${PLEZY_WEBGPU_EP_EXTRACT_ERROR}")
  endif()

  set(PLEZY_WEBGPU_EP_PLUGIN "${PLEZY_WEBGPU_EP_EXTRACT_DIR}/libonnxruntime_providers_webgpu.so")
  if(NOT EXISTS "${PLEZY_WEBGPU_EP_PLUGIN}")
    message(FATAL_ERROR "The WebGPU Plugin EP wheel did not produce its provider library")
  endif()
  list(APPEND PME_PROVIDER_LIBRARIES "${PLEZY_WEBGPU_EP_PLUGIN}")
  list(APPEND PME_PROVIDER_NOTICE_FILES
    "${PLEZY_WEBGPU_EP_EXTRACT_DIR}/WebGPU-License.txt"
    "${PLEZY_WEBGPU_EP_EXTRACT_DIR}/WebGPU-ThirdPartyNotices.txt"
  )
  set(PME_LINUX_PROVIDER_MANIFEST "${CMAKE_CURRENT_LIST_DIR}/providers.linux.webgpu.tsv")
endif()

find_path(ONNXRUNTIME_INCLUDE_DIR
  NAMES onnxruntime_c_api.h
  HINTS
    "${ONNXRUNTIME_ROOT}/include"
    "${ONNXRUNTIME_ROOT}/include/winml"
    "$ENV{ONNXRUNTIME_ROOT}/include"
    "$ENV{ONNXRUNTIME_ROOT}/include/winml"
)
if(NOT ONNXRUNTIME_INCLUDE_DIR)
  message(FATAL_ERROR "ONNXRUNTIME_ROOT must point to an ONNX Runtime distribution with onnxruntime_c_api.h")
endif()

if(NOT PME_ORT_RUNTIME_LIBRARY)
  unset(PME_ORT_RUNTIME_LIBRARY CACHE)
  find_file(PME_ORT_RUNTIME_LIBRARY
    NAMES onnxruntime.dll libonnxruntime.so libonnxruntime.dylib
    HINTS
      "${ONNXRUNTIME_ROOT}/lib"
      "${ONNXRUNTIME_ROOT}/bin"
      "$ENV{ONNXRUNTIME_ROOT}/lib"
      "$ENV{ONNXRUNTIME_ROOT}/bin"
  )
endif()
if(NOT PME_ORT_RUNTIME_LIBRARY OR NOT EXISTS "${PME_ORT_RUNTIME_LIBRARY}")
  message(FATAL_ERROR "Set PME_ORT_RUNTIME_LIBRARY to the ONNX Runtime shared library")
endif()

foreach(provider_library IN LISTS PME_PROVIDER_LIBRARIES PME_PROVIDER_DEPENDENCY_LIBRARIES)
  if(NOT EXISTS "${provider_library}")
    message(FATAL_ERROR "ONNX Runtime provider runtime file does not exist: ${provider_library}")
  endif()
endforeach()

add_library(plezy_motion_engine SHARED pme_runtime.cpp)
if(WIN32)
  target_compile_features(plezy_motion_engine PRIVATE cxx_std_20)
else()
  target_compile_features(plezy_motion_engine PRIVATE cxx_std_17)
endif()
target_compile_definitions(plezy_motion_engine PRIVATE PME_RUNTIME_BUILD)
if(WIN32)
  target_compile_definitions(plezy_motion_engine PRIVATE PME_HAVE_WINML=1)
endif()
target_include_directories(plezy_motion_engine
  PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}"
  PRIVATE "${ONNXRUNTIME_INCLUDE_DIR}"
)
if(WIN32)
  target_include_directories(plezy_motion_engine PRIVATE "${WINML_INCLUDE_DIR}")
endif()
set_target_properties(plezy_motion_engine PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES
)
if(UNIX AND NOT APPLE)
  set_target_properties(plezy_motion_engine PROPERTIES INSTALL_RPATH "$ORIGIN")
endif()

if(CMAKE_DL_LIBS)
  target_link_libraries(plezy_motion_engine PRIVATE "${CMAKE_DL_LIBS}")
endif()
target_link_libraries(plezy_motion_engine PRIVATE Threads::Threads)
if(WIN32)
  target_link_libraries(plezy_motion_engine PRIVATE WindowsML::Api dxgi d3d12)
endif()

if(WIN32)
  set(PME_INSTALL_LIBDIR ".")
  set(PME_ORT_INSTALL_NAME "onnxruntime.dll")
elseif(APPLE)
  set(PME_INSTALL_LIBDIR "lib")
  set(PME_ORT_INSTALL_NAME "libonnxruntime.dylib")
else()
  set(PME_INSTALL_LIBDIR "lib")
  set(PME_ORT_INSTALL_NAME "libonnxruntime.so")
endif()

install(TARGETS plezy_motion_engine
  RUNTIME DESTINATION "${PME_INSTALL_LIBDIR}" COMPONENT Runtime
  LIBRARY DESTINATION "${PME_INSTALL_LIBDIR}" COMPONENT Runtime
  ARCHIVE DESTINATION lib COMPONENT Runtime
)
install(FILES pme_runtime.h DESTINATION include/plezy_motion_engine COMPONENT Runtime)
install(FILES "${PME_ORT_RUNTIME_LIBRARY}"
  DESTINATION "${PME_INSTALL_LIBDIR}"
  RENAME "${PME_ORT_INSTALL_NAME}"
  COMPONENT Runtime
)
if(UNIX AND NOT APPLE)
  # ONNX Runtime ships libonnxruntime.so as a symlink chain. Installing only
  # that entry leaves the bundle pointing at a missing .so.1 target, and the
  # shared provider interface library is needed when execution providers load.
  get_filename_component(PME_ORT_RUNTIME_DIRECTORY "${PME_ORT_RUNTIME_LIBRARY}" DIRECTORY)
  install(DIRECTORY "${PME_ORT_RUNTIME_DIRECTORY}/"
    DESTINATION "${PME_INSTALL_LIBDIR}"
    COMPONENT Runtime
    FILES_MATCHING
      PATTERN "libonnxruntime.so.*"
      PATTERN "libonnxruntime_providers_shared.so*"
  )
  install(FILES "${PME_ORT_LICENSE_FILE}"
    DESTINATION "${PME_INSTALL_LIBDIR}"
    RENAME "ONNXRuntime-License.txt"
    COMPONENT Runtime
    OPTIONAL
  )
  install(FILES "${PME_ORT_THIRD_PARTY_NOTICES_FILE}"
    DESTINATION "${PME_INSTALL_LIBDIR}"
    RENAME "ONNXRuntime-ThirdPartyNotices.txt"
    COMPONENT Runtime
    OPTIONAL
  )
endif()
if(WIN32)
  install(FILES
    "${WINML_BINARY_DIR}/Microsoft.Windows.AI.MachineLearning.dll"
    "${WINML_DIRECTML_DLL}"
    DESTINATION "${PME_INSTALL_LIBDIR}"
    COMPONENT Runtime
  )
  install(FILES "${PLEZY_WINML_PACKAGE_ROOT}/license.txt"
    DESTINATION "${PME_INSTALL_LIBDIR}"
    RENAME "WindowsML-License.txt"
    COMPONENT Runtime
  )
  install(FILES "${PLEZY_WINML_PACKAGE_ROOT}/ThirdPartyNotices.txt"
    DESTINATION "${PME_INSTALL_LIBDIR}"
    RENAME "WindowsML-ThirdPartyNotices.txt"
    COMPONENT Runtime
  )
endif()
if(PME_PROVIDER_LIBRARIES)
  install(FILES ${PME_PROVIDER_LIBRARIES}
    DESTINATION "${PME_INSTALL_LIBDIR}"
    COMPONENT Runtime
  )
endif()
if(PME_PROVIDER_DEPENDENCY_LIBRARIES)
  install(FILES ${PME_PROVIDER_DEPENDENCY_LIBRARIES}
    DESTINATION "${PME_INSTALL_LIBDIR}"
    COMPONENT Runtime
  )
endif()
if(PME_PROVIDER_NOTICE_FILES)
  install(FILES ${PME_PROVIDER_NOTICE_FILES}
    DESTINATION "${PME_INSTALL_LIBDIR}"
    COMPONENT Runtime
  )
endif()
if(PME_PROVIDER_RUNTIME_FILES)
  install(FILES ${PME_PROVIDER_RUNTIME_FILES}
    DESTINATION "${PME_INSTALL_LIBDIR}"
    COMPONENT Runtime
  )
endif()

if(WIN32)
  install(FILES providers.windows.tsv DESTINATION "${PME_INSTALL_LIBDIR}" COMPONENT Runtime)
elseif(UNIX AND NOT APPLE)
  install(FILES "${PME_LINUX_PROVIDER_MANIFEST}"
    DESTINATION "${PME_INSTALL_LIBDIR}"
    RENAME providers.linux.tsv
    COMPONENT Runtime
  )
endif()

if(PME_BUILD_RUNTIME_PROBE)
  add_executable(plezy_motion_runtime_probe
    "${CMAKE_CURRENT_LIST_DIR}/../../../scripts/motion/pme_runtime_probe.cpp"
  )
  target_compile_features(plezy_motion_runtime_probe PRIVATE cxx_std_17)
  target_include_directories(plezy_motion_runtime_probe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(plezy_motion_runtime_probe PRIVATE plezy_motion_engine)
  if(UNIX AND NOT APPLE)
    set_target_properties(plezy_motion_runtime_probe PROPERTIES INSTALL_RPATH "$ORIGIN/../lib")
    set(PME_PROBE_INSTALL_BINDIR bin)
  else()
    set(PME_PROBE_INSTALL_BINDIR "${PME_INSTALL_LIBDIR}")
  endif()
  install(TARGETS plezy_motion_runtime_probe
    RUNTIME DESTINATION "${PME_PROBE_INSTALL_BINDIR}"
    COMPONENT DevTools
  )
endif()

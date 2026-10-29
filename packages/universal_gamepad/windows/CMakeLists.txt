# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to be incompatible with some
# temporary versions of Flutter.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "universal_gamepad")
project(${PROJECT_NAME} LANGUAGES CXX)

# The plugin library target name must be "universal_gamepad_plugin" to match what
# Flutter's generated_plugins.cmake expects (plugin name + "_plugin").
set(PLUGIN_NAME "universal_gamepad_plugin")

# Invoke flutter tooling for plugin setup.
# This must be included before any other rules.
# It defines the flutter_plugin_add_* functions used below.
include(${EPHEMERAL_DIR}/generated_plugin_registrant.cmake OPTIONAL)

# Fetch SDL3 at build time (static library, no runtime DLL needed).
include(FetchContent)
FetchContent_Declare(
  SDL3
  GIT_REPOSITORY https://github.com/libsdl-org/SDL.git
  # Upstream release-3.2.8; immutable pin rather than a mutable release asset.
  GIT_TAG f6864924f76e1a0b4abaefc76ae2ed22b1a8916e
  GIT_SHALLOW FALSE
)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(SDL3)

# Define the plugin library target.
add_library(${PLUGIN_NAME} SHARED
  "gamepad_plugin.cpp"
  "gamepad_stream_handler.cpp"
  "sdl_manager.cpp"
  "button_mapping.cpp"
)

# Apply standard Flutter plugin settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. Explicitly export the plugin registration symbol.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  # Flutter event-channel headers stream unique_ptr error details (C++20).
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED ON
)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  SDL3::SDL3-static
)

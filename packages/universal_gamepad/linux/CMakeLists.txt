# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to be incompatible with some combintions of Flutter, Linux,
# and CMake versions.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "universal_gamepad")
project(${PROJECT_NAME} LANGUAGES C CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "universal_gamepad_plugin")

# Find required dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(EVDEV REQUIRED IMPORTED_TARGET libevdev)

# Define the plugin library target.
add_library(${PLUGIN_NAME} SHARED
  "gamepad_plugin.cc"
  "gamepad_stream_handler.cc"
  "evdev_manager.cc"
  "gamepad_effects.cc"
  "button_mapping.cc"
)

# Apply standard settings to the plugin library (symbol visibility, etc).
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of symbol collisions
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  CXX_STANDARD 17
)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::EVDEV)

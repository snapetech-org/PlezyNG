# The Flutter tooling requires that developers have CMake 3.10 or later
# installed.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "os_media_controls")
project(${PROJECT_NAME} LANGUAGES CXX)

# Set C++ standard to C++17 for better type safety and modern features
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "os_media_controls_plugin")

# Use pkg-config to find GLib and GIO libraries (required for GDBus)
find_package(PkgConfig REQUIRED)
pkg_check_modules(GLIB REQUIRED glib-2.0)
pkg_check_modules(GIO REQUIRED gio-2.0)
pkg_check_modules(GOBJECT REQUIRED gobject-2.0)

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "os_media_controls_plugin.cpp"
  "include/os_media_controls/os_media_controls_plugin.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  ${GLIB_INCLUDE_DIRS}
  ${GIO_INCLUDE_DIRS}
  ${GOBJECT_INCLUDE_DIRS})

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  ${GLIB_LIBRARIES}
  ${GIO_LIBRARIES}
  ${GOBJECT_LIBRARIES}
)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(os_media_controls_bundled_libraries
  ""
  PARENT_SCOPE
)

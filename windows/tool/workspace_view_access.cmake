# Expose a non-owning engine handle in the build-local C++ client wrapper.
# Every translation unit sees this same header after flutter_assemble.
if(NOT DEFINED HEADER OR NOT EXISTS "${HEADER}")
  message(FATAL_ERROR "Flutter client wrapper header missing")
endif()
file(READ "${HEADER}" content)
if(content MATCHES "PlezyNativeHandle")
  return()
endif()
set(anchor " private:\n  // For access to the engine handle.")
string(FIND "${content}" "${anchor}" position)
if(position LESS 0 OR NOT content MATCHES "FlutterDesktopEngineRef engine_ = nullptr")
  message(FATAL_ERROR "Review the changed Flutter engine wrapper before enabling workspace views")
endif()
string(REPLACE "${anchor}"
  "  FlutterDesktopEngineRef PlezyNativeHandle() const { return engine_; }\n\n${anchor}"
  content "${content}")
file(WRITE "${HEADER}" "${content}")

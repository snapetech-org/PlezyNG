cmake_minimum_required(VERSION 3.10)
project(plezy_visualizer_tv_helper LANGUAGES CXX)
find_package(Threads REQUIRED)
add_executable(plezy_visualizer_helper ../tv_helper.cc)
target_compile_features(plezy_visualizer_helper PRIVATE cxx_std_17)
target_link_libraries(plezy_visualizer_helper PRIVATE ${CMAKE_DL_LIBS} Threads::Threads)
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS 9)
  target_link_libraries(plezy_visualizer_helper PRIVATE stdc++fs)
endif()
set_target_properties(plezy_visualizer_helper PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  BUILD_WITH_INSTALL_RPATH ON
  INSTALL_RPATH "$ORIGIN")

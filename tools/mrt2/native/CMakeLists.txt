# Build mrt_render on upstream magentart::core, against the prebuilt MLX from the mlx-metal wheel
# instead of upstream's from-source MLX, which needs Xcode's separate Metal Toolchain.
# Configured by tools/mrt2/mrt2.py, which passes MLX_DIR, MAGENTA_SRC and MAGENTA_SHA.
cmake_minimum_required(VERSION 3.27)

set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version" FORCE)
project(mrt_native LANGUAGES C CXX OBJCXX)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE "Release" CACHE STRING "" FORCE)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(ABSL_INTERNAL_AT_LEAST_CXX20 ON CACHE BOOL "Force Abseil C++20 support")
set(ABSL_PROPAGATE_CXX_STD ON)

set(MAGENTA_SRC "" CACHE PATH "Checkout of github.com/magenta/magenta-realtime")
if(NOT EXISTS "${MAGENTA_SRC}/core/CMakeLists.txt")
  message(FATAL_ERROR "MAGENTA_SRC must point at a magenta-realtime checkout")
endif()

add_definitions(-DMAGENTART_VERSION="0.0.1" -DMAGENTART_GIT_SHA="${MAGENTA_SHA}")

# The wheel's mlx.metallib sits next to libmlx.dylib, where MLX looks for it at runtime.
find_package(MLX CONFIG REQUIRED)

include(FetchContent)

# SentencePiece and TFLite exactly as upstream's root CMakeLists.txt fetches them.
FetchContent_Declare(
  sentencepiece
  GIT_REPOSITORY https://github.com/google/sentencepiece.git
  GIT_TAG        v0.2.0
  GIT_SHALLOW    ON
)
set(SPM_ENABLE_SHARED OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(sentencepiece)

FetchContent_Declare(
  tensorflow-lite
  GIT_REPOSITORY https://github.com/tensorflow/tensorflow.git
  GIT_TAG        v2.21.0
  SOURCE_SUBDIR  tensorflow/lite
  GIT_SHALLOW    ON
)
set(TFLITE_ENABLE_XNNPACK OFF CACHE BOOL "" FORCE)
set(TFLITE_ENABLE_GPU OFF CACHE BOOL "" FORCE)
set(TFLITE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
# Without this TFLite clones a second, older TensorFlow and the FlatBuffers versions clash.
set(FETCHCONTENT_SOURCE_DIR_TENSORFLOW "${CMAKE_BINARY_DIR}/_deps/tensorflow-lite-src" CACHE PATH "" FORCE)
FetchContent_MakeAvailable(tensorflow-lite)

add_subdirectory("${MAGENTA_SRC}/core" core)

add_executable(mrt_render mrt_render.cpp)
target_link_libraries(mrt_render PRIVATE magentart::core)
# The pack installs libmlx.dylib and mlx.metallib beside the binary; without
# this CMake would bake in the build venv's path instead.
set_target_properties(mrt_render PROPERTIES SKIP_BUILD_RPATH ON)
target_link_options(mrt_render PRIVATE "-Wl,-rpath,@executable_path")

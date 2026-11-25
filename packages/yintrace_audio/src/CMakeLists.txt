# Builds the native audio core for Android, Windows and Linux.
# Apple platforms build it through CocoaPods (see ios/ and macos/).
cmake_minimum_required(VERSION 3.10)

project(yintrace_audio_library VERSION 0.1.0 LANGUAGES C)

add_library(yintrace_audio SHARED
  "yt_audio.c"
)

set_target_properties(yintrace_audio PROPERTIES
  PUBLIC_HEADER yt_audio.h
  OUTPUT_NAME "yintrace_audio"
  C_STANDARD 11
)

target_compile_definitions(yintrace_audio PUBLIC DART_SHARED_LIB)

if (NOT WIN32)
  target_compile_options(yintrace_audio PRIVATE -O2 -fvisibility=hidden)
endif()

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(yintrace_audio PRIVATE "-Wl,-z,max-page-size=16384")
  # mediandk: AAC (m4a) and other formats miniaudio does not decode.
  target_link_libraries(yintrace_audio PRIVATE m dl log mediandk)
elseif (UNIX AND NOT APPLE)
  find_package(Threads REQUIRED)
  target_link_libraries(yintrace_audio PRIVATE m dl Threads::Threads)
endif()

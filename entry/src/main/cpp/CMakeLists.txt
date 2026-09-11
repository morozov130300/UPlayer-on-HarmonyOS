cmake_minimum_required(VERSION 3.5.0)
project(UPlayerNative)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})

add_library(uplayer SHARED napi_init.cpp)

target_include_directories(uplayer PRIVATE ${NATIVE_ROOT})

target_link_libraries(uplayer PUBLIC
  libace_napi.z.so
  libhilog_ndk.z.so
  libohaudio.so
  libohaudiosuite.so
  libnative_media_codecbase.so
  libnative_media_core.so
  libnative_media_acodec.so
  libnative_media_avdemuxer.so
  libnative_media_avsource.so
)

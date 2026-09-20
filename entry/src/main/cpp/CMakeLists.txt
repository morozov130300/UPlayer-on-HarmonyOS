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

# 体积裁剪：函数/数据分节 + 链接期回收未引用段（--gc-sections），并对内联函数合并去重。
# 只回收「确实没人引用的段」，不改变可执行语义；符号可见性保持默认，避免影响 NAPI 模块注册。
target_compile_options(uplayer PRIVATE -ffunction-sections -fdata-sections -fmerge-all-constants)
target_link_options(uplayer PRIVATE -Wl,--gc-sections)

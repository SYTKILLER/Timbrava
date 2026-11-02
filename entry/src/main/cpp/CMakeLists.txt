cmake_minimum_required(VERSION 3.5.0)
project(timbrava_core)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(timbrava_core SHARED
            timbrava_napi.cpp
            src/dsp.cpp
            src/engine.cpp
            src/flac_decoder.cpp
            src/wav_decoder.cpp
            src/audio_output.cpp)

target_link_libraries(timbrava_core PUBLIC libohaudio.so libhilog_ndk.z.so libace_napi.z.so)

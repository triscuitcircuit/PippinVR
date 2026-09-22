cmake_minimum_required(VERSION 3.22.1)
project(pippinvr_client C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(native_app_glue STATIC
    ${ANDROID_NDK}/sources/android/native_app_glue/android_native_app_glue.c)
target_include_directories(native_app_glue PUBLIC
    ${ANDROID_NDK}/sources/android/native_app_glue)

find_package(OpenXR REQUIRED CONFIG)
include(FetchContent)
FetchContent_Declare(
    glm
    GIT_REPOSITORY https://github.com/g-truc/glm.git
    GIT_TAG 1.0.1
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(glm)

FetchContent_Declare(
    soil2
    GIT_REPOSITORY https://github.com/SpartanJ/SOIL2.git
    GIT_TAG 1.31
    GIT_SHALLOW TRUE
)
FetchContent_GetProperties(soil2)

if(NOT soil2_POPULATED)
    FetchContent_Populate(soil2)
endif()

add_library(soil2 STATIC
    ${soil2_SOURCE_DIR}/src/SOIL2/SOIL2.c
    ${soil2_SOURCE_DIR}/src/SOIL2/image_DXT.c
    ${soil2_SOURCE_DIR}/src/SOIL2/image_helper.c
    ${soil2_SOURCE_DIR}/src/SOIL2/wfETC.c
)
target_include_directories(soil2 PUBLIC ${soil2_SOURCE_DIR}/src)

target_compile_options(soil2 PRIVATE -w)
target_link_libraries(soil2 PUBLIC GLESv2 EGL)

add_library(pippinvr_client SHARED
    main.cpp
    XrApp.cpp
    Renderer.cpp
    Background.cpp
    Input.cpp
    Net.cpp
    Decoder.cpp
)

target_compile_definitions(pippinvr_client PRIVATE
    XR_USE_PLATFORM_ANDROID
    XR_USE_GRAPHICS_API_OPENGL_ES
)

target_link_options(pippinvr_client PRIVATE -u ANativeActivity_onCreate)

target_link_libraries(pippinvr_client
    native_app_glue
    OpenXR::openxr_loader
    glm::glm
    soil2
    android
    nativewindow
    mediandk
    EGL
    GLESv3
    log
)

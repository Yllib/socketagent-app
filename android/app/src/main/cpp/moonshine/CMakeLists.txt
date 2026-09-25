cmake_minimum_required(VERSION 3.22.1)
project(moonshine_ort_compat C)

# Only ARM64 needs the newer runtime. Other ABIs retain Moonshine's runtime.
if(ANDROID_ABI STREQUAL "arm64-v8a")
    add_library(moonortnext SHARED IMPORTED)
    set_target_properties(moonortnext PROPERTIES IMPORTED_LOCATION
        "${MOONSHINE_ORT_DIR}/arm64-v8a/libmoonortnext.so")
    add_library(moonruntime SHARED ort_compat.c)
    target_link_libraries(moonruntime PRIVATE moonortnext)
    target_link_options(moonruntime PRIVATE
        "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/ort_compat.map"
        "-Wl,-z,max-page-size=16384")
    set_property(TARGET moonruntime APPEND PROPERTY LINK_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/ort_compat.map")
endif()

cmake_minimum_required(VERSION 3.22.1)
project(openzcine_live_feed_vk)

add_library(openzcine_live_feed_vk SHARED
    live_feed_vk_jni.cpp
    live_feed_vk_renderer.cpp
)

find_library(log-lib log)
find_library(android-lib android)
find_library(vulkan-lib vulkan)
find_library(jnigraphics-lib jnigraphics)

target_compile_features(openzcine_live_feed_vk PRIVATE cxx_std_17)
target_compile_options(openzcine_live_feed_vk PRIVATE -Wall -Wextra -fno-exceptions -fno-rtti)
target_link_libraries(openzcine_live_feed_vk
    ${log-lib}
    ${android-lib}
    ${vulkan-lib}
    ${jnigraphics-lib}
)

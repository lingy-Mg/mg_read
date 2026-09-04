# Windows WebView2 host for the private browser.session.v1 bridge.
cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "mgread_plugin_runtime")
project(${PROJECT_NAME} LANGUAGES CXX)
cmake_policy(VERSION 3.14...3.25)
if(POLICY CMP0169)
  cmake_policy(SET CMP0169 OLD)
endif()

set(PLUGIN_NAME "mgread_plugin_runtime_plugin")
include(FetchContent)
FetchContent_Declare(
  mgread_webview2_sdk
  URL "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.4129.50"
  URL_HASH "SHA256=D3934F482D484B89FB4825DF720C710664E1143A1E90F7B3A60794EF33F473D2"
)
FetchContent_GetProperties(mgread_webview2_sdk)
if(NOT mgread_webview2_sdk_POPULATED)
  FetchContent_Populate(mgread_webview2_sdk)
endif()
set(WEBVIEW2_NATIVE "${mgread_webview2_sdk_SOURCE_DIR}/build/native")

add_library(${PLUGIN_NAME} SHARED
  "include/mgread_plugin_runtime/mgread_plugin_runtime_plugin_c_api.h"
  "mgread_plugin_runtime_plugin_c_api.cpp"
  "mgread_plugin_runtime_plugin.cpp"
  "mgread_plugin_runtime_plugin.h"
  "windows_browser_host.cpp"
  "windows_browser_host.h"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
target_compile_options(${PLUGIN_NAME} PRIVATE /utf-8)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE "${WEBVIEW2_NATIVE}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  "${WEBVIEW2_NATIVE}/x64/WebView2LoaderStatic.lib"
  ole32
  user32
)

set(mgread_plugin_runtime_bundled_libraries "" PARENT_SCOPE)

# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(mg_read LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "mg_read")

# Native-only packaging stages the Rust host beside the app and removes the
# legacy Runtime assets from the installed Flutter asset tree. Flutter encodes
# Dart defines as base64 in generated_config.cmake, so derive this mode from the
# same --dart-define used by the Facade instead of retaining a CMake cache flag.
set(MGREAD_NATIVE_RUNTIME OFF)
set(MGREAD_NATIVE_RUNTIME_DEFINE "TUdSRUFEX05BVElWRV9SVU5USU1FPXRydWU=")
set(MGREAD_GENERATED_CONFIG
  "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/generated_config.cmake")
if(EXISTS "${MGREAD_GENERATED_CONFIG}")
  file(STRINGS "${MGREAD_GENERATED_CONFIG}" MGREAD_NATIVE_DEFINE_LINES
    REGEX "DART_DEFINES=.*${MGREAD_NATIVE_RUNTIME_DEFINE}")
  if(MGREAD_NATIVE_DEFINE_LINES)
    set(MGREAD_NATIVE_RUNTIME ON)
  endif()
endif()
get_filename_component(MGREAD_REPOSITORY_ROOT
  "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(MGREAD_NATIVE_HOST_EXECUTABLE
  "${MGREAD_REPOSITORY_ROOT}/packages/mg_read_native_runtime/dist/windows-x86_64/mgread-native-host.exe"
  CACHE FILEPATH "Built native Runtime host executable")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} ${BINARY_NAME}_cli RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

if(MGREAD_NATIVE_RUNTIME)
  if(NOT EXISTS "${MGREAD_NATIVE_HOST_EXECUTABLE}")
    message(FATAL_ERROR
      "MGREAD_NATIVE_RUNTIME requires the Rust host at "
      "${MGREAD_NATIVE_HOST_EXECUTABLE}. Build it before packaging.")
  endif()
  install(FILES "${MGREAD_NATIVE_HOST_EXECUTABLE}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/native"
    RENAME "mgread-native-host.exe"
    COMPONENT Runtime)
  install(CODE
    "file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}/packages/mgread_plugin_runtime/assets/runtime\")"
    COMPONENT Runtime)
else()
  install(CODE
    "file(REMOVE \"${INSTALL_BUNDLE_LIB_DIR}/native/mgread-native-host.exe\")"
    COMPONENT Runtime)
endif()

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

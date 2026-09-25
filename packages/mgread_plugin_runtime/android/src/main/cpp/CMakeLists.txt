cmake_minimum_required(VERSION 3.22)
project(mgread_node_bridge LANGUAGES CXX)

add_library(mgread_node_bridge SHARED mgread_node_bridge.cpp)
target_compile_features(mgread_node_bridge PRIVATE cxx_std_17)
target_compile_options(mgread_node_bridge PRIVATE -Wall -Wextra -Werror)
target_link_libraries(mgread_node_bridge PRIVATE dl)

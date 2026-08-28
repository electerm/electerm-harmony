cmake_minimum_required(VERSION 3.5.0)
project(electerm_web_runtime)

# libnode_launcher.so — loaded into the native child process; its Main()
# execv()s the bundled node binary (installed as libnode.so).
add_library(node_launcher SHARED node_launcher.c)
target_link_libraries(node_launcher PUBLIC libchild_process.so)

# libnode_ctl.so — NAPI module for the main (ArkTS) process: kill the node
# child by pid on app destroy.
add_library(node_ctl SHARED node_ctl.c)
target_link_libraries(node_ctl PUBLIC libace_napi.z.so)

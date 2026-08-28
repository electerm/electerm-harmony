cmake_minimum_required(VERSION 3.5.0)
project(electerm_web_runtime)

# libnode_launcher.so — loaded into the native child process; its Main()
# execv()s the bundled node binary (installed as libnode.so).
add_library(node_launcher SHARED node_launcher.c)
# libhilog_ndk.z.so — native hilog so launcher diagnostics survive release
# builds even when the boot-log file cannot be pulled (cloud debug)
target_link_libraries(node_launcher PUBLIC libchild_process.so libhilog_ndk.z.so)

# libnode_ctl.so — NAPI module for the main (ArkTS) process: run node
# IN-PROCESS (dlopen libnode.so + node::Start — the electron-harmony /
# nodejs-mobile pattern) and kill the spawned child by pid on app destroy.
# -fno-omit-frame-pointer: backtrace() in the crash marker walks the fp chain.
add_library(node_ctl SHARED node_ctl.c)
target_compile_options(node_ctl PRIVATE -fno-omit-frame-pointer)
target_link_libraries(node_ctl PUBLIC libace_napi.z.so libhilog_ndk.z.so)

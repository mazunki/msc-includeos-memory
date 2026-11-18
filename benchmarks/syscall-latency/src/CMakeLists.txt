cmake_minimum_required(VERSION 3.31.6)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

project(syscall_latency C)

enable_language(CXX)
find_package(IncludeOS REQUIRED)
include(os)

add_definitions(-DINCLUDEOS)
os_add_executable(syscall_latency "Syscall latency benchmark" main.c)
os_add_drivers(syscall_latency virtionet vmxnet3 boot_logger)
os_add_stdout(syscall_latency default_stdout)

set(BINARY_NAME syscall_latency)
set(ELF_TARGET ${BINARY_NAME}${ELF_POSTFIX})
install(TARGETS ${ELF_TARGET} DESTINATION bin)

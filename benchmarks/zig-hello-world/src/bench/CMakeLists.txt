cmake_minimum_required(VERSION 3.31.6)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

project(zig_hello_world)

find_program(ZIG_EXECUTABLE zig REQUIRED)
find_package(IncludeOS REQUIRED)
include(os)

add_custom_command(OUTPUT hello.o
  COMMAND ${ZIG_EXECUTABLE} build-obj -target x86_64-linux-musl -O ReleaseFast -lc
          -femit-bin=${CMAKE_CURRENT_BINARY_DIR}/hello.o
          ${CMAKE_CURRENT_SOURCE_DIR}/hello.zig
  DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/hello.zig
          ${CMAKE_CURRENT_SOURCE_DIR}/includeos-allocator.zig
  COMMENT "compiling hello.zig -> hello.o")

add_custom_target(hello_obj DEPENDS hello.o)

set_source_files_properties(hello.o PROPERTIES
  EXTERNAL_OBJECT true
  GENERATED true)

set(BINARY_NAME hello_includeos)
set(ELF_TARGET ${BINARY_NAME}${ELF_POSTFIX})

os_add_executable(${BINARY_NAME} "zig <-> includeos hello world" main.cpp zig_alloc_shim.cpp hello.o)
os_add_drivers(${BINARY_NAME} boot_logger)
os_add_stdout(${BINARY_NAME} default_stdout)

add_dependencies(${ELF_TARGET} hello_obj)

install(TARGETS ${ELF_TARGET} DESTINATION bin)

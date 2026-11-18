cmake_minimum_required(VERSION 3.31.6)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

project(allocator_path)

find_program(ZIG_EXECUTABLE zig REQUIRED)

if (INCLUDEOS_PACKAGE)
  message(STATUS "IncludeOS maxxing")
  find_package(IncludeOS REQUIRED)
  include(os)
else()
  message(STATUS "Linux maxxing")
endif()

set(BENCH_SIZE "" CACHE STRING "allocation size in bytes to benchmark (mandatory)")
if (BENCH_SIZE STREQUAL "")
  message(FATAL_ERROR "BENCH_SIZE must be set, e.g. -DBENCH_SIZE=65536")
endif()

add_custom_command(OUTPUT allocator_path.o
  COMMAND ${ZIG_EXECUTABLE} build-obj -target x86_64-linux-musl -O ReleaseFast -lc
          -femit-bin=${CMAKE_CURRENT_BINARY_DIR}/allocator_path.o
          ${CMAKE_CURRENT_SOURCE_DIR}/allocator_path.zig
  DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/allocator_path.zig
          ${CMAKE_CURRENT_SOURCE_DIR}/includeos-allocator.zig
          ${CMAKE_CURRENT_SOURCE_DIR}/posix-allocator.zig
          ${CMAKE_CURRENT_SOURCE_DIR}/tsc.zig
          ${CMAKE_CURRENT_SOURCE_DIR}/jq_bench.zig
          ${CMAKE_CURRENT_SOURCE_DIR}/jq/json.zig
          ${CMAKE_CURRENT_SOURCE_DIR}/jq/parser.zig
          ${CMAKE_CURRENT_SOURCE_DIR}/jq/query.zig
          ${CMAKE_CURRENT_SOURCE_DIR}/jq/root.zig
  COMMENT "Compiling allocator_path.zig -> allocator_path.o")

add_custom_target(allocator_path_obj DEPENDS allocator_path.o)

set_source_files_properties(allocator_path.o PROPERTIES
  EXTERNAL_OBJECT true
  GENERATED true)

if (INCLUDEOS_PACKAGE)
  foreach(ALLOCATOR posix includeos)
    foreach(WORKLOAD batched interleaved fill interleaved_fill jq_count jq_size)
      foreach(LANG zig cpp)
        if ((WORKLOAD STREQUAL "jq_count" OR WORKLOAD STREQUAL "jq_size") AND LANG STREQUAL "cpp")
          continue()
        endif()
        string(TOUPPER ${ALLOCATOR} ALLOCATOR_UPPER)
        string(TOUPPER ${WORKLOAD} WORKLOAD_UPPER)
        string(TOUPPER ${LANG} LANG_UPPER)
        set(BINARY_NAME allocator_path_${ALLOCATOR}_${WORKLOAD}_${LANG})
        set(ELF_TARGET ${BINARY_NAME}${ELF_POSTFIX})

        os_add_executable(${BINARY_NAME} "zig <-> includeos allocator path (${ALLOCATOR}/${WORKLOAD}/${LANG})" main.cpp zig_alloc_shim.cpp cpp_baseline.cpp randomizer.c allocator_path.o)
        os_add_drivers(${BINARY_NAME} boot_logger)
        os_add_stdout(${BINARY_NAME} default_stdout)

        add_dependencies(${ELF_TARGET} allocator_path_obj)
        target_compile_definitions(${ELF_TARGET} PRIVATE
          BENCH_SIZE=${BENCH_SIZE}
          BENCH_ALLOCATOR_${ALLOCATOR_UPPER}
          BENCH_WORKLOAD_${WORKLOAD_UPPER}
          BENCH_LANG_${LANG_UPPER})

        install(TARGETS ${ELF_TARGET} DESTINATION bin)
      endforeach()
    endforeach()
  endforeach()
else()
  add_executable(allocator_path_linux main.cpp cpp_baseline.cpp randomizer.c allocator_path.o)
  add_dependencies(allocator_path_linux allocator_path_obj)
  target_compile_definitions(allocator_path_linux PRIVATE LINUX=1
    BENCH_SIZE=${BENCH_SIZE}
    BENCH_ALLOCATOR_INCLUDEOS
    BENCH_WORKLOAD_BATCHED
    BENCH_LANG_ZIG)

  set(BINARY_NAME allocator_path_linux)
  set(ELF_TARGET ${BINARY_NAME}${ELF_POSTFIX})

  install(TARGETS ${ELF_TARGET} DESTINATION bin)
endif()

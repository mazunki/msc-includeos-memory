cmake_minimum_required(VERSION 3.10)

set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

project(hello_world)
set(CMAKE_CXX_STANDARD 23)

option(ON_LINUX "Build host Linux binary instead of IncludeOS" OFF)
option(NATIVE_MALLOC "use system malloc() instead of custom allocator" OFF)

if(NOT ON_LINUX)
  find_package(IncludeOS REQUIRED)
  include(os)

  os_add_executable(hello "Hello world - OS included" main.cpp)
  os_add_stdout(hello default_stdout)

  set(ELF_SYMBOLS true)
  set(BINARY_NAME hello)
  set(ELF_TARGET ${BINARY_NAME}${ELF_POSTFIX})

  install(TARGETS ${ELF_TARGET} DESTINATION bin)
  target_compile_definitions(${ELF_TARGET}
    PRIVATE $<$<BOOL:${NATIVE_MALLOC}>:NATIVE_MALLOC>
  )
else()
  add_executable(hello main.cpp)
  target_compile_definitions(hello PRIVATE ON_LINUX=1)
  target_link_options(hello PRIVATE -static)

  install(TARGETS hello DESTINATION bin)
  target_compile_definitions(hello
    PRIVATE $<$<BOOL:${NATIVE_MALLOC}>:NATIVE_MALLOC>
  )
endif()


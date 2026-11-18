#pragma once
#include <cstddef>

extern "C" {
  void* includeos_zig_alloc(size_t len, size_t alignment);
  void includeos_zig_free(void* ptr, size_t len, size_t alignment);
}

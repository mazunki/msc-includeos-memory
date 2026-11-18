#include "zig_alloc_shim.hpp"

#include <exception>
#include <kernel/memory.hpp>

// exceptions mustn't leave c++

extern "C" void* includeos_zig_alloc(size_t len, size_t alignment) {
  try {
    return os::mem::raw_allocator().allocate(len, alignment);
  } catch (const std::exception&) {
    return nullptr;
  }
}

extern "C" void includeos_zig_free(void* ptr, size_t len, size_t alignment) {
  if (ptr == nullptr) return;
  os::mem::raw_allocator().deallocate(ptr, len, alignment);
}

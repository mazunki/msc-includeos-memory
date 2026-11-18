#include <cstddef>
#include <cstdint>
#include <algorithm>
#include <new>

// #include <mem/alloc/buddy.hpp>
#include <sys/mman.h>

struct includeos_buddy_stub {
  // using Alloc  = os::mem::buddy::Alloc<false>;
  // using Policy = Alloc::Policy;

  // Alloc* a = nullptr;

  includeos_buddy_stub(mem_config cfg) {
    return;
    /*
    auto start = reinterpret_cast<void*>(cfg.region.start);
    auto buf   = static_cast<size_t>(cfg.region.end - cfg.region.start);

    if (cfg.overbooking) {
      a = Alloc::create<Policy::overbook>(start, buf);
    } else {
      a = Alloc::create<Policy::underbook>(start, buf);
    }
    if (!a) throw std::bad_alloc();
    */
  }

  uintptr_t malloc(size_t sz) {
    constexpr size_t A = alignof(std::max_align_t);
    sz = round_up(sz, A);

    // void* p = a->allocate(sz);
    // void* p = std::malloc(sz);
    void *p = mmap(nullptr, sz, PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0);
    if (!p) throw std::bad_alloc();
    return reinterpret_cast<uintptr_t>(p);
  }

  void free(uintptr_t addr, size_t sz) noexcept {
    if (!addr) return;
    constexpr size_t A = alignof(std::max_align_t);
    sz = round_up(sz, A);

    // a->deallocate(reinterpret_cast<void*>(addr), sz);
    // std::free(reinterpret_cast<void*>(addr));
    munmap(reinterpret_cast<void*>(addr), sz);
  }

private:
  static size_t round_up(size_t n, size_t a) noexcept {
    return (a <= 1) ? n : ((n + (a - 1)) & ~(a - 1));
  }
};


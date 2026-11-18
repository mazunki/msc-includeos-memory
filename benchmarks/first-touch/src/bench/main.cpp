#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>
#include <tuple>
#include <print>
#include <random>

#include <cstdio>
#include <print>
#include <sys/mman.h>
#ifndef ON_LINUX
#include <os>
#endif

#include "buddy.hpp"
#include "profile.cpp"
#ifdef NATIVE_MALLOC
#include "includeos_buddy_stub.hpp"
#endif

typedef std::tuple<uintptr_t, size_t> allocation_t;

#include <random>

struct rng_t {
  std::mt19937_64 rng_algo;

  explicit rng_t(uint64_t seed)
    : rng_algo(seed) {}

  // uniform [0,1)
  double dice() {
    return (rng_algo() >> 11) * (1.0 / (1ULL << 53)); // [0,1)
  }

  // uniform integer [min, max]
  static inline uint64_t mulhi_u64(uint64_t a, uint64_t b) {
    __uint128_t p = ( __uint128_t)a * b;
    return (uint64_t)(p >> 64);
  }

  size_t between(size_t min, size_t max) {
    uint64_t span = (uint64_t)(max - min + 1);
    uint64_t r = rng_algo();
    uint64_t v = mulhi_u64(r, span);   // unbiased mapping for uniform r
    return (size_t)(min + v);
  }

  /* pareto implementation which avoids pow()
   * alpha = how often we grow exponent
   * smaller alpha => heavier tail. i.e. more big numbers
   */
  size_t allocation_size(size_t min_size, size_t max_size, double alpha) {
    double p = std::exp(-alpha); // or tune manually

    // convert p to fixed-point
    uint64_t p_fp = (uint64_t)(p * (double)UINT64_MAX);

    size_t size = min_size;
    while (size < max_size) {
      if (rng_algo() > p_fp) break; // stop growing
      size <<= 1;
    }

    // add mantissa within the last octave for "continuous" feel
    // pick in [size, min(2*size, max_size)]
    size_t hi = size < (max_size >> 1) ? (size << 1) : max_size;
    return between(size, hi);
  }
};

template <typename strat_allocator>
bool test_allocator(strat_allocator& bud, const uint64_t seed) {
  std::vector<allocation_t> allocations;

  alloc_profile prof;
  profiled_buddy<strat_allocator> pb{bud, prof};

  rng_t rng{/*seed=*/seed};

  try {
    while (true) {
      bool do_alloc = (allocations.empty()) || ((rng.rng_algo() % 1000) >= 300);

      if (do_alloc) {
        size_t alloc_size = rng.allocation_size(4096, 1<<25, 0.1);

        uintptr_t addr = pb.malloc(alloc_size);
        if (!addr) {
          std::println("malloc failed at size={} (allocations={}):)", alloc_size, allocations.size());
          throw std::bad_alloc{};
        }
        pb.touch(addr, alloc_size);
        allocations.push_back({addr, alloc_size});
      } else {
        auto i = rng.between(0, allocations.size()-1);
        auto [addr, sz] = allocations.at(i);
        pb.free(addr, sz);
        allocations.erase(allocations.begin() + i);
      }
    }
  } catch (const std::bad_alloc&) {
    std::println("full! {} allocations", allocations.size());
  }

  std::ranges::sort(allocations);
  bool ok = true;
  for (size_t i = 1; i < allocations.size(); i++) {
    auto [a0, sz0] = allocations.at(i-1);
    pb.touch_random(a0, sz0);

    auto [a1, sz1] = allocations.at(i);

    if ((a0 + sz0) > a1) {
      std::println("bad alloc at 0x{:#x} (+{} bytes) (overlaps with 0x{:#x} @ {} bytes)",
                   a0, sz0, a1, sz1);
      ok = false;
      break;
    }
  }

  for (size_t i = 0; i < allocations.size(); i++) {
    auto [addr, sz] = allocations.at(i);
    pb.free(addr, sz);
    allocations.erase(allocations.begin() + i);
  }

  prof.report();
  prof.dump_csv();

  return ok;
}



#ifdef NATIVE_MALLOC
void run_includeos(mem_config& cfg, uint64_t seed) {
  includeos_buddy_stub buddy(cfg);

  std::println("starting includeos test (seed={})", seed);
  if (test_allocator(buddy, seed)) std::println("ok!");
  else std::println("bad allocator!");
}
#else
void run(mem_config& cfg, uint64_t seed) {
    buddy_resource buddy(cfg, {.min_block=16});
    buddy.dump_state();

    std::println("starting test (seed={})", seed);
    if(test_allocator(buddy, seed)) {
      std::println("ok!");
    } else {
      std::println("bad allocator!");
    };

    std::println("test finished");
    buddy.dump_state();
}
#endif

int main() {
  int64_t seeds[] = {0xDEAD'BEEF, 0x8000'085, 0xCAFE'F00D, 0x1BAD'B002, 0x2BAD'B002};
  for (size_t i=0; i < sizeof(seeds)/sizeof(*seeds); i++) {
    int64_t seed = seeds[i];
  
#ifdef NATIVE_MALLOC
  std::println("testing with native malloc!");
  mem_config cfg{};  // just for function symmetry, not used
  run_includeos(cfg, seed);
#else
  std::printf("testing with custom allocator!\n");
  size_t sz = 1 << 30; // 2^25 = 32 MiB, 2^30 = 1GiB
  void *p = mmap(nullptr, sz, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);

  auto start = reinterpret_cast<uintptr_t>(p);
  auto end = start + sz;

  mem_config cfg{
    .region = mem_region{ .start=start, .end=end },
    .overbooking = false,
  };
  run(cfg, seed);

  munmap(p, sz);
#endif
}

  std::println();
#ifndef ON_LINUX
  os::shutdown();
  os::halt();
#endif
}

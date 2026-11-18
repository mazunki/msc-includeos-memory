#include "buddy.hpp"
#include <chrono>
#include <cstdint>
#include <cstring>
#include <print>
#include <unordered_map>
#include <vector>
#include <algorithm>

struct trace_row {
  uint64_t seq;        // monotonic counter
  uint64_t t_ns;       // timestamp since start
  uint64_t dt_ns;      // duration of call
  uintptr_t addr;      // returned / freed address
  uint64_t size;       // requested size
  uint8_t op;          // 0 = malloc, 1 = free
  uint64_t repeats;    // how many times it was looped
};

struct alloc_profile {
  uint64_t seq = 0;
  uint64_t t0_ns = 0;
  std::vector<trace_row> trace;

  // counters
  uint64_t alloc_calls = 0;
  uint64_t free_calls  = 0;

  uint64_t bytes_alloc_req = 0;
  uint64_t bytes_freed     = 0;

  uint64_t live_bytes = 0;
  uint64_t peak_live_bytes = 0;

  uint64_t malloc_ns = 0;  // total
  uint64_t free_ns   = 0;

  // buckets of allocations, just used for summary
  std::vector<uint64_t> size_buckets = std::vector<uint64_t>(32, 0);

  // track live allocations (detect double free / wrong size)
  std::unordered_map<uintptr_t, size_t> live_allocations;

  static int bucket_for(size_t n) {
    if (n == 0) return 0;
    int b = 0;
    while (n > 1) { n >>= 1; b++; }
    return std::min(b, 31);
  }

  void on_alloc(uintptr_t addr, size_t sz, uint64_t dt_ns) {
    alloc_calls++;
    bytes_alloc_req += sz;
    live_bytes += sz;
    peak_live_bytes = std::max(peak_live_bytes, live_bytes);
    malloc_ns += dt_ns;

    size_buckets[bucket_for(sz)]++;
    live_allocations.emplace(addr, sz);
  }

  void on_free(uintptr_t addr, size_t sz, uint64_t dt_ns) {
    free_calls++;
    bytes_freed += sz;
    live_bytes -= sz;
    free_ns += dt_ns;

    auto it = live_allocations.find(addr);
    if (it == live_allocations.end()) {
      std::println("WARN: free of unknown addr {:#x} (sz passed={})", addr, sz);
    } else if (it->second != sz) {
      std::println("WARN: free size mismatch at {:#x}: tracked={} passed={}", addr, it->second, sz);
    } else {
      live_allocations.erase(it);
    }
  }

  void report() const {
    std::println("\n=== allocation profile ===");
    std::println("alloc calls: {}", alloc_calls);
    std::println("free calls : {}", free_calls);
    std::println("bytes requested : {}", bytes_alloc_req);
    std::println("bytes freed     : {}", bytes_freed);
    std::println("live bytes      : {}", live_bytes);
    std::println("peak live bytes : {}", peak_live_bytes);

    auto avg_malloc = alloc_calls ? (double)malloc_ns / (double)alloc_calls : 0.0;
    auto avg_free   = free_calls  ? (double)free_ns   / (double)free_calls  : 0.0;
    std::println("malloc total ns: {} (avg {:.1f} ns)", malloc_ns, avg_malloc);
    std::println("free total ns  : {} (avg {:.1f} ns)", free_ns, avg_free);

    std::println("live allocations still tracked: {}", live_allocations.size());

    std::println("\nsize histogram (pow2 buckets):");
    for (int i = 0; i < (int)size_buckets.size(); i++) {
      if (size_buckets[i] == 0) continue;
      if (i == 0) std::println("  <0> : {}", size_buckets[i]);
      else std::println("  <2^{}..=2^{}> : {}", i, i+1, size_buckets[i]);
    }
    std::println("==========================\n");
  }

  static uint64_t now_ns() {
    using clock = std::chrono::steady_clock;
    return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(clock::now().time_since_epoch()).count();
  }

  void log(uint8_t op, uintptr_t addr, size_t sz, uint64_t dt_ns, uint64_t repetitions) {
    uint64_t t = now_ns() - t0_ns;
    trace.push_back(trace_row{
      .seq = seq++,
      .t_ns = t,
      .dt_ns = dt_ns,
      .addr = addr,
      .size = (uint64_t)sz,
      .op = op,
      .repeats = repetitions,
    });
  }

  void dump_csv() const {
    std::println("==BEGIN_TRACE==");
    std::println("seq,t_ns,cycle_count,op,addr,size,repeats");
    for (auto const& r : trace) {
      std::println("{},{},{},{},{:#x},{},{}",
                   r.seq, r.t_ns, r.dt_ns,
                   (r.op == 0 ? "request" : (r.op == 1) ? "free" : (r.op == 2) ? "touch" : (r.op == 3) ? "touchsample" : (r.op == 4) ? "touchrandom" : "???"),
                   r.addr, r.size, r.repeats);
    }
    std::println("==END_TRACE==");
  }
};

static inline uint64_t tsc_start() {
  unsigned lo, hi;
  asm volatile(
    "cpuid\n\t"
    "rdtsc\n\t"
    "mov %%edx, %0\n\t"
    "mov %%eax, %1\n\t"
    : "=r"(hi), "=r"(lo)
    :: "%rax", "%rbx", "%rcx", "%rdx", "memory"
  );
  return (uint64_t(hi) << 32) | lo;
}

static inline uint64_t tsc_end() {
  unsigned lo, hi;
  asm volatile(
    "lfence\n\t"  // we don't have rdtscp :(
    "rdtsc\n\t"
    "mov %%edx, %0\n\t"
    "mov %%eax, %1\n\t"
    "cpuid\n\t"
    : "=r"(hi), "=r"(lo)
    :: "%rax", "%rbx", "%rcx", "%rdx", "memory"
  );
  return (uint64_t(hi) << 32) | lo;
}

template <typename strat_resource>
struct profiled_buddy {
  strat_resource& allocator;
  alloc_profile& prof;
  static constexpr const uint64_t REPEATS = 10;
  using memset_fn = void *(*)(void *, int, size_t);

  uintptr_t malloc(size_t sz) {
    auto t0 = tsc_start();
    uintptr_t addr = allocator.malloc(sz);
    if (addr == 0 || addr == UINTPTR_MAX) throw std::bad_alloc{};

    auto t1 = tsc_end();

    auto dt = t1-t0;

    prof.on_alloc(addr, sz, (uint64_t)dt);
    prof.log(0, addr, sz, (uint64_t)dt, 1);
    return addr;
  }

  void touch(uintptr_t addr, size_t sz) {
    auto t0 = tsc_start();
    std::memset(reinterpret_cast<void*>(addr), 0, sz);
    auto t1 = tsc_end();

    auto dt1 = t1-t0;
    prof.log(2, addr, sz, (uint64_t)dt1, 1);
    
    auto t2 = tsc_start();
    for (int i=0; i<REPEATS; i++) {
      std::memset(reinterpret_cast<void*>(addr), addr+i, sz);
      asm volatile("" ::: "memory");
    }
    auto t3 = tsc_end();

    auto dt2 = t3-t2;
    prof.log(3, addr, sz, (uint64_t)dt2, REPEATS);
  }

  void touch_random(uintptr_t addr, size_t sz) {
    auto t0 = tsc_start();
    for (int i=0; i<REPEATS; i++) {
      std::memset(reinterpret_cast<void*>(addr), addr+i, sz);
      asm volatile("" ::: "memory");
    }
    auto t1 = tsc_end();

    auto dt = t1-t0;
    prof.log(4, addr, sz, (uint64_t)dt, REPEATS);
  }

  void free(uintptr_t addr, size_t sz) {
    auto t0 = tsc_start();
    allocator.free(addr, sz);
    auto t1 = tsc_end();

    auto dt = t1-t0;
    prof.on_free(addr, sz, (uint64_t)dt);
    prof.log(1, addr, sz, (uint64_t)dt, 1);
  }
};


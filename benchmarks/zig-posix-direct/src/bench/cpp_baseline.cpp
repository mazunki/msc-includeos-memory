#include "cpp_baseline.hpp"
#include "randomizer.h"
#include "zig_alloc_shim.hpp"

#include <sys/mman.h>
#include <vector>

namespace {

inline uint64_t tsc_start() {
  uint32_t hi, lo;
  asm volatile(
    "cpuid\n\t"
    "rdtsc\n\t"
    "mov %%edx, %0\n\t"
    "mov %%eax, %1\n\t"
    : "=r"(hi), "=r"(lo)
    :
    : "rax", "rbx", "rcx", "rdx", "memory");
  return (static_cast<uint64_t>(hi) << 32) | lo;
}

inline uint64_t tsc_end() {
  uint32_t hi, lo;
  asm volatile(
    "lfence\n\t"
    "rdtsc\n\t"
    "mov %%edx, %0\n\t"
    "mov %%eax, %1\n\t"
    "cpuid\n\t"
    : "=r"(hi), "=r"(lo)
    :
    : "rax", "rbx", "rcx", "rdx", "memory");
  return (static_cast<uint64_t>(hi) << 32) | lo;
}

void* posix_alloc(size_t len) {
  void* p = mmap(nullptr, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  return (p == MAP_FAILED) ? nullptr : p;
}

void posix_free(void* ptr, size_t len) {
  if (ptr) munmap(ptr, len);
}

void* includeos_alloc(size_t len) {
  return includeos_zig_alloc(len, 1);
}

void includeos_free(void* ptr, size_t len) {
  includeos_zig_free(ptr, len, 1);
}

template <typename AllocFn, typename FreeFn>
void bench_batched(AllocFn alloc_fn, FreeFn free_fn, size_t total_ops, size_t batch_size,
                    size_t size, double* alloc_avg_out, double* free_avg_out) {
  std::vector<void*> buffers(batch_size, nullptr);

  uint64_t alloc_total = 0, free_total = 0;
  size_t done = 0;
  while (done < total_ops) {
    for (auto& buf : buffers) {
      const uint64_t t0 = tsc_start();
      buf = alloc_fn(size);
      const uint64_t t1 = tsc_end();
      alloc_total += t1 - t0;
    }
    for (auto& buf : buffers) {
      const uint64_t t0 = tsc_start();
      free_fn(buf, size);
      const uint64_t t1 = tsc_end();
      free_total += t1 - t0;
    }
    done += batch_size;
  }

  const double ops = static_cast<double>(done);
  *alloc_avg_out = static_cast<double>(alloc_total) / ops;
  *free_avg_out = static_cast<double>(free_total) / ops;
}

template <typename AllocFn, typename FreeFn>
void bench_interleaved(AllocFn alloc_fn, FreeFn free_fn, size_t total_ops, size_t max_live,
                        size_t size, uint64_t seed, double* alloc_avg_out, double* free_avg_out) {
  struct LiveBuf { void* ptr; size_t len; };
  std::vector<LiveBuf> live;
  live.reserve(max_live);

  static constexpr size_t size2 = 17;
  static constexpr double size1_prob = 0.7;
  static constexpr double size2_prob = 0.1;

  uint64_t rng_state = seed;

  uint64_t alloc_total = 0, free_total = 0;
  uint64_t alloc_n = 0, free_n = 0;

  for (size_t done = 0; done < total_ops; ++done) {
    const double r = randomizer_next_float(&rng_state);

    bool want_free = r >= size1_prob + size2_prob;
    if (live.empty()) want_free = false;
    if (live.size() >= max_live) want_free = true;

    if (want_free) {
      const size_t idx = randomizer_next_less_than(&rng_state, live.size());
      LiveBuf entry = live[idx];
      live[idx] = live.back();
      live.pop_back();

      const uint64_t t0 = tsc_start();
      free_fn(entry.ptr, entry.len);
      const uint64_t t1 = tsc_end();
      if (entry.len == size) {
        free_total += t1 - t0;
        free_n++;
      }
    } else {
      const bool use_size2 = r >= size1_prob && r < size1_prob + size2_prob;
      const size_t alloc_size = use_size2 ? size2 : size;

      const uint64_t t0 = tsc_start();
      void* buf = alloc_fn(alloc_size);
      const uint64_t t1 = tsc_end();
      if (!use_size2) {
        alloc_total += t1 - t0;
        alloc_n++;
      }
      live.push_back({buf, alloc_size});
    }
  }

  for (auto& entry : live) free_fn(entry.ptr, entry.len);

  *alloc_avg_out = alloc_n ? static_cast<double>(alloc_total) / static_cast<double>(alloc_n) : 0.0;
  *free_avg_out = free_n ? static_cast<double>(free_total) / static_cast<double>(free_n) : 0.0;
}

template <typename AllocFn, typename FreeFn>
void bench_fill(AllocFn alloc_fn, FreeFn free_fn, size_t size,
                 double* alloc_costs_out, double* free_costs_out,
                 size_t capacity, size_t* count_out, bool* capped_out) {
  std::vector<void*> live;
  live.reserve(capacity);

  size_t count = 0;
  while (count < capacity) {
    const uint64_t t0 = tsc_start();
    void* buf = alloc_fn(size);
    const uint64_t t1 = tsc_end();
    if (!buf) break; // genuine failure -- stop
    alloc_costs_out[count] = static_cast<double>(t1 - t0);
    live.push_back(buf);
    count++;
  }
  *count_out = count;
  *capped_out = (count == capacity);

  for (size_t i = count; i-- > 0;) {
    const uint64_t t0 = tsc_start();
    free_fn(live[i], size);
    const uint64_t t1 = tsc_end();
    free_costs_out[i] = static_cast<double>(t1 - t0);
  }
}

template <typename AllocFn, typename FreeFn>
void bench_interleaved_fill(AllocFn alloc_fn, FreeFn free_fn, size_t size, uint64_t seed,
                             double* alloc_costs_out, double* free_costs_out,
                             size_t live_capacity, size_t cost_capacity,
                             size_t* alloc_count_out, size_t* free_count_out,
                             bool* capped_out) {
  struct LiveBuf { void* ptr; size_t len; };
  std::vector<LiveBuf> live;
  live.reserve(live_capacity);

  static constexpr size_t size2 = 17;
  static constexpr double size1_prob = 0.7;
  static constexpr double size2_prob = 0.1;

  uint64_t rng_state = seed;
  size_t alloc_count = 0, free_count = 0;
  bool capped = false;

  for (;;) {
    const double r = randomizer_next_float(&rng_state);

    bool want_free = r >= size1_prob + size2_prob;
    if (live.empty()) want_free = false;
    if (live.size() >= live_capacity) want_free = true;

    if (want_free) {
      const size_t idx = randomizer_next_less_than(&rng_state, live.size());
      LiveBuf entry = live[idx];
      live[idx] = live.back();
      live.pop_back();

      const uint64_t t0 = tsc_start();
      free_fn(entry.ptr, entry.len);
      const uint64_t t1 = tsc_end();
      if (entry.len == size) {
        if (free_count >= cost_capacity) { capped = true; break; } // safety stop
        free_costs_out[free_count] = static_cast<double>(t1 - t0);
        free_count++;
      }
    } else {
      const bool use_size2 = r >= size1_prob && r < size1_prob + size2_prob;
      const size_t alloc_size = use_size2 ? size2 : size;

      if (!use_size2 && alloc_count >= cost_capacity) { capped = true; break; } // safety stop

      const uint64_t t0 = tsc_start();
      void* buf = alloc_fn(alloc_size);
      const uint64_t t1 = tsc_end();
      if (!buf) break; // genuine failure -- stop
      if (!use_size2) {
        alloc_costs_out[alloc_count] = static_cast<double>(t1 - t0);
        alloc_count++;
      }
      live.push_back({buf, alloc_size});
    }
  }
  *alloc_count_out = alloc_count;
  *capped_out = capped;

  for (size_t i = live.size(); i-- > 0;) {
    const uint64_t t0 = tsc_start();
    free_fn(live[i].ptr, live[i].len);
    const uint64_t t1 = tsc_end();
    if (live[i].len == size && free_count < cost_capacity) {
      free_costs_out[free_count] = static_cast<double>(t1 - t0);
      free_count++;
    }
  }
  *free_count_out = free_count;
}

} // namespace

void cpp_bench_posix_batched(size_t total_ops, size_t batch_size, size_t size, double* alloc_avg_out, double* free_avg_out) {
  bench_batched(posix_alloc, posix_free, total_ops, batch_size, size, alloc_avg_out, free_avg_out);
}

void cpp_bench_includeos_batched(size_t total_ops, size_t batch_size, size_t size, double* alloc_avg_out, double* free_avg_out) {
  bench_batched(includeos_alloc, includeos_free, total_ops, batch_size, size, alloc_avg_out, free_avg_out);
}

void cpp_bench_posix_interleaved(size_t total_ops, size_t max_live, size_t size, uint64_t seed, double* alloc_avg_out, double* free_avg_out) {
  bench_interleaved(posix_alloc, posix_free, total_ops, max_live, size, seed, alloc_avg_out, free_avg_out);
}

void cpp_bench_includeos_interleaved(size_t total_ops, size_t max_live, size_t size, uint64_t seed, double* alloc_avg_out, double* free_avg_out) {
  bench_interleaved(includeos_alloc, includeos_free, total_ops, max_live, size, seed, alloc_avg_out, free_avg_out);
}

void cpp_bench_posix_fill(size_t size, double* alloc_costs_out, double* free_costs_out, size_t capacity, size_t* count_out, bool* capped_out) {
  bench_fill(posix_alloc, posix_free, size, alloc_costs_out, free_costs_out, capacity, count_out, capped_out);
}

void cpp_bench_includeos_fill(size_t size, double* alloc_costs_out, double* free_costs_out, size_t capacity, size_t* count_out, bool* capped_out) {
  bench_fill(includeos_alloc, includeos_free, size, alloc_costs_out, free_costs_out, capacity, count_out, capped_out);
}

void cpp_bench_posix_interleaved_fill(size_t size, uint64_t seed, double* alloc_costs_out, double* free_costs_out, size_t live_capacity, size_t cost_capacity, size_t* alloc_count_out, size_t* free_count_out, bool* capped_out) {
  bench_interleaved_fill(posix_alloc, posix_free, size, seed, alloc_costs_out, free_costs_out, live_capacity, cost_capacity, alloc_count_out, free_count_out, capped_out);
}

void cpp_bench_includeos_interleaved_fill(size_t size, uint64_t seed, double* alloc_costs_out, double* free_costs_out, size_t live_capacity, size_t cost_capacity, size_t* alloc_count_out, size_t* free_count_out, bool* capped_out) {
  bench_interleaved_fill(includeos_alloc, includeos_free, size, seed, alloc_costs_out, free_costs_out, live_capacity, cost_capacity, alloc_count_out, free_count_out, capped_out);
}

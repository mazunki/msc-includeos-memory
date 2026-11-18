#include <algorithm>
#include <cstddef>
#include <os>
#include <service>

#include "cpp_baseline.hpp"

#if !defined(BENCH_SIZE)
#error "BENCH_SIZE must be defined (bytes per allocation, e.g. -DBENCH_SIZE=65536)"
#endif

#if defined(BENCH_ALLOCATOR_POSIX) == defined(BENCH_ALLOCATOR_INCLUDEOS)
#error "define exactly one of BENCH_ALLOCATOR_POSIX or BENCH_ALLOCATOR_INCLUDEOS"
#endif

#if defined(BENCH_WORKLOAD_BATCHED) + defined(BENCH_WORKLOAD_INTERLEAVED) + defined(BENCH_WORKLOAD_FILL) + defined(BENCH_WORKLOAD_INTERLEAVED_FILL) + defined(BENCH_WORKLOAD_JQ_COUNT) + defined(BENCH_WORKLOAD_JQ_SIZE) != 1
#error "define exactly one of BENCH_WORKLOAD_BATCHED, BENCH_WORKLOAD_INTERLEAVED, BENCH_WORKLOAD_FILL, BENCH_WORKLOAD_INTERLEAVED_FILL, BENCH_WORKLOAD_JQ_COUNT, or BENCH_WORKLOAD_JQ_SIZE"
#endif

#if defined(BENCH_LANG_ZIG) == defined(BENCH_LANG_CPP)
#error "define exactly one of BENCH_LANG_ZIG or BENCH_LANG_CPP"
#endif

extern "C" int zig_add(int a, int b);
extern "C" int zig_alloc_roundtrip();
extern "C" void bench_posix_mmap(size_t total_ops, size_t batch_size, size_t size, double* alloc_avg_out, double* free_avg_out);
extern "C" void bench_includeos_direct(size_t total_ops, size_t batch_size, size_t size, double* alloc_avg_out, double* free_avg_out);
extern "C" void bench_posix_interleaved(size_t total_ops, size_t max_live, size_t size, uint64_t seed, double* alloc_avg_out, double* free_avg_out);
extern "C" void bench_includeos_interleaved(size_t total_ops, size_t max_live, size_t size, uint64_t seed, double* alloc_avg_out, double* free_avg_out);
extern "C" void bench_posix_fill(size_t size, double* alloc_costs_out, double* free_costs_out, size_t capacity, size_t* count_out, bool* capped_out);
extern "C" void bench_includeos_fill(size_t size, double* alloc_costs_out, double* free_costs_out, size_t capacity, size_t* count_out, bool* capped_out);
extern "C" void bench_posix_interleaved_fill(size_t size, uint64_t seed, double* alloc_costs_out, double* free_costs_out, size_t live_capacity, size_t cost_capacity, size_t* alloc_count_out, size_t* free_count_out, bool* capped_out);
extern "C" void bench_includeos_interleaved_fill(size_t size, uint64_t seed, double* alloc_costs_out, double* free_costs_out, size_t live_capacity, size_t cost_capacity, size_t* alloc_count_out, size_t* free_count_out, bool* capped_out);

// jq-zig arena benchmark. BENCH_SIZE is element count or string length.
extern "C" void bench_posix_jq_count(size_t n, size_t iterations, double* apply_avg_out, double* alloc_avg_out, double* reset_cycles_out);
extern "C" void bench_includeos_jq_count(size_t n, size_t iterations, double* apply_avg_out, double* alloc_avg_out, double* reset_cycles_out);
extern "C" void bench_posix_jq_size(size_t len, size_t iterations, double* apply_avg_out, double* byte_avg_out, double* reset_cycles_out);
extern "C" void bench_includeos_jq_size(size_t len, size_t iterations, double* apply_avg_out, double* byte_avg_out, double* reset_cycles_out);

void Service::start(const std::string&) {
  std::println("Hello from the zig<->includeos bridge!");
  std::println("zig_add(2, 40) = {}", zig_add(2, 40));

  const int alloc_result = zig_alloc_roundtrip();
  std::println("zig_alloc_roundtrip() = {} ({})", alloc_result,
               alloc_result == 0 ? "PASS: os::mem::raw_allocator() alloc/write/realloc/free all correct"
                                  : "FAIL");

  // One size and one allocator per binary, so nothing else warms up.
  static constexpr size_t bytes = BENCH_SIZE;

  std::println("[service start]");

#if defined(BENCH_WORKLOAD_FILL)
  static constexpr size_t capacity = 1048576;
  static double alloc_costs[capacity];
  static double free_costs[capacity];
  size_t count = 0;
  bool capped = false;

  const char* label_prefix;
#if defined(BENCH_LANG_ZIG) && defined(BENCH_ALLOCATOR_POSIX)
  bench_posix_fill(bytes, alloc_costs, free_costs, capacity, &count, &capped);
  label_prefix = "zig_posix";
#elif defined(BENCH_LANG_ZIG) && defined(BENCH_ALLOCATOR_INCLUDEOS)
  bench_includeos_fill(bytes, alloc_costs, free_costs, capacity, &count, &capped);
  label_prefix = "zig_includeos";
#elif defined(BENCH_LANG_CPP) && defined(BENCH_ALLOCATOR_POSIX)
  cpp_bench_posix_fill(bytes, alloc_costs, free_costs, capacity, &count, &capped);
  label_prefix = "cpp_posix";
#else // BENCH_LANG_CPP && BENCH_ALLOCATOR_INCLUDEOS
  cpp_bench_includeos_fill(bytes, alloc_costs, free_costs, capacity, &count, &capped);
  label_prefix = "cpp_includeos";
#endif

  for (size_t i = 0; i < count; ++i) {
    std::println("{}.fill_alloc.{}.{} {:.3f}", label_prefix, bytes, i, alloc_costs[i]);
  }
  for (size_t i = 0; i < count; ++i) {
    std::println("{}.fill_free.{}.{} {:.3f}", label_prefix, bytes, i, free_costs[i]);
  }
  std::println("{}.fill_count.{} {}", label_prefix, bytes, count);
  std::println("{}.fill_capped.{} {}", label_prefix, bytes, capped ? 1 : 0);
#elif defined(BENCH_WORKLOAD_INTERLEAVED_FILL)
  static constexpr uint64_t interleaved_seed = 0xC0FFEE;
  static constexpr size_t live_capacity = 4096;
  static constexpr size_t cost_capacity = 1048576;
  static double alloc_costs[cost_capacity];
  static double free_costs[cost_capacity];
  size_t alloc_count = 0, free_count = 0;
  bool capped = false;

  const char* label_prefix;
#if defined(BENCH_LANG_ZIG) && defined(BENCH_ALLOCATOR_POSIX)
  bench_posix_interleaved_fill(bytes, interleaved_seed, alloc_costs, free_costs, live_capacity, cost_capacity, &alloc_count, &free_count, &capped);
  label_prefix = "zig_posix";
#elif defined(BENCH_LANG_ZIG) && defined(BENCH_ALLOCATOR_INCLUDEOS)
  bench_includeos_interleaved_fill(bytes, interleaved_seed, alloc_costs, free_costs, live_capacity, cost_capacity, &alloc_count, &free_count, &capped);
  label_prefix = "zig_includeos";
#elif defined(BENCH_LANG_CPP) && defined(BENCH_ALLOCATOR_POSIX)
  cpp_bench_posix_interleaved_fill(bytes, interleaved_seed, alloc_costs, free_costs, live_capacity, cost_capacity, &alloc_count, &free_count, &capped);
  label_prefix = "cpp_posix";
#else // BENCH_LANG_CPP && BENCH_ALLOCATOR_INCLUDEOS
  cpp_bench_includeos_interleaved_fill(bytes, interleaved_seed, alloc_costs, free_costs, live_capacity, cost_capacity, &alloc_count, &free_count, &capped);
  label_prefix = "cpp_includeos";
#endif

  for (size_t i = 0; i < alloc_count; ++i) {
    std::println("{}.interleaved_fill_alloc.{}.{} {:.3f}", label_prefix, bytes, i, alloc_costs[i]);
  }
  for (size_t i = 0; i < free_count; ++i) {
    std::println("{}.interleaved_fill_free.{}.{} {:.3f}", label_prefix, bytes, i, free_costs[i]);
  }
  std::println("{}.interleaved_fill_alloc_count.{} {}", label_prefix, bytes, alloc_count);
  std::println("{}.interleaved_fill_free_count.{} {}", label_prefix, bytes, free_count);
  std::println("{}.interleaved_fill_capped.{} {}", label_prefix, bytes, capped ? 1 : 0);
#elif defined(BENCH_WORKLOAD_JQ_COUNT)
  static constexpr size_t jq_iterations = 50;
  double apply_avg, alloc_avg, reset_cycles;
  const char* label_prefix;
#if defined(BENCH_ALLOCATOR_POSIX)
  bench_posix_jq_count(bytes, jq_iterations, &apply_avg, &alloc_avg, &reset_cycles);
  label_prefix = "posix";
#else // BENCH_ALLOCATOR_INCLUDEOS
  bench_includeos_jq_count(bytes, jq_iterations, &apply_avg, &alloc_avg, &reset_cycles);
  label_prefix = "includeos";
#endif
  std::println("{}.count-apply.{} {:.4f}", label_prefix, bytes, apply_avg);
  std::println("{}.count-alloc.{} {:.4f}", label_prefix, bytes, alloc_avg);
  std::println("{}.count-reset.{} {:.4f}", label_prefix, bytes, reset_cycles);
#elif defined(BENCH_WORKLOAD_JQ_SIZE)
  static constexpr size_t jq_iterations = 50;
  double apply_avg, byte_avg, reset_cycles;
  const char* label_prefix;
#if defined(BENCH_ALLOCATOR_POSIX)
  bench_posix_jq_size(bytes, jq_iterations, &apply_avg, &byte_avg, &reset_cycles);
  label_prefix = "posix";
#else // BENCH_ALLOCATOR_INCLUDEOS
  bench_includeos_jq_size(bytes, jq_iterations, &apply_avg, &byte_avg, &reset_cycles);
  label_prefix = "includeos";
#endif
  std::println("{}.size-apply.{} {:.4f}", label_prefix, bytes, apply_avg);
  std::println("{}.size-byte.{} {:.4f}", label_prefix, bytes, byte_avg);
  std::println("{}.size-reset.{} {:.4f}", label_prefix, bytes, reset_cycles);
#else
  static constexpr size_t total_ops = 2000;
  static constexpr size_t max_live_bytes = 64 * 1024 * 1024;
  const size_t batch_size = std::clamp<size_t>(max_live_bytes / bytes, 1, 256);

  static constexpr uint64_t interleaved_seed = 0xC0FFEE;

  // Exactly one bench_* call per binary.
  double alloc_avg, free_avg;
  const char* label_prefix;
  const char* op_suffix;

#if defined(BENCH_LANG_ZIG) && defined(BENCH_ALLOCATOR_POSIX) && defined(BENCH_WORKLOAD_BATCHED)
  bench_posix_mmap(total_ops, batch_size, bytes, &alloc_avg, &free_avg);
  label_prefix = "zig_posix"; op_suffix = "";
#elif defined(BENCH_LANG_ZIG) && defined(BENCH_ALLOCATOR_POSIX) && defined(BENCH_WORKLOAD_INTERLEAVED)
  bench_posix_interleaved(total_ops, batch_size, bytes, interleaved_seed, &alloc_avg, &free_avg);
  label_prefix = "zig_posix"; op_suffix = "_interleaved";
#elif defined(BENCH_LANG_ZIG) && defined(BENCH_ALLOCATOR_INCLUDEOS) && defined(BENCH_WORKLOAD_BATCHED)
  bench_includeos_direct(total_ops, batch_size, bytes, &alloc_avg, &free_avg);
  label_prefix = "zig_includeos"; op_suffix = "";
#elif defined(BENCH_LANG_ZIG) && defined(BENCH_ALLOCATOR_INCLUDEOS) && defined(BENCH_WORKLOAD_INTERLEAVED)
  bench_includeos_interleaved(total_ops, batch_size, bytes, interleaved_seed, &alloc_avg, &free_avg);
  label_prefix = "zig_includeos"; op_suffix = "_interleaved";
#elif defined(BENCH_LANG_CPP) && defined(BENCH_ALLOCATOR_POSIX) && defined(BENCH_WORKLOAD_BATCHED)
  cpp_bench_posix_batched(total_ops, batch_size, bytes, &alloc_avg, &free_avg);
  label_prefix = "cpp_posix"; op_suffix = "";
#elif defined(BENCH_LANG_CPP) && defined(BENCH_ALLOCATOR_POSIX) && defined(BENCH_WORKLOAD_INTERLEAVED)
  cpp_bench_posix_interleaved(total_ops, batch_size, bytes, interleaved_seed, &alloc_avg, &free_avg);
  label_prefix = "cpp_posix"; op_suffix = "_interleaved";
#elif defined(BENCH_LANG_CPP) && defined(BENCH_ALLOCATOR_INCLUDEOS) && defined(BENCH_WORKLOAD_BATCHED)
  cpp_bench_includeos_batched(total_ops, batch_size, bytes, &alloc_avg, &free_avg);
  label_prefix = "cpp_includeos"; op_suffix = "";
#else // BENCH_LANG_CPP && BENCH_ALLOCATOR_INCLUDEOS && BENCH_WORKLOAD_INTERLEAVED
  cpp_bench_includeos_interleaved(total_ops, batch_size, bytes, interleaved_seed, &alloc_avg, &free_avg);
  label_prefix = "cpp_includeos"; op_suffix = "_interleaved";
#endif

  std::println("{}.alloc{}.{} {:.3f}", label_prefix, op_suffix, bytes, alloc_avg);
  std::println("{}.free{}.{} {:.3f}", label_prefix, op_suffix, bytes, free_avg);
#endif

  std::println("[service end]");

  os::shutdown();
}

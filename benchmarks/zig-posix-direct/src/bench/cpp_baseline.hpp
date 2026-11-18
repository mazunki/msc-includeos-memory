#pragma once
#include <cstddef>
#include <cstdint>

extern "C" {
  void cpp_bench_posix_batched(size_t total_ops, size_t batch_size, size_t size, double* alloc_avg_out, double* free_avg_out);
  void cpp_bench_includeos_batched(size_t total_ops, size_t batch_size, size_t size, double* alloc_avg_out, double* free_avg_out);
  void cpp_bench_posix_interleaved(size_t total_ops, size_t max_live, size_t size, uint64_t seed, double* alloc_avg_out, double* free_avg_out);
  void cpp_bench_includeos_interleaved(size_t total_ops, size_t max_live, size_t size, uint64_t seed, double* alloc_avg_out, double* free_avg_out);
  void cpp_bench_posix_fill(size_t size, double* alloc_costs_out, double* free_costs_out, size_t capacity, size_t* count_out, bool* capped_out);
  void cpp_bench_includeos_fill(size_t size, double* alloc_costs_out, double* free_costs_out, size_t capacity, size_t* count_out, bool* capped_out);
  void cpp_bench_posix_interleaved_fill(size_t size, uint64_t seed, double* alloc_costs_out, double* free_costs_out, size_t live_capacity, size_t cost_capacity, size_t* alloc_count_out, size_t* free_count_out, bool* capped_out);
  void cpp_bench_includeos_interleaved_fill(size_t size, uint64_t seed, double* alloc_costs_out, double* free_costs_out, size_t live_capacity, size_t cost_capacity, size_t* alloc_count_out, size_t* free_count_out, bool* capped_out);
}

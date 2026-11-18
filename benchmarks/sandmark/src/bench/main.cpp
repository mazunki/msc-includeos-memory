#include <os>
#include <service>
#include <kernel/memory.hpp>
#include "test.c"

void Service::start(const std::string&){
  printf("[ocaml start]\n");
  printf("[bench start]\n");

  struct ocaml_timing t = ocaml_init();

  printf("[bench end]\n");

  auto& stats = os::mem::raw_allocator().stats();
  printf("caml_startup_cycles  %llu\n", (unsigned long long)t.startup_cycles);
  printf("ocaml_entry_cycles   %llu\n", (unsigned long long)t.entry_cycles);
  printf("peak_requested_bytes %zu\n",  stats.peak_requested_bytes);
  printf("peak_busy_bytes      %zu\n",  stats.peak_busy_bytes);
  printf("highest_used         %zu\n",  os::mem::raw_allocator().highest_used());
  printf("count_alloc          %llu\n", (unsigned long long)stats.count_alloc);
  printf("count_alloc_at       %llu\n", (unsigned long long)stats.count_alloc_at);

  printf("[ocaml end]\n");
  os::shutdown();
}

#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>
#include "test.c"

struct maps_stats {
  size_t    total_anon_bytes;
  uint64_t  count_anon;
  uintptr_t highest_used;
};

static struct maps_stats read_maps(void) {
  struct maps_stats s = {0, 0, 0};
  FILE *f = fopen("/proc/self/maps", "r");
  if (!f) return s;

  char line[256];
  while (fgets(line, sizeof(line), f)) {
    uintptr_t start, end;
    char perms[5], dev[6], path[64] = "";
    unsigned long offset, inode;
    int n = sscanf(line, "%lx-%lx %4s %lx %5s %lu %63s", &start, &end, perms, &offset, dev, &inode, path);

    if (n < 6) continue;
    if (inode != 0) continue; /* only anonymous mappings */
    if (path[0] != '\0') continue;  /* skip [stack], [vdso], [vvar], [vsyscall] */

    size_t len = end - start;
    s.total_anon_bytes += len;
    s.count_anon++;
    if (end > s.highest_used) s.highest_used = end;
  }
  fclose(f);
  return s;
}

static void dump_maps(void) {
  FILE *f = fopen("/proc/self/maps", "r");
  if (!f) return;
  char line[256];
  while (fgets(line, sizeof(line), f))
    fputs(line, stdout);
  fclose(f);
}

int main(void) {
  printf("[ocaml start]\n");

  struct ocaml_timing t = ocaml_init();
  struct maps_stats m = read_maps();

  printf("caml_startup_cycles  %llu\n", (unsigned long long)t.startup_cycles);
  printf("ocaml_entry_cycles   %llu\n", (unsigned long long)t.entry_cycles);
  printf("peak_requested_bytes %zu\n",  m.total_anon_bytes);
  printf("highest_used         %zu\n",  (size_t)m.highest_used);
  printf("count_alloc          %llu\n", (unsigned long long)m.count_anon);
  printf("peak_rss_kb          %ld\n",  t.peak_rss_kb);

  dump_maps();

  printf("[ocaml end]\n");
  return 0;
}

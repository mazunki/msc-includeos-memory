#include <unistd.h>
#include <sys/syscall.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <x86intrin.h>

static const uint64_t COUNT = 10000;


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
  return ((uint64_t)hi << 32) | lo;
}

static inline uint64_t tsc_end() {
  unsigned lo, hi;
  asm volatile(
    "lfence\n\t"
    "rdtsc\n\t"
    "mov %%edx, %0\n\t"
    "mov %%eax, %1\n\t"
    "cpuid\n\t"
    : "=r"(hi), "=r"(lo)
    :: "%rax", "%rbx", "%rcx", "%rdx", "memory"
  );
  return ((uint64_t)hi << 32) | lo;
}

static double measure(void (*fn)(void), void (*cleanup)(void)) {
  uint64_t total = 0;
  for (size_t i = 0; i < COUNT; i++) {
    uint64_t t0 = tsc_start();
    fn();
    uint64_t t1 = tsc_end();
    total += t1 - t0;
    if (cleanup != NULL) cleanup();
  }
  return (double)total / (double)COUNT;
}

static void do_gettid_syscall(void) { syscall(SYS_gettid); }
static void do_getpid_syscall(void) { syscall(SYS_getpid); }
static void do_getpid_libc(void)    { getpid(); }
static void do_gettimeofday(void)   { struct timeval tv; gettimeofday(&tv, NULL); }

#ifdef INCLUDEOS
extern void* syscall_SYS_mmap(void*, size_t, int, int, int, off_t);
extern long  syscall_SYS_munmap(void*, size_t);
#endif

static void *p;
#ifdef INCLUDEOS
static void do_mmap_syscall_256k(void)         { p = syscall_SYS_mmap(NULL, 4096*64, PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0); }
static void do_mmap_syscall_256k_cleanup(void) { syscall_SYS_munmap(p, 4096*64); }
static void do_mmap_syscall_1b(void)           { p = syscall_SYS_mmap(NULL, 1, PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0); }
static void do_mmap_syscall_1b_cleanup(void)   { syscall_SYS_munmap(p, 1); }
#else
static void do_mmap_syscall_256k(void)         { p = (void*) syscall(SYS_mmap, NULL, 4096*64, PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0); }
static void do_mmap_syscall_256k_cleanup(void) { syscall(SYS_munmap, p, 4096*64); }
static void do_mmap_syscall_1b(void)           { p = (void*) syscall(SYS_mmap, NULL, 1, PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0); }
static void do_mmap_syscall_1b_cleanup(void)   { syscall(SYS_munmap, p, 1); }
#endif

static void do_mmap_libc_256k(void)         { p = mmap(NULL, 4096*64, PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0); }
static void do_mmap_libc_256k_cleanup(void) { munmap(p, 4096*64); }
static void do_mmap_libc_1b(void)           { p = mmap(NULL, 1, PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0); }
static void do_mmap_libc_1b_cleanup(void)   { munmap(p, 1); }

static void do_malloc(void)         { p = malloc(4096*64); }
static void do_malloc_cleanup(void) { free(p); }

static void do_empty_malloc(void)         { p = malloc(0); }
static void do_empty_malloc_cleanup(void) { free(p); }

int main() {
  printf("[service start]\n");
  printf("gettid_syscall       %.3f\n", measure(do_gettid_syscall, NULL));
  printf("getpid_syscall       %.3f\n", measure(do_getpid_syscall, NULL));
  printf("getpid_libc          %.3f\n", measure(do_getpid_libc, NULL));
  printf("gettimeofday         %.3f\n", measure(do_gettimeofday, NULL));
  printf("\n");

  printf("mmap_libc(256KiB)    %.3f\n", measure(do_mmap_libc_256k, do_mmap_libc_256k_cleanup));
  printf("mmap_syscall(256KiB) %.3f\n", measure(do_mmap_syscall_256k, do_mmap_syscall_256k_cleanup));
  printf("\n");

  printf("mmap_libc(1B)        %.3f\n", measure(do_mmap_libc_1b, do_mmap_libc_1b_cleanup));
  printf("mmap_syscall(1B)     %.3f\n", measure(do_mmap_syscall_1b, do_mmap_syscall_1b_cleanup));
  printf("\n");

  printf("malloc(256KiB)       %.3f\n", measure(do_malloc, do_malloc_cleanup));
  printf("malloc(0)            %.3f\n", measure(do_empty_malloc, do_empty_malloc_cleanup));

  printf("[service end]\n");
  return 0;
}

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <caml/alloc.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/callback.h>

#ifndef INCLUDEOS
#include <sys/resource.h>
#endif

#define CAML_NAME_SPACE

/* from ocaml-freestanding; warnings off (set called = 0 to enable) */
#define STUB_WARN_ONCE(type, function, ret) \
    type __unsup_##function(void) __asm__(#function); \
    type __unsup_##function(void) \
    { \
        static int called = 1; \
        if (!called) {\
            printf("STUB: %s() called\n", #function); \
            called = 1; \
        } \
	errno = ENOSYS; \
	return ret; \
    }

#ifdef INCLUDEOS
STUB_WARN_ONCE(pid_t, getpid, 2);
STUB_WARN_ONCE(pid_t, getppid, 1);
STUB_WARN_ONCE(char *, secure_getenv, NULL);
#endif

static inline uint64_t tsc_start(void) {
  unsigned lo, hi;
  __asm__ volatile(
    "cpuid\n\t"
    "rdtsc\n\t"
    "mov %%edx, %0\n\t"
    "mov %%eax, %1\n\t"
    : "=r"(hi), "=r"(lo)
    :: "%rax", "%rbx", "%rcx", "%rdx", "memory"
  );
  return ((uint64_t)hi << 32) | lo;
}

static inline uint64_t tsc_end(void) {
  unsigned lo, hi;
  __asm__ volatile(
    "lfence\n\t"
    "rdtsc\n\t"
    "mov %%edx, %0\n\t"
    "mov %%eax, %1\n\t"
    : "=r"(hi), "=r"(lo)
    :: "%rax", "%rbx", "%rcx", "%rdx", "memory"
  );
  return ((uint64_t)hi << 32) | lo;
}

struct ocaml_timing {
  uint64_t startup_cycles;
  uint64_t entry_cycles;
#ifndef INCLUDEOS
  long peak_rss_kb;
#endif
};

/* Sandmark runs inside caml_startup, so startup_cycles is the whole run. */
static void ocaml_entry(void) {
  static const value *func = NULL;
  if (func == NULL)
    func = caml_named_value("ocaml_entry");
  if (func != NULL)
    caml_callback(*func, Val_unit);
}

static char *argv[] = { (char*)"hello", (char*)NULL };

struct ocaml_timing ocaml_init(void) {
  struct ocaml_timing t = {0, 0};

  uint64_t t0 = tsc_start();
  caml_startup(argv);
  t.startup_cycles = tsc_end() - t0;

  uint64_t t1 = tsc_start();
  ocaml_entry();
  t.entry_cycles = tsc_end() - t1;

#ifndef INCLUDEOS
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  t.peak_rss_kb = ru.ru_maxrss;
#endif

  caml_shutdown();
  return t;
}

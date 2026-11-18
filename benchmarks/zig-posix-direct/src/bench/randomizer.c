#include "randomizer.h"

static uint64_t next(uint64_t* state) {
  uint64_t x = *state;
  x ^= x >> 12;
  x ^= x << 25;
  x ^= x >> 27;
  *state = x;
  return x * 0x2545F4914F6CDD1DULL;
}

double randomizer_next_float(uint64_t* state) {
  const uint64_t bits = next(state) >> 11;
  return (double)bits * (1.0 / 9007199254740992.0); // 2^53
}

size_t randomizer_next_less_than(uint64_t* state, size_t bound) {
  return (size_t)(next(state) % bound);
}

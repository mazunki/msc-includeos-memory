#pragma once

#ifdef __cplusplus
#include <cstddef>
#include <cstdint>
extern "C" {
#else
#include <stddef.h>
#include <stdint.h>
#endif

double randomizer_next_float(uint64_t* state);

size_t randomizer_next_less_than(uint64_t* state, size_t bound);

#ifdef __cplusplus
} // extern "C"
#endif

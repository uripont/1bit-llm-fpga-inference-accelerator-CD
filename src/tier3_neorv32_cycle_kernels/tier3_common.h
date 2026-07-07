#ifndef TIER3_COMMON_H
#define TIER3_COMMON_H

#include <stdint.h>
#if !defined(__riscv)
#include <sys/time.h>
#endif

#define BONSAI_HIDDEN 2048u
#define BONSAI_FFN 6144u
#define BONSAI_HEADS 16u
#define BONSAI_KV_HEADS 8u
#define BONSAI_HEAD_DIM 128u
#define BONSAI_Q1_GROUP 128u
#define BONSAI_REDUCED_LAYERS 2u
#define BONSAI_REDUCED_CTX 4u

static inline uint64_t t3_cycle_counter(void) {
#if defined(__riscv)
  uint32_t lo = 0;
  __asm__ volatile ("csrr %0, cycle" : "=r" (lo));
  return (uint64_t)lo;
#else
  struct timeval tv;
  gettimeofday(&tv, 0);
  return ((uint64_t)tv.tv_sec * 1000000ull) + (uint64_t)tv.tv_usec;
#endif
}

static inline const char * t3_counter_unit(void) {
#if defined(__riscv)
  return "cycles";
#else
  return "host_us";
#endif
}

static inline int16_t t3_input_value(uint32_t index) {
  return (int16_t)((int32_t)((index * 17u + 5u) % 257u) - 128);
}

static inline int16_t t3_scale_q8(uint32_t row, uint32_t group, uint32_t seed) {
  return (int16_t)(64 + ((row * 13u + group * 7u + seed) & 63u));
}

static inline int32_t t3_q1_dot_generated(const int16_t * x,
                                          uint32_t row,
                                          uint32_t cols,
                                          uint32_t seed) {
  int32_t acc = 0;
  for (uint32_t base = 0; base < cols; base += BONSAI_Q1_GROUP) {
    const uint32_t group = base / BONSAI_Q1_GROUP;
    const int16_t scale = t3_scale_q8(row, group, seed);
    int32_t group_acc = 0;

    for (uint32_t j = 0; j < BONSAI_Q1_GROUP; j++) {
      const uint32_t col = base + j;
      const uint32_t bit = ((row * 1103515245u) ^ (col * 12345u) ^ seed) >> 31;
      group_acc += bit ? x[col] : -x[col];
    }

    acc += (group_acc * (int32_t)scale) >> 8;
  }
  return acc;
}

static inline int16_t t3_clamp_i16(int32_t value) {
  if (value > 32767) return 32767;
  if (value < -32768) return -32768;
  return (int16_t)value;
}

static inline int32_t t3_checksum_i16(const int16_t * x, uint32_t n) {
  int32_t sum = 0;
  for (uint32_t i = 0; i < n; i++) {
    sum += (int32_t)x[i] * (int32_t)((i % 31u) + 1u);
  }
  return sum;
}

#endif

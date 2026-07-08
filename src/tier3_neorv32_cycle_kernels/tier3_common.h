#ifndef TIER3_COMMON_H
#define TIER3_COMMON_H

#include <stdint.h>
#if !defined(__riscv)
#include <sys/time.h>
#include <stdio.h>
#else
#include <neorv32.h>
#endif

#define BONSAI_HIDDEN 2048u
#define BONSAI_FFN 6144u
#define BONSAI_HEADS 16u
#define BONSAI_KV_HEADS 8u
#define BONSAI_HEAD_DIM 128u
#define BONSAI_Q1_GROUP 128u
#define BONSAI_REDUCED_LAYERS 2u
#define BONSAI_REDUCED_CTX 4u

#if defined(TIER3_USE_GGUF_FIXTURE)
#include "generated/tier3_bonsai_fixture.h"
#endif

#if defined(__riscv)
#define T3_SETUP() do { neorv32_rte_setup(); neorv32_uart0_setup(19200, 0); } while (0)
#define T3_PRINTF neorv32_uart0_printf
#else
#define T3_SETUP() do { } while (0)
#define T3_PRINTF printf
#endif

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

static inline uint16_t t3_read_u16_le(const uint8_t * p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static inline int32_t t3_fp16_to_q8(uint16_t h) {
  const int32_t sign = (h & 0x8000u) ? -1 : 1;
  int32_t exp = (int32_t)((h >> 10) & 0x1fu);
  int32_t mant = (int32_t)(h & 0x03ffu);
  int32_t value_q8;

  if (exp == 0) {
    value_q8 = mant == 0 ? 0 : ((mant * 256) >> 24);
  } else if (exp == 31) {
    value_q8 = 0;
  } else {
    mant |= 0x0400;
    exp -= 15;
    value_q8 = mant * 256;
    if (exp >= 10) {
      value_q8 <<= (exp - 10);
    } else {
      value_q8 >>= (10 - exp);
    }
  }
  return sign * value_q8;
}

static inline int16_t t3_input_value(uint32_t index) {
#if defined(TIER3_USE_GGUF_FIXTURE)
  return T3_INITIAL_HIDDEN[index % T3_INITIAL_HIDDEN_COUNT];
#else
  return (int16_t)((int32_t)((index * 17u + 5u) % 257u) - 128);
#endif
}

static inline int16_t t3_scale_q8(uint32_t row, uint32_t group, uint32_t seed) {
  return (int16_t)(64 + ((row * 13u + group * 7u + seed) & 63u));
}

static inline int32_t t3_q1_dot_generated(const int16_t * x,
                                          uint32_t row,
                                          uint32_t cols,
                                          uint32_t seed) {
  int32_t acc = 0;
#if defined(TIER3_USE_GGUF_FIXTURE)
  const uint32_t row_bytes = cols == 6144u ? T3_Q1_6144_ROW_BYTES : T3_Q1_2048_ROW_BYTES;
  const uint8_t * bytes = cols == 6144u
      ? T3_Q1_6144_ROWS[(row + seed) % T3_Q1_6144_ROW_COUNT]
      : T3_Q1_2048_ROWS[(row + seed) % T3_Q1_2048_ROW_COUNT];
  (void)row_bytes;

  for (uint32_t base = 0; base < cols; base += BONSAI_Q1_GROUP) {
    const uint32_t block_index = base / BONSAI_Q1_GROUP;
    const uint8_t * block = bytes + block_index * 18u;
    const int32_t scale_q8 = t3_fp16_to_q8(t3_read_u16_le(block));
    const uint8_t * signs = block + 2u;
    int32_t group_acc = 0;

    for (uint32_t j = 0; j < BONSAI_Q1_GROUP; j++) {
      const uint32_t col = base + j;
      const uint32_t bit = (signs[j >> 3] >> (j & 7u)) & 1u;
      group_acc += bit ? x[col] : -x[col];
    }

    acc += (group_acc * scale_q8) >> 8;
  }
#else
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
#endif
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

#include "tier3_common.h"

#ifndef Q1_ROWS
#define Q1_ROWS BONSAI_HIDDEN
#endif

#ifndef Q1_COLS
#define Q1_COLS BONSAI_HIDDEN
#endif

#define Q8_BLOCK 32u
#define Q1_BLOCK_BYTES 18u
#define Q1_SEED 17u

// Activation-side block used by GGML dot kernels: one scale for 32 signed i8 values.
typedef struct {
  int32_t scale_q16;
  int8_t qs[Q8_BLOCK];
} q8_0_block_t;

static int16_t x[Q1_COLS];
static int16_t y[Q1_ROWS];
static q8_0_block_t x_q8[Q1_COLS / Q8_BLOCK];

static int32_t abs_i16_as_i32(int16_t v) {
  return v < 0 ? -(int32_t)v : (int32_t)v;
}

static int32_t div_round_nearest(int32_t num, int32_t den) {
  if (den == 0) return 0;
  if (num >= 0) return (num + den / 2) / den;
  return -((-num + den / 2) / den);
}

static int8_t clamp_i8(int32_t v) {
  if (v > 127) return 127;
  if (v < -128) return -128;
  return (int8_t)v;
}

static void init_input(void) {
  for (uint32_t i = 0; i < Q1_COLS; i++) {
    x[i] = t3_input_value(i);
  }
}

// Mirrors quantize_row_q8_0_ref() at the operation boundary, using fixed-point
// scale storage so the kernel stays NEORV32-friendly.
static void quantize_input_q8_0(void) {
  for (uint32_t block = 0; block < Q1_COLS / Q8_BLOCK; block++) {
    int32_t amax = 0;
    for (uint32_t j = 0; j < Q8_BLOCK; j++) {
      const int32_t a = abs_i16_as_i32(x[block * Q8_BLOCK + j]);
      if (a > amax) amax = a;
    }

    q8_0_block_t * out = &x_q8[block];
    out->scale_q16 = amax == 0 ? 0 : div_round_nearest(amax * 256, 127);
    for (uint32_t j = 0; j < Q8_BLOCK; j++) {
      const int32_t src = (int32_t)x[block * Q8_BLOCK + j];
      const int32_t q = out->scale_q16 == 0 ? 0 : div_round_nearest(src * 256, out->scale_q16);
      out->qs[j] = clamp_i8(q);
    }
  }
}

// The fixture path reads real GGUF Q1_0 block scales; the fallback keeps the
// same loop shape when the generated model fixture is not present.
static int32_t q1_scale_q8(uint32_t row, uint32_t group) {
#if defined(TIER3_USE_GGUF_FIXTURE)
  const uint8_t * bytes = Q1_COLS == 6144u
      ? T3_Q1_6144_ROWS[(row + Q1_SEED) % T3_Q1_6144_ROW_COUNT]
      : T3_Q1_2048_ROWS[(row + Q1_SEED) % T3_Q1_2048_ROW_COUNT];
  const uint8_t * block = bytes + group * Q1_BLOCK_BYTES;
  return t3_fp16_to_q8(t3_read_u16_le(block));
#else
  return (int32_t)t3_scale_q8(row, group, Q1_SEED);
#endif
}

// GGML Q1_0 stores 128 sign bits after one FP16 scale. A set bit contributes
// +x and a clear bit contributes -x for the corresponding activation lane.
static uint32_t q1_sign_bit(uint32_t row, uint32_t col) {
#if defined(TIER3_USE_GGUF_FIXTURE)
  const uint32_t group = col / BONSAI_Q1_GROUP;
  const uint32_t within = col % BONSAI_Q1_GROUP;
  const uint8_t * bytes = Q1_COLS == 6144u
      ? T3_Q1_6144_ROWS[(row + Q1_SEED) % T3_Q1_6144_ROW_COUNT]
      : T3_Q1_2048_ROWS[(row + Q1_SEED) % T3_Q1_2048_ROW_COUNT];
  const uint8_t * signs = bytes + group * Q1_BLOCK_BYTES + 2u;
  return (uint32_t)((signs[within >> 3] >> (within & 7u)) & 1u);
#else
  return ((row * 1103515245u) ^ (col * 12345u) ^ Q1_SEED) >> 31;
#endif
}

// Tier 3 target primitive: Q1_0 weight row times Q8_0 activation blocks.
// Each 128-weight Q1_0 group is split across four Q8_0 activation blocks,
// matching the scalar structure of ggml_vec_dot_q1_0_q8_0_generic().
static int16_t q1_dot_q8_0_row(uint32_t row) {
  int64_t acc_q8 = 0;

  for (uint32_t base = 0; base < Q1_COLS; base += BONSAI_Q1_GROUP) {
    const uint32_t group = base / BONSAI_Q1_GROUP;
    const int32_t w_scale_q8 = q1_scale_q8(row, group);

    for (uint32_t chunk = 0; chunk < BONSAI_Q1_GROUP / Q8_BLOCK; chunk++) {
      const uint32_t q8_block_index = (base / Q8_BLOCK) + chunk;
      const q8_0_block_t * xb = &x_q8[q8_block_index];
      int32_t sumi = 0;

      for (uint32_t j = 0; j < Q8_BLOCK; j++) {
        const uint32_t col = base + chunk * Q8_BLOCK + j;
        const int32_t xq = (int32_t)xb->qs[j];
        sumi += q1_sign_bit(row, col) ? xq : -xq;
      }

      acc_q8 += ((int64_t)w_scale_q8 * (int64_t)xb->scale_q16 * (int64_t)sumi) >> 16;
    }
  }

  return t3_clamp_i16((int32_t)acc_q8);
}

// One backend call computes every output row for the selected Bonsai matvec
// shape, preserving the same rows * cols accounting used by Tier 2.
static void q1_matvec_q1_0_q8_0(void) {
  for (uint32_t row = 0; row < Q1_ROWS; row++) {
    y[row] = q1_dot_q8_0_row(row);
  }
}

int main(void) {
  T3_SETUP();
  init_input();
  quantize_input_q8_0();

  const uint64_t start = t3_cycle_counter();
  q1_matvec_q1_0_q8_0();
  const uint64_t end = t3_cycle_counter();

  const uint64_t dot_elements = (uint64_t)Q1_ROWS * (uint64_t)Q1_COLS;
  const uint64_t groups = dot_elements / BONSAI_Q1_GROUP;
  const uint64_t q8_blocks = (uint64_t)Q1_COLS / Q8_BLOCK;

  T3_PRINTF("kernel=q1_matvec_q1_0_q8_0\n");
  T3_PRINTF("counter_unit=%s\n", t3_counter_unit());
  T3_PRINTF("rows=%u\n", (uint32_t)Q1_ROWS);
  T3_PRINTF("cols=%u\n", (uint32_t)Q1_COLS);
  T3_PRINTF("q1_group=%u\n", (uint32_t)BONSAI_Q1_GROUP);
  T3_PRINTF("q8_block=%u\n", (uint32_t)Q8_BLOCK);
  T3_PRINTF("dot_elements=%u\n", (uint32_t)dot_elements);
  T3_PRINTF("q1_groups=%u\n", (uint32_t)groups);
  T3_PRINTF("activation_q8_blocks=%u\n", (uint32_t)q8_blocks);
  T3_PRINTF("cycles=%u\n", (uint32_t)(end - start));
  T3_PRINTF("checksum=%i\n", (int32_t)t3_checksum_i16(y, Q1_ROWS));
  return 0;
}

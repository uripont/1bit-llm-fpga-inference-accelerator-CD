#include "tier3_common.h"

#include <stdio.h>

#ifndef REDUCED_LAYERS
#define REDUCED_LAYERS BONSAI_REDUCED_LAYERS
#endif

#ifndef REDUCED_CTX
#define REDUCED_CTX BONSAI_REDUCED_CTX
#endif

static int16_t hidden[BONSAI_HIDDEN];
static int16_t normed[BONSAI_HIDDEN];
static int16_t q[BONSAI_HEADS * BONSAI_HEAD_DIM];
static int16_t k[BONSAI_KV_HEADS * BONSAI_HEAD_DIM];
static int16_t v[BONSAI_KV_HEADS * BONSAI_HEAD_DIM];
static int16_t attn[BONSAI_HEADS * BONSAI_HEAD_DIM];
static int16_t attn_projected[BONSAI_HIDDEN];
static int16_t gate[BONSAI_FFN];
static int16_t up[BONSAI_FFN];
static int16_t ffn[BONSAI_HIDDEN];
static int16_t k_cache[REDUCED_CTX][BONSAI_KV_HEADS * BONSAI_HEAD_DIM];
static int16_t v_cache[REDUCED_CTX][BONSAI_KV_HEADS * BONSAI_HEAD_DIM];

static uint64_t q1_calls;
static uint64_t q1_dot_elements;
static uint64_t q1_groups;
static uint64_t attention_calls;
static uint64_t attention_score_mac;
static uint64_t attention_value_moves;
static uint64_t q1_cycles;
static uint64_t attention_cycles;

static void init_hidden(void) {
  for (uint32_t i = 0; i < BONSAI_HIDDEN; i++) {
    hidden[i] = t3_input_value(i + 101u);
  }

  for (uint32_t pos = 0; pos < REDUCED_CTX; pos++) {
    for (uint32_t i = 0; i < BONSAI_KV_HEADS * BONSAI_HEAD_DIM; i++) {
      k_cache[pos][i] = t3_input_value(pos * 4096u + i + 211u);
      v_cache[pos][i] = t3_input_value(pos * 4096u + i + 307u);
    }
  }
}

static void copy_norm_placeholder(void) {
  for (uint32_t i = 0; i < BONSAI_HIDDEN; i++) {
    normed[i] = hidden[i];
  }
}

static void q1_matvec_target(const int16_t * x,
                             uint32_t cols,
                             int16_t * y,
                             uint32_t rows,
                             uint32_t seed) {
  const uint64_t start = t3_cycle_counter();

  for (uint32_t row = 0; row < rows; row++) {
    y[row] = t3_clamp_i16(t3_q1_dot_generated(x, row, cols, seed) >> 4);
  }

  const uint64_t end = t3_cycle_counter();
  q1_cycles += end - start;
  q1_calls++;
  q1_dot_elements += (uint64_t)rows * cols;
  q1_groups += ((uint64_t)rows * cols) / BONSAI_Q1_GROUP;
}

static void attention_target(uint32_t ctx) {
  const uint64_t start = t3_cycle_counter();
  const uint32_t heads_per_kv = BONSAI_HEADS / BONSAI_KV_HEADS;

  for (uint32_t head = 0; head < BONSAI_HEADS; head++) {
    const uint32_t kv_head = head / heads_per_kv;
    int32_t best_score = INT32_MIN;
    uint32_t best_pos = 0;

    for (uint32_t pos = 0; pos < ctx; pos++) {
      int32_t score = 0;
      for (uint32_t d = 0; d < BONSAI_HEAD_DIM; d++) {
        const uint32_t q_idx = head * BONSAI_HEAD_DIM + d;
        const uint32_t kv_idx = kv_head * BONSAI_HEAD_DIM + d;
        score += ((int32_t)q[q_idx] * (int32_t)k_cache[pos][kv_idx]) >> 8;
      }
      if (score > best_score) {
        best_score = score;
        best_pos = pos;
      }
    }

    for (uint32_t d = 0; d < BONSAI_HEAD_DIM; d++) {
      const uint32_t out_idx = head * BONSAI_HEAD_DIM + d;
      const uint32_t kv_idx = kv_head * BONSAI_HEAD_DIM + d;
      attn[out_idx] = v_cache[best_pos][kv_idx];
    }
  }

  const uint64_t end = t3_cycle_counter();
  attention_cycles += end - start;
  attention_calls++;
  attention_score_mac += (uint64_t)BONSAI_HEADS * ctx * BONSAI_HEAD_DIM;
  attention_value_moves += (uint64_t)BONSAI_HEADS * BONSAI_HEAD_DIM;
}

static void residual_add(int16_t * dst, const int16_t * src, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) {
    dst[i] = t3_clamp_i16((int32_t)dst[i] + src[i]);
  }
}

static void ffn_gate_product(void) {
  for (uint32_t i = 0; i < BONSAI_FFN; i++) {
    const int32_t g = gate[i] > 0 ? gate[i] : 0;
    gate[i] = t3_clamp_i16((g * (int32_t)up[i]) >> 8);
  }
}

static void run_layer(uint32_t layer, uint32_t ctx) {
  copy_norm_placeholder();
  q1_matvec_target(normed, BONSAI_HIDDEN, q, BONSAI_HEADS * BONSAI_HEAD_DIM, 1000u + layer);
  q1_matvec_target(normed, BONSAI_HIDDEN, k, BONSAI_KV_HEADS * BONSAI_HEAD_DIM, 2000u + layer);
  q1_matvec_target(normed, BONSAI_HIDDEN, v, BONSAI_KV_HEADS * BONSAI_HEAD_DIM, 3000u + layer);

  for (uint32_t i = 0; i < BONSAI_KV_HEADS * BONSAI_HEAD_DIM; i++) {
    k_cache[ctx - 1u][i] = k[i];
    v_cache[ctx - 1u][i] = v[i];
  }

  attention_target(ctx);
  q1_matvec_target(attn, BONSAI_HEADS * BONSAI_HEAD_DIM, attn_projected, BONSAI_HIDDEN, 4000u + layer);
  residual_add(hidden, attn_projected, BONSAI_HIDDEN);

  copy_norm_placeholder();
  q1_matvec_target(normed, BONSAI_HIDDEN, gate, BONSAI_FFN, 5000u + layer);
  q1_matvec_target(normed, BONSAI_HIDDEN, up, BONSAI_FFN, 6000u + layer);
  ffn_gate_product();
  q1_matvec_target(gate, BONSAI_FFN, ffn, BONSAI_HIDDEN, 7000u + layer);
  residual_add(hidden, ffn, BONSAI_HIDDEN);
}

int main(void) {
  init_hidden();

  const uint64_t start = t3_cycle_counter();
  for (uint32_t layer = 0; layer < REDUCED_LAYERS; layer++) {
    run_layer(layer, REDUCED_CTX);
  }
  const uint64_t end = t3_cycle_counter();

  printf("kernel=reduced_bonsai\n");
  printf("counter_unit=%s\n", t3_counter_unit());
  printf("layers=%u\n", (unsigned)REDUCED_LAYERS);
  printf("ctx=%u\n", (unsigned)REDUCED_CTX);
  printf("hidden=%u\n", (unsigned)BONSAI_HIDDEN);
  printf("ffn=%u\n", (unsigned)BONSAI_FFN);
  printf("heads=%u\n", (unsigned)BONSAI_HEADS);
  printf("kv_heads=%u\n", (unsigned)BONSAI_KV_HEADS);
  printf("head_dim=%u\n", (unsigned)BONSAI_HEAD_DIM);
  printf("q1_calls=%llu\n", (unsigned long long)q1_calls);
  printf("q1_dot_elements=%llu\n", (unsigned long long)q1_dot_elements);
  printf("q1_groups=%llu\n", (unsigned long long)q1_groups);
  printf("attention_calls=%llu\n", (unsigned long long)attention_calls);
  printf("attention_score_mac=%llu\n", (unsigned long long)attention_score_mac);
  printf("attention_value_moves=%llu\n", (unsigned long long)attention_value_moves);
  printf("q1_cycles=%llu\n", (unsigned long long)q1_cycles);
  printf("attention_cycles=%llu\n", (unsigned long long)attention_cycles);
  printf("cycles=%llu\n", (unsigned long long)(end - start));
  printf("checksum=%d\n", (int)t3_checksum_i16(hidden, BONSAI_HIDDEN));
  return 0;
}

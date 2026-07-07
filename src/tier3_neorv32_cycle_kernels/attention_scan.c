#include "tier3_common.h"

#include <stdio.h>

#ifndef ATTENTION_CTX
#define ATTENTION_CTX BONSAI_REDUCED_CTX
#endif

#ifndef ATTENTION_REPEATS
#if defined(__riscv)
#define ATTENTION_REPEATS 1u
#else
#define ATTENTION_REPEATS 1000u
#endif
#endif

static int16_t q[BONSAI_HEADS * BONSAI_HEAD_DIM];
static int16_t k_cache[ATTENTION_CTX][BONSAI_KV_HEADS * BONSAI_HEAD_DIM];
static int16_t v_cache[ATTENTION_CTX][BONSAI_KV_HEADS * BONSAI_HEAD_DIM];
static int16_t out[BONSAI_HEADS * BONSAI_HEAD_DIM];

static void init_attention(void) {
  for (uint32_t i = 0; i < BONSAI_HEADS * BONSAI_HEAD_DIM; i++) {
    q[i] = t3_input_value(i + 11u);
  }

  for (uint32_t t = 0; t < ATTENTION_CTX; t++) {
    for (uint32_t i = 0; i < BONSAI_KV_HEADS * BONSAI_HEAD_DIM; i++) {
      k_cache[t][i] = t3_input_value(t * 4096u + i + 23u);
      v_cache[t][i] = t3_input_value(t * 4096u + i + 47u);
    }
  }
}

static void attention_scan_naive(void) {
  const uint32_t heads_per_kv = BONSAI_HEADS / BONSAI_KV_HEADS;

  for (uint32_t head = 0; head < BONSAI_HEADS; head++) {
    const uint32_t kv_head = head / heads_per_kv;
    int32_t best_score = INT32_MIN;
    uint32_t best_pos = 0;

    for (uint32_t pos = 0; pos < ATTENTION_CTX; pos++) {
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
      out[out_idx] = v_cache[best_pos][kv_idx];
    }
  }
}

int main(void) {
  init_attention();

  const uint64_t start = t3_cycle_counter();
  for (uint32_t i = 0; i < ATTENTION_REPEATS; i++) {
    attention_scan_naive();
  }
  const uint64_t end = t3_cycle_counter();

  const uint64_t score_mac_per_call = (uint64_t)BONSAI_HEADS * ATTENTION_CTX * BONSAI_HEAD_DIM;
  const uint64_t value_moves_per_call = (uint64_t)BONSAI_HEADS * BONSAI_HEAD_DIM;

  printf("kernel=attention_scan\n");
  printf("counter_unit=%s\n", t3_counter_unit());
  printf("heads=%u\n", (unsigned)BONSAI_HEADS);
  printf("kv_heads=%u\n", (unsigned)BONSAI_KV_HEADS);
  printf("head_dim=%u\n", (unsigned)BONSAI_HEAD_DIM);
  printf("ctx=%u\n", (unsigned)ATTENTION_CTX);
  printf("repeats=%u\n", (unsigned)ATTENTION_REPEATS);
  printf("score_mac_per_call=%llu\n", (unsigned long long)score_mac_per_call);
  printf("value_moves_per_call=%llu\n", (unsigned long long)value_moves_per_call);
  printf("score_mac=%llu\n", (unsigned long long)(score_mac_per_call * ATTENTION_REPEATS));
  printf("value_moves=%llu\n", (unsigned long long)(value_moves_per_call * ATTENTION_REPEATS));
  printf("cycles=%llu\n", (unsigned long long)(end - start));
  printf("checksum=%d\n", (int)t3_checksum_i16(out, BONSAI_HEADS * BONSAI_HEAD_DIM));
  return 0;
}

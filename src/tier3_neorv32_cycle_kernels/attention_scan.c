#include "tier3_common.h"

#include <float.h>
#include <math.h>

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

#define ATTENTION_INV_SQRT_HEAD_DIM 0.08838834764831845f

// Tier 3 enters at the attention backend boundary: Q/K are assumed to already
// include Qwen3 head RMSNorm and RoPE, as in Tier 2 before attention_backend().
static int16_t q[BONSAI_HEADS * BONSAI_HEAD_DIM];
static int16_t current_k[BONSAI_KV_HEADS * BONSAI_HEAD_DIM];
static int16_t current_v[BONSAI_KV_HEADS * BONSAI_HEAD_DIM];
static int16_t k_cache[ATTENTION_CTX][BONSAI_KV_HEADS * BONSAI_HEAD_DIM];
static int16_t v_cache[ATTENTION_CTX][BONSAI_KV_HEADS * BONSAI_HEAD_DIM];
static int16_t out[BONSAI_HEADS * BONSAI_HEAD_DIM];
static float scores[ATTENTION_CTX];

static float q8_to_float(int16_t value) {
  return (float)value / 256.0f;
}

static int16_t float_to_q8(float value) {
  const float scaled = value * 256.0f;
  const int32_t rounded = scaled >= 0.0f
      ? (int32_t)(scaled + 0.5f)
      : -(int32_t)((-scaled) + 0.5f);
  return t3_clamp_i16(rounded);
}

// Seed a reduced decode cache: previous positions are already resident, and
// current_k/current_v represent the token being appended before attention.
static void init_attention(void) {
  for (uint32_t i = 0; i < BONSAI_HEADS * BONSAI_HEAD_DIM; i++) {
    q[i] = t3_input_value(i + 11u);
  }

  for (uint32_t i = 0; i < BONSAI_KV_HEADS * BONSAI_HEAD_DIM; i++) {
    current_k[i] = t3_input_value(i + 23u);
    current_v[i] = t3_input_value(i + 47u);
  }

  for (uint32_t t = 0; t + 1u < ATTENTION_CTX; t++) {
    for (uint32_t i = 0; i < BONSAI_KV_HEADS * BONSAI_HEAD_DIM; i++) {
      k_cache[t][i] = t3_input_value(t * 4096u + i + 23u);
      v_cache[t][i] = t3_input_value(t * 4096u + i + 47u);
    }
  }
}

// Decode attention first appends the current token's K/V vectors, then scans
// the resulting cache window for this layer.
static void append_current_kv(void) {
  const uint32_t pos = ATTENTION_CTX - 1u;
  for (uint32_t i = 0; i < BONSAI_KV_HEADS * BONSAI_HEAD_DIM; i++) {
    k_cache[pos][i] = current_k[i];
    v_cache[pos][i] = current_v[i];
  }
}

// Mirrors the Tier 2 attention backend: grouped-query head mapping, QK score
// scan, stable softmax normalization, then weighted V accumulation.
static void attention_backend(void) {
  append_current_kv();

  for (uint32_t head = 0; head < BONSAI_HEADS; head++) {
    // Bonsai/Qwen3 uses more query heads than KV heads; multiple Q heads share
    // each streamed K/V head.
    const uint32_t kv_head = head * BONSAI_KV_HEADS / BONSAI_HEADS;
    float max_score = -FLT_MAX;

    // Score pass: stream K over the context window and retain scores for the
    // later value pass.
    for (uint32_t pos = 0; pos < ATTENTION_CTX; pos++) {
      float score = 0.0f;
      for (uint32_t d = 0; d < BONSAI_HEAD_DIM; d++) {
        const uint32_t q_idx = head * BONSAI_HEAD_DIM + d;
        const uint32_t kv_idx = kv_head * BONSAI_HEAD_DIM + d;
        score += q8_to_float(q[q_idx]) * q8_to_float(k_cache[pos][kv_idx]);
      }

      scores[pos] = score * ATTENTION_INV_SQRT_HEAD_DIM;
      if (scores[pos] > max_score) max_score = scores[pos];
    }

    // Stable softmax, matching the max-subtraction structure used by Tier 2.
    float denom = 0.0f;
    for (uint32_t pos = 0; pos < ATTENTION_CTX; pos++) {
      scores[pos] = expf(scores[pos] - max_score);
      denom += scores[pos];
    }

    const float inv_denom = denom == 0.0f ? 0.0f : 1.0f / denom;
    // Value pass: stream V over the same context window and accumulate one
    // output vector for this query head.
    for (uint32_t d = 0; d < BONSAI_HEAD_DIM; d++) {
      const uint32_t out_idx = head * BONSAI_HEAD_DIM + d;
      float acc = 0.0f;

      for (uint32_t pos = 0; pos < ATTENTION_CTX; pos++) {
        const uint32_t kv_idx = kv_head * BONSAI_HEAD_DIM + d;
        const float weight = scores[pos] * inv_denom;
        acc += weight * q8_to_float(v_cache[pos][kv_idx]);
      }

      out[out_idx] = float_to_q8(acc);
    }
  }
}

int main(void) {
  T3_SETUP();
  init_attention();

  const uint64_t start = t3_cycle_counter();
  for (uint32_t i = 0; i < ATTENTION_REPEATS; i++) {
    attention_backend();
  }
  const uint64_t end = t3_cycle_counter();

  const uint64_t score_mac_per_call = (uint64_t)BONSAI_HEADS * ATTENTION_CTX * BONSAI_HEAD_DIM;
  const uint64_t value_mac_per_call = (uint64_t)BONSAI_HEADS * ATTENTION_CTX * BONSAI_HEAD_DIM;
  const uint64_t kv_append_elements_per_call = (uint64_t)2u * BONSAI_KV_HEADS * BONSAI_HEAD_DIM;

  T3_PRINTF("kernel=attention_kv_softmax\n");
  T3_PRINTF("counter_unit=%s\n", t3_counter_unit());
  T3_PRINTF("heads=%u\n", (uint32_t)BONSAI_HEADS);
  T3_PRINTF("kv_heads=%u\n", (uint32_t)BONSAI_KV_HEADS);
  T3_PRINTF("head_dim=%u\n", (uint32_t)BONSAI_HEAD_DIM);
  T3_PRINTF("ctx=%u\n", (uint32_t)ATTENTION_CTX);
  T3_PRINTF("repeats=%u\n", (uint32_t)ATTENTION_REPEATS);
  T3_PRINTF("score_mac_per_call=%u\n", (uint32_t)score_mac_per_call);
  T3_PRINTF("value_mac_per_call=%u\n", (uint32_t)value_mac_per_call);
  T3_PRINTF("kv_append_elements_per_call=%u\n", (uint32_t)kv_append_elements_per_call);
  T3_PRINTF("score_mac=%u\n", (uint32_t)(score_mac_per_call * ATTENTION_REPEATS));
  T3_PRINTF("value_mac=%u\n", (uint32_t)(value_mac_per_call * ATTENTION_REPEATS));
  T3_PRINTF("kv_append_elements=%u\n", (uint32_t)(kv_append_elements_per_call * ATTENTION_REPEATS));
  T3_PRINTF("cycles=%u\n", (uint32_t)(end - start));
  T3_PRINTF("checksum=%i\n", (int32_t)t3_checksum_i16(out, BONSAI_HEADS * BONSAI_HEAD_DIM));
  return 0;
}

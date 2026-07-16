#include "tier3_common.h"

#include <float.h>
#include <math.h>

#ifndef ATTENTION_CTX
#define ATTENTION_CTX BONSAI_REDUCED_CTX
#endif

#ifndef ATTENTION_HEADS
#define ATTENTION_HEADS BONSAI_HEADS
#endif

#ifndef ATTENTION_KV_HEADS
#define ATTENTION_KV_HEADS BONSAI_KV_HEADS
#endif

#ifndef ATTENTION_HEAD_DIM
#define ATTENTION_HEAD_DIM BONSAI_HEAD_DIM
#endif

#ifndef ATTENTION_REPEATS
#if defined(__riscv)
#define ATTENTION_REPEATS 1u
#else
#define ATTENTION_REPEATS 1000u
#endif
#endif

#ifndef ATTENTION_INV_SQRT_HEAD_DIM
#define ATTENTION_INV_SQRT_HEAD_DIM 0.08838834764831845f
#endif

#define ATTENTION_NORM_NONE 0
#define ATTENTION_NORM_SOFTMAX_EXACT 1

#ifndef ATTENTION_NORM_MODE
#define ATTENTION_NORM_MODE ATTENTION_NORM_SOFTMAX_EXACT
#endif

// Tier 3 enters at the attention backend boundary: Q/K are assumed to already
// include Qwen3 head RMSNorm and RoPE, as in Tier 2 before attention_backend().
static int16_t q[ATTENTION_HEADS * ATTENTION_HEAD_DIM];
static int16_t current_k[ATTENTION_KV_HEADS * ATTENTION_HEAD_DIM];
static int16_t current_v[ATTENTION_KV_HEADS * ATTENTION_HEAD_DIM];
static int16_t k_cache[ATTENTION_CTX][ATTENTION_KV_HEADS * ATTENTION_HEAD_DIM];
static int16_t v_cache[ATTENTION_CTX][ATTENTION_KV_HEADS * ATTENTION_HEAD_DIM];
static int16_t out[ATTENTION_HEADS * ATTENTION_HEAD_DIM];
static float scores[ATTENTION_CTX];
static uint64_t append_cycles;
static uint64_t score_cycles;
static uint64_t norm_cycles;
static uint64_t value_cycles;
static uint64_t service_cycles;

static const char * normalization_mode_name(void) {
#if ATTENTION_NORM_MODE == ATTENTION_NORM_NONE
  return "none";
#elif ATTENTION_NORM_MODE == ATTENTION_NORM_SOFTMAX_EXACT
  return "softmax_exact";
#else
  return "unknown";
#endif
}

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
  for (uint32_t i = 0; i < ATTENTION_HEADS * ATTENTION_HEAD_DIM; i++) {
    q[i] = t3_input_value(i + 11u);
  }

  for (uint32_t i = 0; i < ATTENTION_KV_HEADS * ATTENTION_HEAD_DIM; i++) {
    current_k[i] = t3_input_value(i + 23u);
    current_v[i] = t3_input_value(i + 47u);
  }

  for (uint32_t t = 0; t + 1u < ATTENTION_CTX; t++) {
    for (uint32_t i = 0; i < ATTENTION_KV_HEADS * ATTENTION_HEAD_DIM; i++) {
      k_cache[t][i] = t3_input_value(t * 4096u + i + 23u);
      v_cache[t][i] = t3_input_value(t * 4096u + i + 47u);
    }
  }
}

// Decode attention first appends the current token's K/V vectors, then scans
// the resulting cache window for this layer.
static void append_current_kv(void) {
  const uint32_t pos = ATTENTION_CTX - 1u;
  for (uint32_t i = 0; i < ATTENTION_KV_HEADS * ATTENTION_HEAD_DIM; i++) {
    k_cache[pos][i] = current_k[i];
    v_cache[pos][i] = current_v[i];
  }
}

// Streaming attention service baseline: append K/V, stream K to compute QK
// scores, normalize scores, then stream V to produce the weighted output.
// Phase counters keep memory/stream work visible separately from the total.
static void attention_backend(void) {
  const uint64_t service_start = t3_cycle_counter();
  uint64_t phase_start = t3_cycle_counter();
  append_current_kv();
  append_cycles += t3_cycle_counter() - phase_start;

  for (uint32_t head = 0; head < ATTENTION_HEADS; head++) {
    // Bonsai/Qwen3 uses more query heads than KV heads; multiple Q heads share
    // each streamed K/V head.
    const uint32_t kv_head = head * ATTENTION_KV_HEADS / ATTENTION_HEADS;
    float max_score = -FLT_MAX;

    // Score pass: stream K over the context window and retain scores for the
    // later value pass.
    phase_start = t3_cycle_counter();
    for (uint32_t pos = 0; pos < ATTENTION_CTX; pos++) {
      float score = 0.0f;
      for (uint32_t d = 0; d < ATTENTION_HEAD_DIM; d++) {
        const uint32_t q_idx = head * ATTENTION_HEAD_DIM + d;
        const uint32_t kv_idx = kv_head * ATTENTION_HEAD_DIM + d;
        score += q8_to_float(q[q_idx]) * q8_to_float(k_cache[pos][kv_idx]);
      }

      scores[pos] = score * ATTENTION_INV_SQRT_HEAD_DIM;
      if (scores[pos] > max_score) max_score = scores[pos];
    }
    score_cycles += t3_cycle_counter() - phase_start;

    // Normalization mode is selectable so the same stream-shaped service can
    // be measured both as traversal-only work and with stable softmax.
    phase_start = t3_cycle_counter();
#if ATTENTION_NORM_MODE == ATTENTION_NORM_NONE
    (void)max_score;
    const float inv_denom = 1.0f;
#else
    float denom = 0.0f;
    for (uint32_t pos = 0; pos < ATTENTION_CTX; pos++) {
      scores[pos] = expf(scores[pos] - max_score);
      denom += scores[pos];
    }

    const float inv_denom = denom == 0.0f ? 0.0f : 1.0f / denom;
#endif
    norm_cycles += t3_cycle_counter() - phase_start;

    // Value pass: stream V over the same context window and accumulate one
    // output vector for this query head.
    phase_start = t3_cycle_counter();
    for (uint32_t d = 0; d < ATTENTION_HEAD_DIM; d++) {
      const uint32_t out_idx = head * ATTENTION_HEAD_DIM + d;
      float acc = 0.0f;

      for (uint32_t pos = 0; pos < ATTENTION_CTX; pos++) {
        const uint32_t kv_idx = kv_head * ATTENTION_HEAD_DIM + d;
        const float weight = scores[pos] * inv_denom;
        acc += weight * q8_to_float(v_cache[pos][kv_idx]);
      }

      out[out_idx] = float_to_q8(acc);
    }
    value_cycles += t3_cycle_counter() - phase_start;
  }
  service_cycles += t3_cycle_counter() - service_start;
}

int main(void) {
  T3_SETUP();
  init_attention();

  const uint64_t start = t3_cycle_counter();
  for (uint32_t i = 0; i < ATTENTION_REPEATS; i++) {
    attention_backend();
  }
  const uint64_t end = t3_cycle_counter();

  const uint64_t score_mac_per_call = (uint64_t)ATTENTION_HEADS * ATTENTION_CTX * ATTENTION_HEAD_DIM;
  const uint64_t value_mac_per_call = (uint64_t)ATTENTION_HEADS * ATTENTION_CTX * ATTENTION_HEAD_DIM;
  const uint64_t softmax_elements_per_call = (uint64_t)ATTENTION_HEADS * ATTENTION_CTX;
  const uint64_t k_read_elements_per_call = score_mac_per_call;
  const uint64_t v_read_elements_per_call = value_mac_per_call;
  const uint64_t kv_append_elements_per_call = (uint64_t)2u * ATTENTION_KV_HEADS * ATTENTION_HEAD_DIM;
  const uint64_t kv_cache_elements = (uint64_t)2u * ATTENTION_CTX * ATTENTION_KV_HEADS * ATTENTION_HEAD_DIM;
  const uint64_t k_read_bytes_per_call = k_read_elements_per_call * sizeof(int16_t);
  const uint64_t v_read_bytes_per_call = v_read_elements_per_call * sizeof(int16_t);
  const uint64_t kv_write_bytes_per_call = kv_append_elements_per_call * sizeof(int16_t);
  const uint64_t kv_read_bytes_per_call = k_read_bytes_per_call + v_read_bytes_per_call;
  const uint64_t kv_total_bytes_per_call = kv_read_bytes_per_call + kv_write_bytes_per_call;
#if ATTENTION_NORM_MODE == ATTENTION_NORM_NONE
  const uint64_t softmax_elements_report = 0u;
#else
  const uint64_t softmax_elements_report = softmax_elements_per_call * ATTENTION_REPEATS;
#endif

  T3_PRINTF("backend=software_neorv32\n");
  T3_PRINTF("kernel=attention_kv_service\n");
  T3_PRINTF("baseline_role=software_pre_acc_reference\n");
  T3_PRINTF("counter_unit=%s\n", t3_counter_unit());
  T3_PRINTF("measured_region=kernel_only\n");
  T3_PRINTF("phase_cycles_role=software_phase_cycles_not_memory_wait\n");
  T3_PRINTF("input_source=synthetic_q8\n");
  T3_PRINTF("normalization_mode=%s\n", normalization_mode_name());
  T3_PRINTF("heads=%u\n", (uint32_t)ATTENTION_HEADS);
  T3_PRINTF("kv_heads=%u\n", (uint32_t)ATTENTION_KV_HEADS);
  T3_PRINTF("head_dim=%u\n", (uint32_t)ATTENTION_HEAD_DIM);
  T3_PRINTF("ctx=%u\n", (uint32_t)ATTENTION_CTX);
  T3_PRINTF("repeats=%u\n", (uint32_t)ATTENTION_REPEATS);
  T3_PRINTF("score_mac_per_call=%u\n", (uint32_t)score_mac_per_call);
  T3_PRINTF("value_mac_per_call=%u\n", (uint32_t)value_mac_per_call);
  T3_PRINTF("softmax_elements_per_call=%u\n", (uint32_t)softmax_elements_per_call);
  T3_PRINTF("k_read_elements_per_call=%u\n", (uint32_t)k_read_elements_per_call);
  T3_PRINTF("v_read_elements_per_call=%u\n", (uint32_t)v_read_elements_per_call);
  T3_PRINTF("kv_append_elements_per_call=%u\n", (uint32_t)kv_append_elements_per_call);
  T3_PRINTF("kv_cache_elements=%u\n", (uint32_t)kv_cache_elements);
  T3_PRINTF("k_read_bytes_per_call=%u\n", (uint32_t)k_read_bytes_per_call);
  T3_PRINTF("v_read_bytes_per_call=%u\n", (uint32_t)v_read_bytes_per_call);
  T3_PRINTF("kv_read_bytes_per_call=%u\n", (uint32_t)kv_read_bytes_per_call);
  T3_PRINTF("kv_write_bytes_per_call=%u\n", (uint32_t)kv_write_bytes_per_call);
  T3_PRINTF("kv_total_bytes_per_call=%u\n", (uint32_t)kv_total_bytes_per_call);
  T3_PRINTF("score_mac=%u\n", (uint32_t)(score_mac_per_call * ATTENTION_REPEATS));
  T3_PRINTF("value_mac=%u\n", (uint32_t)(value_mac_per_call * ATTENTION_REPEATS));
  T3_PRINTF("softmax_elements=%u\n", (uint32_t)softmax_elements_report);
  T3_PRINTF("k_read_elements=%u\n", (uint32_t)(k_read_elements_per_call * ATTENTION_REPEATS));
  T3_PRINTF("v_read_elements=%u\n", (uint32_t)(v_read_elements_per_call * ATTENTION_REPEATS));
  T3_PRINTF("kv_append_elements=%u\n", (uint32_t)(kv_append_elements_per_call * ATTENTION_REPEATS));
  T3_PRINTF("k_read_bytes=%u\n", (uint32_t)(k_read_bytes_per_call * ATTENTION_REPEATS));
  T3_PRINTF("v_read_bytes=%u\n", (uint32_t)(v_read_bytes_per_call * ATTENTION_REPEATS));
  T3_PRINTF("kv_read_bytes=%u\n", (uint32_t)(kv_read_bytes_per_call * ATTENTION_REPEATS));
  T3_PRINTF("kv_write_bytes=%u\n", (uint32_t)(kv_write_bytes_per_call * ATTENTION_REPEATS));
  T3_PRINTF("kv_total_bytes=%u\n", (uint32_t)(kv_total_bytes_per_call * ATTENTION_REPEATS));
  T3_PRINTF("append_cycles=%u\n", (uint32_t)append_cycles);
  T3_PRINTF("score_cycles=%u\n", (uint32_t)score_cycles);
  T3_PRINTF("norm_cycles=%u\n", (uint32_t)norm_cycles);
  T3_PRINTF("value_cycles=%u\n", (uint32_t)value_cycles);
  T3_PRINTF("service_cycles=%u\n", (uint32_t)service_cycles);
  T3_PRINTF("cycles=%u\n", (uint32_t)(end - start));
  T3_PRINTF("checksum=%i\n", (int32_t)t3_checksum_i16(out, ATTENTION_HEADS * ATTENTION_HEAD_DIM));
  return 0;
}

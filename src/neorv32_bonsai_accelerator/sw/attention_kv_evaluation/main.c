#include <stdint.h>

#include <neorv32.h>

#include "../bonsai_accel.h"
#include "../../../tier3_neorv32_cycle_kernels/tier3_common.h"

#ifndef ATTENTION_HEADS
#define ATTENTION_HEADS 1u
#endif
#ifndef ATTENTION_KV_HEADS
#define ATTENTION_KV_HEADS 1u
#endif
#ifndef ATTENTION_HEAD_DIM
#define ATTENTION_HEAD_DIM 32u
#endif
#ifndef ATTENTION_CTX
#define ATTENTION_CTX 2u
#endif
#ifndef EXPECTED_CHECKSUM
#error EXPECTED_CHECKSUM must match the Tier 3 compatibility profile
#endif

#define TERMINAL_MASK (BONSAI_STATUS_DONE | BONSAI_STATUS_ERROR)
#define POLL_LIMIT UINT32_C(100000000)
#define APPEND_POSITION (ATTENTION_CTX - 1u)
#define TILE_ELEMENTS BONSAI_ATTN_VECTOR_TILE_ELEMENTS
#define TILE_WORD_CAPACITY BONSAI_ATTN_VECTOR_TILE_WORDS
#define SEGMENTS ((ATTENTION_HEAD_DIM + TILE_ELEMENTS - 1u) / TILE_ELEMENTS)
#define VECTOR_WORDS ((ATTENTION_HEAD_DIM + 1u) / 2u)

#if (ATTENTION_HEAD_DIM != 16u) && (ATTENTION_HEAD_DIM != 32u) && \
    (ATTENTION_HEAD_DIM != 64u) && (ATTENTION_HEAD_DIM != 128u)
#error unsupported attention head dimension
#endif
#if (ATTENTION_HEADS % ATTENTION_KV_HEADS) != 0
#error query heads must be divisible by KV heads
#endif

static uint32_t query_payload[ATTENTION_HEADS * SEGMENTS * TILE_WORD_CAPACITY];
static uint32_t current_k_payload[ATTENTION_KV_HEADS * SEGMENTS * TILE_WORD_CAPACITY];
static uint32_t current_v_payload[ATTENTION_KV_HEADS * SEGMENTS * TILE_WORD_CAPACITY];
static uint32_t k_cache_payload[
    ATTENTION_KV_HEADS * ATTENTION_CTX * SEGMENTS * TILE_WORD_CAPACITY];
static uint32_t v_cache_payload[
    ATTENTION_KV_HEADS * ATTENTION_CTX * SEGMENTS * TILE_WORD_CAPACITY];
static int16_t actual[ATTENTION_HEADS * ATTENTION_HEAD_DIM];

struct command_metrics {
  uint32_t command_cycles;
  uint32_t engine_cycles;
  uint32_t active_cycles;
  uint32_t input_wait_cycles;
  uint32_t output_wait_cycles;
  uint32_t control_cycles;
  uint32_t frontend_input_wait;
  uint32_t frontend_output_wait;
  uint32_t input_bytes;
  uint32_t output_bytes;
  uint32_t work;
};

static uint32_t pack_i16(int16_t low, int16_t high) {
  return (uint16_t)low | ((uint32_t)(uint16_t)high << 16);
}

static unsigned int words_for_segment(unsigned int segment) {
  const unsigned int first = segment * TILE_ELEMENTS;
  const unsigned int remaining = ATTENTION_HEAD_DIM - first;
  const unsigned int elements = remaining < TILE_ELEMENTS ? remaining : TILE_ELEMENTS;
  return (elements + 1u) / 2u;
}

static unsigned int payload_offset(unsigned int tile, unsigned int word) {
  return tile * TILE_WORD_CAPACITY + word;
}

// Build the same backend-ready Q/K/V fixture used by the Tier 3 service before
// timing begins. The final cache position is supplied through CURRENT_K/V.
static void prepare_payloads(void) {
  for (unsigned int head = 0; head < ATTENTION_HEADS; ++head) {
    for (unsigned int segment = 0; segment < SEGMENTS; ++segment) {
      const unsigned int tile = head * SEGMENTS + segment;
      for (unsigned int word = 0; word < words_for_segment(segment); ++word) {
        const unsigned int element = segment * TILE_ELEMENTS + word * 2u;
        const unsigned int base = head * ATTENTION_HEAD_DIM + element;
        query_payload[payload_offset(tile, word)] = pack_i16(
            t3_input_value(base + 11u), t3_input_value(base + 12u));
      }
    }
  }

  for (unsigned int kv_head = 0; kv_head < ATTENTION_KV_HEADS; ++kv_head) {
    for (unsigned int segment = 0; segment < SEGMENTS; ++segment) {
      const unsigned int current_tile = kv_head * SEGMENTS + segment;
      for (unsigned int word = 0; word < words_for_segment(segment); ++word) {
        const unsigned int element = segment * TILE_ELEMENTS + word * 2u;
        const unsigned int base = kv_head * ATTENTION_HEAD_DIM + element;
        current_k_payload[payload_offset(current_tile, word)] = pack_i16(
            t3_input_value(base + 23u), t3_input_value(base + 24u));
        current_v_payload[payload_offset(current_tile, word)] = pack_i16(
            t3_input_value(base + 47u), t3_input_value(base + 48u));

        for (unsigned int position = 0; position < ATTENTION_CTX; ++position) {
          const unsigned int cache_tile =
              (kv_head * ATTENTION_CTX + position) * SEGMENTS + segment;
          const unsigned int seed = position == APPEND_POSITION ? 0u : position * 4096u;
          k_cache_payload[payload_offset(cache_tile, word)] = pack_i16(
              t3_input_value(seed + base + 23u),
              t3_input_value(seed + base + 24u));
          v_cache_payload[payload_offset(cache_tile, word)] = pack_i16(
              t3_input_value(seed + base + 47u),
              t3_input_value(seed + base + 48u));
        }
      }
    }
  }
}

#ifndef EVALUATE_MEM_STREAM
static const uint32_t *payload_for(unsigned int role, unsigned int tile) {
  switch (role) {
    case BONSAI_ROLE_QUERY:
      return tile < ATTENTION_HEADS * SEGMENTS
                 ? &query_payload[payload_offset(tile, 0)] : 0;
    case BONSAI_ROLE_CURRENT_K:
      return tile < ATTENTION_KV_HEADS * SEGMENTS
                 ? &current_k_payload[payload_offset(tile, 0)] : 0;
    case BONSAI_ROLE_CURRENT_V:
      return tile < ATTENTION_KV_HEADS * SEGMENTS
                 ? &current_v_payload[payload_offset(tile, 0)] : 0;
    case BONSAI_ROLE_K_CACHE:
      return tile < ATTENTION_KV_HEADS * ATTENTION_CTX * SEGMENTS
                 ? &k_cache_payload[payload_offset(tile, 0)] : 0;
    case BONSAI_ROLE_V_CACHE:
      return tile < ATTENTION_KV_HEADS * ATTENTION_CTX * SEGMENTS
                 ? &v_cache_payload[payload_offset(tile, 0)] : 0;
    default:
      return 0;
  }
}
#endif

static void read_metrics(struct command_metrics *metrics) {
  metrics->command_cycles = bonsai_accel_read(BONSAI_REG_COUNTER_COMMAND);
  metrics->engine_cycles = bonsai_accel_read(BONSAI_REG_COUNTER_ENGINE);
  metrics->active_cycles = bonsai_accel_read(BONSAI_REG_COUNTER_ACTIVE);
  metrics->input_wait_cycles = bonsai_accel_read(BONSAI_REG_COUNTER_INPUT_WAIT);
  metrics->output_wait_cycles = bonsai_accel_read(BONSAI_REG_COUNTER_OUTPUT_WAIT);
  metrics->control_cycles = bonsai_accel_read(BONSAI_REG_COUNTER_CONTROL);
  metrics->frontend_input_wait = bonsai_accel_read(BONSAI_REG_COUNTER_FRONTEND_IN);
  metrics->frontend_output_wait = bonsai_accel_read(BONSAI_REG_COUNTER_FRONTEND_OUT);
  metrics->input_bytes = bonsai_accel_read(BONSAI_REG_COUNTER_INPUT_BYTES);
  metrics->output_bytes = bonsai_accel_read(BONSAI_REG_COUNTER_OUTPUT_BYTES);
  metrics->work = bonsai_accel_read(BONSAI_REG_COUNTER_WORK);
}

#ifndef EVALUATE_MEM_STREAM
static int wait_output_word(void) {
  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    if ((bonsai_accel_read(BONSAI_REG_FIFO_STATUS) &
         BONSAI_FIFO_OUTPUT_VALID) != 0) return 1;
  }
  return 0;
}

static int service_input(unsigned int role, unsigned int tile,
                         unsigned int words) {
  const uint32_t *payload = payload_for(role, tile);
  if (payload == 0 || words != words_for_segment(tile % SEGMENTS)) return 0;
  for (unsigned int word = 0; word < words; ++word) {
    bonsai_accel_write(BONSAI_REG_FIFO_IN, payload[word]);
  }
  return 1;
}

static int service_output(unsigned int role, unsigned int tile,
                          unsigned int words) {
  if (words != words_for_segment(tile % SEGMENTS)) return 0;
  if (role == BONSAI_ROLE_CURRENT_K || role == BONSAI_ROLE_CURRENT_V) {
    const uint32_t *expected = payload_for(role, tile);
    if (expected == 0) return 0;
    for (unsigned int word = 0; word < words; ++word) {
      if (!wait_output_word() ||
          bonsai_accel_read(BONSAI_REG_FIFO_OUT) != expected[word]) return 0;
    }
    return 1;
  }
  if (role != BONSAI_ROLE_OUTPUT || tile >= ATTENTION_HEADS * SEGMENTS) return 0;

  const unsigned int head = tile / SEGMENTS;
  const unsigned int segment = tile % SEGMENTS;
  for (unsigned int word = 0; word < words; ++word) {
    if (!wait_output_word()) return 0;
    const uint32_t packed = bonsai_accel_read(BONSAI_REG_FIFO_OUT);
    const unsigned int element = segment * TILE_ELEMENTS + word * 2u;
    actual[head * ATTENTION_HEAD_DIM + element] = (int16_t)packed;
    actual[head * ATTENTION_HEAD_DIM + element + 1u] = (int16_t)(packed >> 16);
  }
  return 1;
}

static int run_command(struct command_metrics *metrics,
                       unsigned int *input_transactions,
                       unsigned int *output_transactions) {
  uint32_t terminal_status = UINT32_MAX;
  bonsai_accel_write(
      BONSAI_REG_ATTN_HEADS_DIM,
      bonsai_accel_attention_heads_dim(
          ATTENTION_HEADS, ATTENTION_KV_HEADS, ATTENTION_HEAD_DIM));
  bonsai_accel_write(
      BONSAI_REG_ATTN_CONTEXT,
      bonsai_accel_attention_context(ATTENTION_CTX, APPEND_POSITION));
  bonsai_accel_write(
      BONSAI_REG_CONFIG,
      bonsai_accel_config(BONSAI_SERVICE_ATTN_KV, BONSAI_TRANSFER_CPU_PUSH));
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_START);

  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    const uint32_t status = bonsai_accel_read(BONSAI_REG_STATUS);
    if ((status & TERMINAL_MASK) != 0) {
      terminal_status = status;
      break;
    }
    const uint32_t request = bonsai_accel_read(BONSAI_REG_REQUEST);
    if ((request & BONSAI_REQUEST_INPUT_VALID) != 0) {
      const unsigned int role =
          (request & BONSAI_REQUEST_INPUT_ROLE_MASK) >>
          BONSAI_REQUEST_INPUT_ROLE_SHIFT;
      const unsigned int tile =
          bonsai_accel_read(BONSAI_REG_REQUEST_TILE) & 0xffffu;
      const unsigned int words =
          bonsai_accel_read(BONSAI_REG_REQUEST_REMAINING) & 0xffffu;
      if (!service_input(role, tile, words)) return 0;
      ++*input_transactions;
    } else if ((request & BONSAI_REQUEST_OUTPUT_VALID) != 0) {
      const unsigned int role =
          (request & BONSAI_REQUEST_OUTPUT_ROLE_MASK) >>
          BONSAI_REQUEST_OUTPUT_ROLE_SHIFT;
      const unsigned int tile =
          bonsai_accel_read(BONSAI_REG_REQUEST_TILE) >> 16;
      const unsigned int words =
          bonsai_accel_read(BONSAI_REG_REQUEST_REMAINING) >> 16;
      if (!service_output(role, tile, words)) return 0;
      ++*output_transactions;
    }
  }

  if (terminal_status == UINT32_MAX ||
      (terminal_status & BONSAI_STATUS_DONE) == 0 ||
      (terminal_status & BONSAI_STATUS_ERROR) != 0) return 0;
  read_metrics(metrics);
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
  return bonsai_accel_read(BONSAI_REG_STATUS) == 0;
}
#else

#define TILE_STRIDE_BYTES (TILE_WORD_CAPACITY * sizeof(uint32_t))
#define QUERY_BASE_WORD 0u
#define CURRENT_K_BASE_WORD 1024u
#define CURRENT_V_BASE_WORD 2048u
#define K_CACHE_BASE_WORD 3072u
#define V_CACHE_BASE_WORD 6144u
#define OUTPUT_BASE_WORD 9216u

static int reject_missing_descriptors(void) {
  bonsai_accel_write(BONSAI_REG_ATTN_HEADS_DIM,
      bonsai_accel_attention_heads_dim(
          ATTENTION_HEADS, ATTENTION_KV_HEADS, ATTENTION_HEAD_DIM));
  bonsai_accel_write(BONSAI_REG_ATTN_CONTEXT,
      bonsai_accel_attention_context(ATTENTION_CTX, APPEND_POSITION));
  bonsai_accel_write(BONSAI_REG_CONFIG,
      bonsai_accel_config(BONSAI_SERVICE_ATTN_KV, BONSAI_TRANSFER_MEM_STREAM));
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_START);
  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    const uint32_t status = bonsai_accel_read(BONSAI_REG_STATUS);
    if ((status & TERMINAL_MASK) != 0) {
      if ((status & BONSAI_STATUS_ERROR) == 0 ||
          bonsai_accel_status_error(status) != BONSAI_ERROR_BAD_COMMAND) return 0;
      bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
      return bonsai_accel_read(BONSAI_REG_STATUS) == 0;
    }
  }
  return 0;
}

static void copy_tiles_to_memory(unsigned int base_word,
                                 const uint32_t *source,
                                 unsigned int tile_count) {
  volatile uint32_t *memory = bonsai_accel_memory_window();
  for (unsigned int tile = 0; tile < tile_count; ++tile) {
    for (unsigned int word = 0; word < TILE_WORD_CAPACITY; ++word) {
      memory[base_word + tile * TILE_WORD_CAPACITY + word] =
          source[payload_offset(tile, word)];
    }
  }
}

static void prepare_memory_descriptors(void) {
  const unsigned int query_tiles = ATTENTION_HEADS * SEGMENTS;
  const unsigned int current_tiles = ATTENTION_KV_HEADS * SEGMENTS;
  const unsigned int cache_tiles = ATTENTION_KV_HEADS * ATTENTION_CTX * SEGMENTS;
  copy_tiles_to_memory(QUERY_BASE_WORD, query_payload, query_tiles);
  copy_tiles_to_memory(CURRENT_K_BASE_WORD, current_k_payload, current_tiles);
  copy_tiles_to_memory(CURRENT_V_BASE_WORD, current_v_payload, current_tiles);
  copy_tiles_to_memory(K_CACHE_BASE_WORD, k_cache_payload, cache_tiles);
  copy_tiles_to_memory(V_CACHE_BASE_WORD, v_cache_payload, cache_tiles);

  bonsai_accel_write_descriptor(BONSAI_ROLE_QUERY, query_tiles,
      QUERY_BASE_WORD * sizeof(uint32_t), TILE_STRIDE_BYTES);
  bonsai_accel_write_descriptor(BONSAI_ROLE_CURRENT_K, current_tiles,
      CURRENT_K_BASE_WORD * sizeof(uint32_t), TILE_STRIDE_BYTES);
  bonsai_accel_write_descriptor(BONSAI_ROLE_CURRENT_V, current_tiles,
      CURRENT_V_BASE_WORD * sizeof(uint32_t), TILE_STRIDE_BYTES);
  bonsai_accel_write_descriptor(BONSAI_ROLE_K_CACHE, cache_tiles,
      K_CACHE_BASE_WORD * sizeof(uint32_t), TILE_STRIDE_BYTES);
  bonsai_accel_write_descriptor(BONSAI_ROLE_V_CACHE, cache_tiles,
      V_CACHE_BASE_WORD * sizeof(uint32_t), TILE_STRIDE_BYTES);
  bonsai_accel_write_descriptor(BONSAI_ROLE_OUTPUT, query_tiles,
      OUTPUT_BASE_WORD * sizeof(uint32_t), TILE_STRIDE_BYTES);
}

static int collect_memory_outputs(void) {
  volatile uint32_t *memory = bonsai_accel_memory_window();
  for (unsigned int head = 0; head < ATTENTION_HEADS; ++head) {
    for (unsigned int segment = 0; segment < SEGMENTS; ++segment) {
      const unsigned int tile = head * SEGMENTS + segment;
      for (unsigned int word = 0; word < words_for_segment(segment); ++word) {
        const uint32_t packed =
            memory[OUTPUT_BASE_WORD + tile * TILE_WORD_CAPACITY + word];
        const unsigned int element = segment * TILE_ELEMENTS + word * 2u;
        actual[head * ATTENTION_HEAD_DIM + element] = (int16_t)packed;
        actual[head * ATTENTION_HEAD_DIM + element + 1u] = (int16_t)(packed >> 16);
      }
    }
  }

  for (unsigned int kv_head = 0; kv_head < ATTENTION_KV_HEADS; ++kv_head) {
    for (unsigned int segment = 0; segment < SEGMENTS; ++segment) {
      const unsigned int current_tile = kv_head * SEGMENTS + segment;
      const unsigned int cache_tile =
          (kv_head * ATTENTION_CTX + APPEND_POSITION) * SEGMENTS + segment;
      for (unsigned int word = 0; word < words_for_segment(segment); ++word) {
        if (memory[K_CACHE_BASE_WORD + cache_tile * TILE_WORD_CAPACITY + word] !=
                current_k_payload[payload_offset(current_tile, word)] ||
            memory[V_CACHE_BASE_WORD + cache_tile * TILE_WORD_CAPACITY + word] !=
                current_v_payload[payload_offset(current_tile, word)]) return 0;
      }
    }
  }
  return 1;
}

static int run_command(struct command_metrics *metrics,
                       unsigned int *input_transactions,
                       unsigned int *output_transactions) {
  uint32_t terminal_status = UINT32_MAX;
  prepare_memory_descriptors();
  bonsai_accel_write(BONSAI_REG_ATTN_HEADS_DIM,
      bonsai_accel_attention_heads_dim(
          ATTENTION_HEADS, ATTENTION_KV_HEADS, ATTENTION_HEAD_DIM));
  bonsai_accel_write(BONSAI_REG_ATTN_CONTEXT,
      bonsai_accel_attention_context(ATTENTION_CTX, APPEND_POSITION));
  bonsai_accel_write(BONSAI_REG_CONFIG,
      bonsai_accel_config(BONSAI_SERVICE_ATTN_KV, BONSAI_TRANSFER_MEM_STREAM));
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_START);

  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    const uint32_t status = bonsai_accel_read(BONSAI_REG_STATUS);
    if ((status & TERMINAL_MASK) != 0) {
      terminal_status = status;
      break;
    }
  }
  if (terminal_status == UINT32_MAX ||
      (terminal_status & BONSAI_STATUS_DONE) == 0 ||
      (terminal_status & BONSAI_STATUS_ERROR) != 0) return 0;
  read_metrics(metrics);
  *input_transactions =
      (2u * ATTENTION_KV_HEADS +
       ATTENTION_HEADS * (1u + 2u * (ATTENTION_CTX - 1u))) * SEGMENTS;
  *output_transactions =
      (2u * ATTENTION_KV_HEADS + ATTENTION_HEADS) * SEGMENTS;
  if (!collect_memory_outputs()) return 0;
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
  return bonsai_accel_read(BONSAI_REG_STATUS) == 0;
}
#endif

static int32_t checksum_i16(const int16_t *values, unsigned int count) {
  int32_t checksum = 0;
  for (unsigned int i = 0; i < count; ++i) {
    checksum += (int32_t)values[i] * (int32_t)((i % 31u) + 1u);
  }
  return checksum;
}

int main(void) {
  struct command_metrics metrics = {0};
  unsigned int input_transactions = 0;
  unsigned int output_transactions = 0;
  const unsigned int input_words =
      (2u * ATTENTION_KV_HEADS +
       ATTENTION_HEADS * (1u + 2u * (ATTENTION_CTX - 1u))) * VECTOR_WORDS;
  const unsigned int output_words =
      (2u * ATTENTION_KV_HEADS + ATTENTION_HEADS) * VECTOR_WORDS;
  const unsigned int expected_input_transactions =
      (2u * ATTENTION_KV_HEADS +
       ATTENTION_HEADS * (1u + 2u * (ATTENTION_CTX - 1u))) * SEGMENTS;
  const unsigned int expected_output_transactions =
      (2u * ATTENTION_KV_HEADS + ATTENTION_HEADS) * SEGMENTS;
  const unsigned int expected_active =
      input_words + output_words +
      3u * ATTENTION_HEADS * ATTENTION_CTX +
      2u * ATTENTION_HEADS * VECTOR_WORDS;

  neorv32_uart0_setup(19200, 0);
  if (neorv32_cfs_available() == 0 ||
      bonsai_accel_read(BONSAI_REG_ID) != BONSAI_ACCEL_ID ||
      bonsai_accel_read(BONSAI_REG_VERSION) != BONSAI_ACCEL_VERSION) {
    neorv32_uart0_printf("evaluation_status=FAIL_IDENTITY\n");
    return 1;
  }
  prepare_payloads();
#ifdef EVALUATE_MEM_STREAM
  if (!reject_missing_descriptors()) {
    neorv32_uart0_printf("evaluation_status=FAIL_DESCRIPTOR_REJECT\n");
    return 1;
  }
#endif
  if (!run_command(&metrics, &input_transactions, &output_transactions)) {
    neorv32_uart0_printf("evaluation_status=FAIL_COMMAND\n");
    return 1;
  }

  const int32_t checksum =
      checksum_i16(actual, ATTENTION_HEADS * ATTENTION_HEAD_DIM);
  if (checksum != (int32_t)EXPECTED_CHECKSUM ||
      metrics.active_cycles != expected_active ||
      metrics.command_cycles < metrics.engine_cycles ||
      metrics.engine_cycles != metrics.active_cycles +
          metrics.input_wait_cycles + metrics.output_wait_cycles +
          metrics.control_cycles ||
      metrics.input_bytes != input_words * sizeof(uint32_t) ||
      metrics.output_bytes != output_words * sizeof(uint32_t) ||
      metrics.work != 2u * ATTENTION_HEADS * ATTENTION_CTX * ATTENTION_HEAD_DIM ||
      input_transactions != expected_input_transactions ||
      output_transactions != expected_output_transactions) {
    neorv32_uart0_printf("evaluation_status=FAIL_OUTPUT_OR_COUNTER\n");
    return 1;
  }

  neorv32_uart0_printf("kernel=attention_kv_engine\n");
  neorv32_uart0_printf("backend=hardware_neorv32_cfs\n");
#ifdef EVALUATE_MEM_STREAM
  neorv32_uart0_printf("transfer_mode=mem_stream\n");
  neorv32_uart0_printf("memory_strategy=descriptor_tile_stream\n");
#else
  neorv32_uart0_printf("transfer_mode=cpu_push\n");
  neorv32_uart0_printf("cpu_push_strategy=tile_burst_prepacked\n");
#endif
  neorv32_uart0_printf("input_source=synthetic_q8\n");
  neorv32_uart0_printf("normalization_mode=stable_softmax_fixed_q16\n");
  neorv32_uart0_printf("heads=%u\n", (uint32_t)ATTENTION_HEADS);
  neorv32_uart0_printf("kv_heads=%u\n", (uint32_t)ATTENTION_KV_HEADS);
  neorv32_uart0_printf("head_dim=%u\n", (uint32_t)ATTENTION_HEAD_DIM);
  neorv32_uart0_printf("ctx=%u\n", (uint32_t)ATTENTION_CTX);
  neorv32_uart0_printf("append_position=%u\n", (uint32_t)APPEND_POSITION);
  neorv32_uart0_printf("score_mac=%u\n",
                      (uint32_t)(ATTENTION_HEADS * ATTENTION_CTX * ATTENTION_HEAD_DIM));
  neorv32_uart0_printf("value_mac=%u\n",
                      (uint32_t)(ATTENTION_HEADS * ATTENTION_CTX * ATTENTION_HEAD_DIM));
  neorv32_uart0_printf("softmax_elements=%u\n",
                      (uint32_t)(ATTENTION_HEADS * ATTENTION_CTX));
  neorv32_uart0_printf("input_transactions=%u\n", input_transactions);
  neorv32_uart0_printf("output_transactions=%u\n", output_transactions);
  neorv32_uart0_printf("command_cycles=%u\n", metrics.command_cycles);
  neorv32_uart0_printf("engine_cycles=%u\n", metrics.engine_cycles);
  neorv32_uart0_printf("active_cycles=%u\n", metrics.active_cycles);
  neorv32_uart0_printf("input_wait_cycles=%u\n", metrics.input_wait_cycles);
  neorv32_uart0_printf("output_wait_cycles=%u\n", metrics.output_wait_cycles);
  neorv32_uart0_printf("control_cycles=%u\n", metrics.control_cycles);
  neorv32_uart0_printf("frontend_input_wait=%u\n", metrics.frontend_input_wait);
  neorv32_uart0_printf("frontend_output_wait=%u\n", metrics.frontend_output_wait);
  neorv32_uart0_printf("input_bytes=%u\n", metrics.input_bytes);
  neorv32_uart0_printf("output_bytes=%u\n", metrics.output_bytes);
  neorv32_uart0_printf("work_mac=%u\n", metrics.work);
  neorv32_uart0_printf("checksum=%i\n", checksum);
  neorv32_uart0_printf("expected_checksum=%i\n", (int32_t)EXPECTED_CHECKSUM);
  neorv32_uart0_printf("evaluation_status=PASS\n");
  return 0;
}

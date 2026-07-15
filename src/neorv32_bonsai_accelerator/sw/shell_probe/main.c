#include <stdint.h>

#include <neorv32.h>

#include "../bonsai_accel.h"
#include "q1_matvec_fixture.h"

#define TERMINAL_MASK (BONSAI_STATUS_DONE | BONSAI_STATUS_ERROR)
#define POLL_LIMIT UINT32_C(200000)
#define Q1_BLOCK_PIPELINE_CYCLES 3u
#define FNV_OFFSET UINT32_C(2166136261)
#define FNV_PRIME UINT32_C(16777619)

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

static int metrics_are_classified(const struct command_metrics *metrics) {
  return metrics->command_cycles >= metrics->engine_cycles &&
         metrics->engine_cycles ==
             metrics->active_cycles + metrics->input_wait_cycles +
             metrics->output_wait_cycles + metrics->control_cycles;
}

enum q1_fixture_mode {
  Q1_FIXTURE_FIXED,
  Q1_FIXTURE_BONSAI_ROW,
};

static uint32_t fixture_q8_word(enum q1_fixture_mode mode,
                                unsigned int tile,
                                unsigned int word,
                                int32_t fixed_scale_q16) {
  return mode == Q1_FIXTURE_BONSAI_ROW
             ? q1_fixture_bonsai_q8_word(tile, word)
             : q1_fixture_q8_word(
                   tile % BONSAI_Q8_BLOCKS_PER_Q1, word, fixed_scale_q16);
}

static uint32_t fixture_q1_word(enum q1_fixture_mode mode,
                                unsigned int row,
                                unsigned int group,
                                unsigned int word,
                                uint16_t fixed_weight_scale_fp16,
                                uint32_t fixed_sign_word) {
  return mode == Q1_FIXTURE_BONSAI_ROW
             ? q1_fixture_bonsai_q1_word(row, group, word)
             : q1_fixture_q1_word(word, fixed_weight_scale_fp16,
                                  fixed_sign_word);
}

static int16_t fixture_reference(enum q1_fixture_mode mode,
                                 unsigned int row,
                                 unsigned int groups,
                                 enum bonsai_accel_q1_scale_format scale_format,
                                 uint16_t fixed_weight_scale,
                                 int32_t fixed_q8_scale_q16,
                                 uint32_t fixed_sign_word) {
  return mode == Q1_FIXTURE_BONSAI_ROW
             ? q1_fixture_bonsai_reference_result(row, groups)
             : scale_format == BONSAI_Q1_SCALE_FIXED_Q8
                   ? q1_fixture_reference_result_from_q8(
                         (int32_t)(int16_t)fixed_weight_scale,
                         fixed_q8_scale_q16, fixed_sign_word)
                   : q1_fixture_reference_result(fixed_weight_scale,
                                                 fixed_q8_scale_q16,
                                                 fixed_sign_word);
}

static int run_q1_arithmetic(enum q1_fixture_mode mode,
                             uint16_t rows,
                             uint16_t groups,
                             enum bonsai_accel_q1_scale_format scale_format,
                             uint16_t weight_scale,
                             int32_t q8_scale_q16,
                             uint32_t sign_word,
                             struct command_metrics *metrics,
                             uint32_t output_words[]) {
  unsigned int q8_transaction = 0;
  unsigned int q8_word = 0;
  unsigned int q1_transaction = 0;
  unsigned int q1_word = 0;
  unsigned int output_count = 0;
  uint32_t terminal_status = UINT32_MAX;

  const uint32_t shape =
      bonsai_accel_matvec_shape(rows, groups);
  bonsai_accel_write(BONSAI_REG_MATVEC_SHAPE, shape);
  if (bonsai_accel_read(BONSAI_REG_MATVEC_SHAPE) != shape) return 0;

  bonsai_accel_write(
      BONSAI_REG_CONFIG,
      bonsai_accel_matvec_config(BONSAI_TRANSFER_CPU_PUSH, scale_format));
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_START);

  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    const uint32_t status = bonsai_accel_read(BONSAI_REG_STATUS);
    if ((status & TERMINAL_MASK) != 0) {
      terminal_status = status;
      break;
    }

    const uint32_t request = bonsai_accel_read(BONSAI_REG_REQUEST);
    const uint32_t tiles = bonsai_accel_read(BONSAI_REG_REQUEST_TILE);
    const uint32_t remaining = bonsai_accel_read(BONSAI_REG_REQUEST_REMAINING);
    const uint32_t fifo_status = bonsai_accel_read(BONSAI_REG_FIFO_STATUS);

    if ((request & BONSAI_REQUEST_INPUT_VALID) != 0 &&
        (fifo_status & BONSAI_FIFO_INPUT_READY) != 0) {
      const unsigned int role =
          (request & BONSAI_REQUEST_INPUT_ROLE_MASK) >>
          BONSAI_REQUEST_INPUT_ROLE_SHIFT;
      const unsigned int tile = tiles & 0xffffu;
      const unsigned int words_left = remaining & 0xffffu;
      uint32_t word;

      const unsigned int expected_q8_tile =
          q8_transaction % (groups * BONSAI_Q8_BLOCKS_PER_Q1);
      if (role == BONSAI_ROLE_Q8_INPUT && tile == expected_q8_tile &&
          q8_transaction < rows * groups * BONSAI_Q8_BLOCKS_PER_Q1 &&
          words_left > 0 &&
          words_left <= BONSAI_Q8_BLOCK_WORDS &&
          q8_word == BONSAI_Q8_BLOCK_WORDS - words_left) {
        word = fixture_q8_word(mode, expected_q8_tile, q8_word, q8_scale_q16);
        if (++q8_word == BONSAI_Q8_BLOCK_WORDS) {
          q8_word = 0;
          ++q8_transaction;
        }
      } else if (role == BONSAI_ROLE_Q1_WEIGHTS &&
                 tile == q1_transaction && tile < rows * groups &&
                 words_left > 0 && words_left <= BONSAI_Q1_GROUP_WORDS &&
                 q1_word == BONSAI_Q1_GROUP_WORDS - words_left) {
        word = fixture_q1_word(mode, tile / groups, tile % groups, q1_word,
                               weight_scale, sign_word);
        if (++q1_word == BONSAI_Q1_GROUP_WORDS) {
          q1_word = 0;
          ++q1_transaction;
        }
      } else {
        return 0;
      }
      bonsai_accel_write(BONSAI_REG_FIFO_IN, word);
    }

    if ((request & BONSAI_REQUEST_OUTPUT_VALID) != 0 &&
        (fifo_status & BONSAI_FIFO_OUTPUT_VALID) != 0 && output_count < rows) {
      const unsigned int role =
          (request & BONSAI_REQUEST_OUTPUT_ROLE_MASK) >>
          BONSAI_REQUEST_OUTPUT_ROLE_SHIFT;
      const unsigned int tile = tiles >> 16;
      const unsigned int words_left = remaining >> 16;
      if (role != BONSAI_ROLE_OUTPUT || tile != output_count || words_left != 1)
        return 0;
      output_words[output_count++] = bonsai_accel_read(BONSAI_REG_FIFO_OUT);
    }
  }

  if (terminal_status == UINT32_MAX ||
      (terminal_status & BONSAI_STATUS_DONE) == 0 ||
      (terminal_status & BONSAI_STATUS_ERROR) != 0 ||
      q8_transaction != rows * groups * BONSAI_Q8_BLOCKS_PER_Q1 ||
      q8_word != 0 || q1_transaction != rows * groups || q1_word != 0 ||
      output_count != rows) {
    return 0;
  }

  read_metrics(metrics);
  const int valid =
      metrics_are_classified(metrics) &&
      metrics->active_cycles ==
          rows * (groups *
                      (BONSAI_Q8_BLOCKS_PER_Q1 * BONSAI_Q8_BLOCK_WORDS +
                       BONSAI_Q1_GROUP_WORDS +
                       BONSAI_Q8_BLOCKS_PER_Q1 * Q1_BLOCK_PIPELINE_CYCLES) +
                  BONSAI_MATVEC_OUTPUT_WORDS) &&
      metrics->input_wait_cycles != 0 && metrics->output_wait_cycles == 0 &&
      metrics->frontend_input_wait != 0 && metrics->frontend_output_wait != 0 &&
      metrics->input_bytes ==
          rows * groups *
              (BONSAI_Q8_BLOCKS_PER_Q1 * BONSAI_Q8_BLOCK_WORDS +
               BONSAI_Q1_GROUP_WORDS) * sizeof(uint32_t) &&
      metrics->output_bytes == rows * sizeof(uint32_t) &&
      metrics->work == rows * groups;

  for (unsigned int row = 0; row < rows; ++row) {
    if (output_words[row] != (uint32_t)(int32_t)fixture_reference(
                                 mode, row, groups, scale_format, weight_scale,
                                 q8_scale_q16, sign_word)) {
      bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
      return 0;
    }
  }

  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
  return valid && bonsai_accel_read(BONSAI_REG_STATUS) == 0;
}

struct attention_profile {
  uint8_t heads;
  uint8_t kv_heads;
  uint16_t head_dim;
  uint16_t context;
  uint16_t append_position;
};

static unsigned int attention_segments(uint16_t head_dim) {
  return (head_dim + BONSAI_ATTN_VECTOR_TILE_ELEMENTS - 1u) /
         BONSAI_ATTN_VECTOR_TILE_ELEMENTS;
}

static unsigned int attention_segment_words(uint16_t head_dim,
                                            unsigned int segment) {
  const unsigned int first = segment * BONSAI_ATTN_VECTOR_TILE_ELEMENTS;
  const unsigned int remaining = head_dim - first;
  const unsigned int elements =
      remaining < BONSAI_ATTN_VECTOR_TILE_ELEMENTS
          ? remaining
          : BONSAI_ATTN_VECTOR_TILE_ELEMENTS;
  return (elements + 1u) / 2u;
}

static uint32_t attention_fixture_word(unsigned int role,
                                       unsigned int tile,
                                       unsigned int word) {
  return UINT32_C(0xa5a50000) ^ ((uint32_t)role << 24) ^
         ((uint32_t)tile << 8) ^ word;
}

static uint32_t attention_hash_transaction(uint32_t hash,
                                           unsigned int role,
                                           unsigned int tile,
                                           unsigned int words) {
  hash = (hash ^ role) * FNV_PRIME;
  hash = (hash ^ tile) * FNV_PRIME;
  return (hash ^ words) * FNV_PRIME;
}

static uint32_t expected_attention_input_hash(
    const struct attention_profile *profile) {
  const unsigned int segments = attention_segments(profile->head_dim);
  uint32_t hash = FNV_OFFSET;

  for (unsigned int kv_head = 0; kv_head < profile->kv_heads; ++kv_head) {
    for (unsigned int segment = 0; segment < segments; ++segment) {
      const unsigned int tile = kv_head * segments + segment;
      const unsigned int words = attention_segment_words(profile->head_dim, segment);
      hash = attention_hash_transaction(hash, BONSAI_ROLE_CURRENT_K, tile, words);
    }
    for (unsigned int segment = 0; segment < segments; ++segment) {
      const unsigned int tile = kv_head * segments + segment;
      const unsigned int words = attention_segment_words(profile->head_dim, segment);
      hash = attention_hash_transaction(hash, BONSAI_ROLE_CURRENT_V, tile, words);
    }
  }

  for (unsigned int head = 0; head < profile->heads; ++head) {
    const unsigned int kv_head = head * profile->kv_heads / profile->heads;
    for (unsigned int segment = 0; segment < segments; ++segment) {
      const unsigned int tile = head * segments + segment;
      const unsigned int words = attention_segment_words(profile->head_dim, segment);
      hash = attention_hash_transaction(hash, BONSAI_ROLE_QUERY, tile, words);
    }
    for (unsigned int position = 0; position < profile->context; ++position) {
      if (position == profile->append_position) continue;
      for (unsigned int segment = 0; segment < segments; ++segment) {
        const unsigned int tile =
            (kv_head * profile->context + position) * segments + segment;
        const unsigned int words = attention_segment_words(profile->head_dim, segment);
        hash = attention_hash_transaction(hash, BONSAI_ROLE_K_CACHE, tile, words);
      }
    }
    for (unsigned int position = 0; position < profile->context; ++position) {
      if (position == profile->append_position) continue;
      for (unsigned int segment = 0; segment < segments; ++segment) {
        const unsigned int tile =
            (kv_head * profile->context + position) * segments + segment;
        const unsigned int words = attention_segment_words(profile->head_dim, segment);
        hash = attention_hash_transaction(hash, BONSAI_ROLE_V_CACHE, tile, words);
      }
    }
  }
  return hash;
}

static uint32_t expected_attention_head_checksum(
    const struct attention_profile *profile, unsigned int selected_head) {
  const unsigned int segments = attention_segments(profile->head_dim);
  const unsigned int mapped_kv_head =
      selected_head * profile->kv_heads / profile->heads;
  uint32_t append_checksum = 0;

  for (unsigned int kv_head = 0; kv_head < profile->kv_heads; ++kv_head) {
    for (unsigned int role = BONSAI_ROLE_CURRENT_K;
         role <= BONSAI_ROLE_CURRENT_V; ++role) {
      for (unsigned int segment = 0; segment < segments; ++segment) {
        const unsigned int tile = kv_head * segments + segment;
        const unsigned int words = attention_segment_words(profile->head_dim, segment);
        for (unsigned int word = 0; word < words; ++word) {
          append_checksum ^= attention_fixture_word(role, tile, word);
        }
      }
    }
  }

  uint32_t checksum = append_checksum;
  for (unsigned int segment = 0; segment < segments; ++segment) {
    const unsigned int tile = selected_head * segments + segment;
    const unsigned int words = attention_segment_words(profile->head_dim, segment);
    for (unsigned int word = 0; word < words; ++word) {
      checksum ^= attention_fixture_word(BONSAI_ROLE_QUERY, tile, word);
    }
  }
  for (unsigned int role = BONSAI_ROLE_K_CACHE;
       role <= BONSAI_ROLE_V_CACHE; ++role) {
    for (unsigned int position = 0; position < profile->context; ++position) {
      if (position == profile->append_position) continue;
      for (unsigned int segment = 0; segment < segments; ++segment) {
        const unsigned int tile =
            (mapped_kv_head * profile->context + position) * segments + segment;
        const unsigned int words = attention_segment_words(profile->head_dim, segment);
        for (unsigned int word = 0; word < words; ++word) {
          checksum ^= attention_fixture_word(role, tile, word);
        }
      }
    }
  }
  return checksum;
}

static uint32_t expected_attention_output_hash(
    const struct attention_profile *profile) {
  const unsigned int segments = attention_segments(profile->head_dim);
  uint32_t hash = FNV_OFFSET;
  for (unsigned int kv_head = 0; kv_head < profile->kv_heads; ++kv_head) {
    for (unsigned int role = BONSAI_ROLE_CURRENT_K;
         role <= BONSAI_ROLE_CURRENT_V; ++role) {
      for (unsigned int segment = 0; segment < segments; ++segment) {
        const unsigned int tile = kv_head * segments + segment;
        const unsigned int words = attention_segment_words(profile->head_dim, segment);
        hash = attention_hash_transaction(hash, role, tile, words);
      }
    }
  }
  for (unsigned int head = 0; head < profile->heads; ++head) {
    for (unsigned int segment = 0; segment < segments; ++segment) {
      const unsigned int tile = head * segments + segment;
      const unsigned int words = attention_segment_words(profile->head_dim, segment);
      hash = attention_hash_transaction(hash, BONSAI_ROLE_OUTPUT, tile, words);
    }
  }
  return hash;
}

static int run_attention_probe(const struct attention_profile *profile,
                               struct command_metrics *metrics) {
  const unsigned int segments = attention_segments(profile->head_dim);
  const unsigned int vector_words = (profile->head_dim + 1u) / 2u;
  const unsigned int input_transactions =
      (2u * profile->kv_heads +
       profile->heads * (1u + 2u * (profile->context - 1u))) * segments;
  const unsigned int input_words =
      (2u * profile->kv_heads +
       profile->heads * (1u + 2u * (profile->context - 1u))) * vector_words;
  const unsigned int output_words =
      (2u * profile->kv_heads + profile->heads) * vector_words;
  unsigned int input_word = 0;
  unsigned int input_transaction_count = 0;
  unsigned int output_word = 0;
  unsigned int output_transaction_count = 0;
  uint32_t input_hash = FNV_OFFSET;
  uint32_t output_hash = FNV_OFFSET;
  uint32_t terminal_status = UINT32_MAX;
  const uint32_t heads_dim = bonsai_accel_attention_heads_dim(
      profile->heads, profile->kv_heads, profile->head_dim);
  const uint32_t context = bonsai_accel_attention_context(
      profile->context, profile->append_position);

  bonsai_accel_write(BONSAI_REG_ATTN_HEADS_DIM, heads_dim);
  bonsai_accel_write(BONSAI_REG_ATTN_CONTEXT, context);
  if (bonsai_accel_read(BONSAI_REG_ATTN_HEADS_DIM) != heads_dim ||
      bonsai_accel_read(BONSAI_REG_ATTN_CONTEXT) != context) return 0;

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
    const uint32_t tiles = bonsai_accel_read(BONSAI_REG_REQUEST_TILE);
    const uint32_t remaining = bonsai_accel_read(BONSAI_REG_REQUEST_REMAINING);
    const uint32_t fifo_status = bonsai_accel_read(BONSAI_REG_FIFO_STATUS);
    if ((request & BONSAI_REQUEST_INPUT_VALID) != 0 &&
        (fifo_status & BONSAI_FIFO_INPUT_READY) != 0) {
      const unsigned int role =
          (request & BONSAI_REQUEST_INPUT_ROLE_MASK) >>
          BONSAI_REQUEST_INPUT_ROLE_SHIFT;
      const unsigned int tile = tiles & 0xffffu;
      const unsigned int words_left = remaining & 0xffffu;
      const unsigned int segment = tile % segments;
      const unsigned int words = attention_segment_words(profile->head_dim, segment);
      if (role < BONSAI_ROLE_QUERY || role > BONSAI_ROLE_V_CACHE ||
          input_word >= words || words_left != words - input_word) return 0;
      if (input_word == 0) {
        input_hash = attention_hash_transaction(input_hash, role, tile, words);
        ++input_transaction_count;
      }
      bonsai_accel_write(
          BONSAI_REG_FIFO_IN,
          attention_fixture_word(role, tile, input_word));
      if (++input_word == words) input_word = 0;
    }
    if ((request & BONSAI_REQUEST_OUTPUT_VALID) != 0 &&
        (fifo_status & BONSAI_FIFO_OUTPUT_VALID) != 0) {
      const unsigned int role =
          (request & BONSAI_REQUEST_OUTPUT_ROLE_MASK) >>
          BONSAI_REQUEST_OUTPUT_ROLE_SHIFT;
      const unsigned int tile = tiles >> 16;
      const unsigned int words_left = remaining >> 16;
      const unsigned int head = tile / segments;
      const unsigned int segment = tile % segments;
      const unsigned int words = attention_segment_words(profile->head_dim, segment);
      if (output_word >= words || words_left != words - output_word) return 0;
      uint32_t expected;
      if (role == BONSAI_ROLE_CURRENT_K || role == BONSAI_ROLE_CURRENT_V) {
        if (tile >= profile->kv_heads * segments) return 0;
        expected = attention_fixture_word(role, tile, output_word);
      } else if (role == BONSAI_ROLE_OUTPUT && head < profile->heads) {
        expected = expected_attention_head_checksum(profile, head) ^
                   ((uint32_t)head << 24) ^
                   ((uint32_t)segment << 16) ^ output_word;
      } else {
        return 0;
      }
      if (bonsai_accel_read(BONSAI_REG_FIFO_OUT) != expected) return 0;
      if (output_word == 0) {
        output_hash = attention_hash_transaction(output_hash, role, tile, words);
        ++output_transaction_count;
      }
      if (++output_word == words) output_word = 0;
    }
  }

  if (terminal_status == UINT32_MAX ||
      (terminal_status & BONSAI_STATUS_DONE) == 0 ||
      (terminal_status & BONSAI_STATUS_ERROR) != 0 ||
      input_word != 0 || output_word != 0 ||
      input_transaction_count != input_transactions ||
      output_transaction_count !=
          (2u * profile->kv_heads + profile->heads) * segments ||
      input_hash != expected_attention_input_hash(profile) ||
      output_hash != expected_attention_output_hash(profile)) return 0;

  read_metrics(metrics);
  const int valid = metrics_are_classified(metrics) &&
                    metrics->active_cycles ==
                        input_words + output_words + profile->heads &&
                    metrics->input_wait_cycles != 0 &&
                    metrics->output_wait_cycles == 0 &&
                    metrics->input_bytes == input_words * sizeof(uint32_t) &&
                    metrics->output_bytes == output_words * sizeof(uint32_t) &&
                    metrics->work ==
                        2u * profile->heads * profile->context * profile->head_dim;
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
  return valid && bonsai_accel_read(BONSAI_REG_STATUS) == 0;
}

static uint32_t wait_for_terminal(void) {
  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    const uint32_t status = bonsai_accel_read(BONSAI_REG_STATUS);
    if ((status & TERMINAL_MASK) != 0) return status;
  }
  return UINT32_MAX;
}

static int rejects_bad_attention_shape(void) {
  bonsai_accel_write(
      BONSAI_REG_ATTN_HEADS_DIM,
      bonsai_accel_attention_heads_dim(2, 0, 16));
  bonsai_accel_write(
      BONSAI_REG_ATTN_CONTEXT,
      bonsai_accel_attention_context(2, 1));
  bonsai_accel_write(
      BONSAI_REG_CONFIG,
      bonsai_accel_config(BONSAI_SERVICE_ATTN_KV, BONSAI_TRANSFER_CPU_PUSH));
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_START);

  const uint32_t status = wait_for_terminal();
  const int valid = status != UINT32_MAX &&
                    (status & BONSAI_STATUS_ERROR) != 0 &&
                    bonsai_accel_status_error(status) == BONSAI_ERROR_BAD_COMMAND;
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
  return valid && bonsai_accel_read(BONSAI_REG_STATUS) == 0;
}

static void print_metrics(const char *prefix,
                          const struct command_metrics *metrics) {
  neorv32_uart0_printf(
      "%s_cycles command=%u engine=%u active=%u input_wait=%u output_wait=%u control=%u\n",
      prefix, metrics->command_cycles, metrics->engine_cycles,
      metrics->active_cycles, metrics->input_wait_cycles,
      metrics->output_wait_cycles, metrics->control_cycles);
  neorv32_uart0_printf(
      "%s_frontend input_wait=%u output_wait=%u input_bytes=%u output_bytes=%u work=%u\n",
      prefix, metrics->frontend_input_wait, metrics->frontend_output_wait,
      metrics->input_bytes, metrics->output_bytes, metrics->work);
}

int main(void) {
  struct command_metrics q1_base_metrics = {0};
  struct command_metrics q1_saturation_metrics = {0};
  struct command_metrics q1_bonsai_row_metrics = {0};
  struct command_metrics q1_multi_row_metrics = {0};
  struct command_metrics attention_board_metrics = {0};
  struct command_metrics attention_gqa_metrics = {0};
  const struct attention_profile attention_board = {
      .heads = 1, .kv_heads = 1, .head_dim = 32,
      .context = 2, .append_position = 1};
  const struct attention_profile attention_gqa = {
      .heads = 2, .kv_heads = 1, .head_dim = 16,
      .context = 2, .append_position = 1};
  uint32_t q1_base_output[1] = {0};
  uint32_t q1_saturation_output[1] = {0};
  uint32_t q1_bonsai_row_output[1] = {0};
  uint32_t q1_multi_row_output[Q1_FIXTURE_MULTI_ROWS] = {0};

  neorv32_uart0_setup(19200, 0);
  neorv32_uart0_printf("bonsai_shell_probe\n");

  if (neorv32_cfs_available() == 0 ||
      bonsai_accel_read(BONSAI_REG_ID) != BONSAI_ACCEL_ID ||
      bonsai_accel_read(BONSAI_REG_VERSION) != BONSAI_ACCEL_VERSION) {
    neorv32_uart0_printf("shell_probe=FAIL reason=identity\n");
    return 1;
  }

  const int16_t base_reference = q1_fixture_reference_result_from_q8(
      Q1_FIXTURE_WEIGHT_SCALE_FIXED_Q8, Q1_FIXTURE_Q8_SCALE_Q16,
      Q1_FIXTURE_SIGN_WORD);
  const int16_t saturation_reference = q1_fixture_reference_result(
      Q1_FIXTURE_WEIGHT_SCALE_FP16, Q1_FIXTURE_SATURATING_Q8_SCALE_Q16,
      Q1_FIXTURE_SIGN_WORD);
  const int16_t bonsai_row_reference =
      q1_fixture_bonsai_reference_result(0, Q1_FIXTURE_BONSAI_GROUPS);
  if (base_reference != 64 || saturation_reference != 32767 ||
      !run_q1_arithmetic(
          Q1_FIXTURE_FIXED, Q1_FIXTURE_ROWS, Q1_FIXTURE_GROUPS,
          BONSAI_Q1_SCALE_FIXED_Q8, Q1_FIXTURE_WEIGHT_SCALE_FIXED_Q8,
          Q1_FIXTURE_Q8_SCALE_Q16,
          Q1_FIXTURE_SIGN_WORD, &q1_base_metrics, q1_base_output) ||
      !run_q1_arithmetic(
          Q1_FIXTURE_FIXED, Q1_FIXTURE_ROWS, Q1_FIXTURE_GROUPS,
          BONSAI_Q1_SCALE_FP16, Q1_FIXTURE_WEIGHT_SCALE_FP16,
          Q1_FIXTURE_SATURATING_Q8_SCALE_Q16,
          Q1_FIXTURE_SIGN_WORD, &q1_saturation_metrics,
          q1_saturation_output) ||
      !run_q1_arithmetic(
          Q1_FIXTURE_BONSAI_ROW, Q1_FIXTURE_ROWS, Q1_FIXTURE_BONSAI_GROUPS,
          BONSAI_Q1_SCALE_FP16, 0, 0, 0,
          &q1_bonsai_row_metrics, q1_bonsai_row_output) ||
      !run_q1_arithmetic(
          Q1_FIXTURE_BONSAI_ROW, Q1_FIXTURE_MULTI_ROWS,
          Q1_FIXTURE_MULTI_GROUPS, BONSAI_Q1_SCALE_FP16, 0, 0, 0,
          &q1_multi_row_metrics, q1_multi_row_output) ||
      !run_attention_probe(&attention_board, &attention_board_metrics) ||
      !run_attention_probe(&attention_gqa, &attention_gqa_metrics) ||
      !rejects_bad_attention_shape()) {
    neorv32_uart0_printf("shell_probe=FAIL reason=cpu_push\n");
    return 1;
  }

  bonsai_accel_write(
      BONSAI_REG_CONFIG,
      bonsai_accel_config(BONSAI_SERVICE_Q1_MATVEC, BONSAI_TRANSFER_MEM_STREAM));
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_START);
  const uint32_t unsupported_status = wait_for_terminal();
  const enum bonsai_accel_error unsupported_error =
      bonsai_accel_status_error(unsupported_status);
  if (unsupported_status == UINT32_MAX ||
      (unsupported_status & BONSAI_STATUS_ERROR) == 0 ||
      unsupported_error != BONSAI_ERROR_UNSUPPORTED_MODE) {
    neorv32_uart0_printf("shell_probe=FAIL reason=unsupported_mode\n");
    return 1;
  }
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);

  neorv32_uart0_printf("accelerator_id=0x%x\n", BONSAI_ACCEL_ID);
  neorv32_uart0_printf("interface_version=0x%x\n", BONSAI_ACCEL_VERSION);
  neorv32_uart0_printf(
      "q1_base reference=%i output=%i checksum=0x%x\n",
      (int32_t)base_reference, (int32_t)q1_base_output[0],
      q1_fixture_transport_checksum(
          Q1_FIXTURE_WEIGHT_SCALE_FIXED_Q8, Q1_FIXTURE_Q8_SCALE_Q16,
          Q1_FIXTURE_SIGN_WORD));
  neorv32_uart0_printf("q1_saturation reference=%i output=%i\n",
                      (int32_t)saturation_reference,
                      (int32_t)q1_saturation_output[0]);
  neorv32_uart0_printf(
      "q1_bonsai_row groups=%u elements=%u reference=%i output=%i\n",
      Q1_FIXTURE_BONSAI_GROUPS,
      Q1_FIXTURE_BONSAI_GROUPS * BONSAI_Q1_GROUP_ELEMENTS,
      (int32_t)bonsai_row_reference, (int32_t)q1_bonsai_row_output[0]);
  neorv32_uart0_printf(
      "q1_multi_row rows=%u groups=%u outputs=%i,%i,%i\n",
      Q1_FIXTURE_MULTI_ROWS, Q1_FIXTURE_MULTI_GROUPS,
      (int32_t)q1_multi_row_output[0], (int32_t)q1_multi_row_output[1],
      (int32_t)q1_multi_row_output[2]);
  print_metrics("q1_base", &q1_base_metrics);
  print_metrics("q1_saturation", &q1_saturation_metrics);
  print_metrics("q1_bonsai_row", &q1_bonsai_row_metrics);
  print_metrics("q1_multi_row", &q1_multi_row_metrics);
  print_metrics("attention_board", &attention_board_metrics);
  print_metrics("attention_gqa", &attention_gqa_metrics);
  neorv32_uart0_printf("attention_board heads=1 kv_heads=1 head_dim=32 ctx=2 append=1\n");
  neorv32_uart0_printf("attention_gqa heads=2 kv_heads=1 head_dim=16 ctx=2 append=1\n");
  neorv32_uart0_printf("attention_bad_shape_error=%u\n", (uint32_t)BONSAI_ERROR_BAD_COMMAND);
  neorv32_uart0_printf("unsupported_mode_error=%u\n", (uint32_t)unsupported_error);
  neorv32_uart0_printf("shell_probe=PASS\n");
  return 0;
}

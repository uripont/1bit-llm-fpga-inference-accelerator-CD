#include <stdint.h>

#include <neorv32.h>

#include "../bonsai_accel.h"

#ifndef Q1_ROWS
#define Q1_ROWS 1u
#endif

#ifndef Q1_COLS
#define Q1_COLS 128u
#endif

#ifndef TIER3_USE_GGUF_FIXTURE
#define TIER3_USE_GGUF_FIXTURE 0
#endif

#if TIER3_USE_GGUF_FIXTURE
#include "../../../tier3_neorv32_cycle_kernels/generated/tier3_bonsai_fixture.h"
#define Q1_INPUT_SOURCE "gguf_fixture_packed"
#else
#define Q1_INPUT_SOURCE "synthetic_packed"
#endif

#define TERMINAL_MASK (BONSAI_STATUS_DONE | BONSAI_STATUS_ERROR)
#define POLL_LIMIT UINT32_C(100000000)
#define Q1_SEED 17u
#define Q1_GROUP_ELEMENTS 128u
#define Q8_BLOCK_ELEMENTS 32u
#define Q8_BLOCKS_PER_GROUP 4u
#define Q8_BLOCK_WORDS 9u
#define Q1_GROUP_WORDS 5u
#define Q1_GROUPS_PER_ROW (Q1_COLS / Q1_GROUP_ELEMENTS)
#define Q8_BLOCK_COUNT (Q1_COLS / Q8_BLOCK_ELEMENTS)
#define Q8_PAYLOAD_WORDS (Q8_BLOCK_COUNT * Q8_BLOCK_WORDS)
#define Q1_PAYLOAD_WORDS (Q1_ROWS * Q1_GROUPS_PER_ROW * Q1_GROUP_WORDS)

#if (Q1_COLS % Q1_GROUP_ELEMENTS) != 0
#error Q1_COLS must be a multiple of 128
#endif

static int16_t actual[Q1_ROWS];
static uint32_t q8_payload[Q8_PAYLOAD_WORDS];
static uint32_t q1_payload[Q1_PAYLOAD_WORDS];
#ifndef EXPECTED_CHECKSUM
static int16_t expected[Q1_ROWS];
#endif

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

#if TIER3_USE_GGUF_FIXTURE
static uint16_t read_u16_le(const uint8_t *bytes) {
  return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t read_u32_le(const uint8_t *bytes) {
  return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
         ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

#ifndef EXPECTED_CHECKSUM
static int32_t fp16_to_q8(uint16_t h) {
  const int32_t sign = (h & 0x8000u) ? -1 : 1;
  int32_t exponent = (int32_t)((h >> 10) & 0x1fu);
  int32_t mantissa = (int32_t)(h & 0x03ffu);
  int32_t value_q8;

  if (exponent == 0) {
    value_q8 = mantissa == 0 ? 0 : ((mantissa * 256) >> 24);
  } else if (exponent == 31) {
    value_q8 = 0;
  } else {
    mantissa |= 0x0400;
    exponent -= 15;
    value_q8 = mantissa * 256;
    value_q8 = exponent >= 10 ? value_q8 << (exponent - 10)
                              : value_q8 >> (10 - exponent);
  }
  return sign * value_q8;
}
#endif
#endif

static int32_t q8_scale_q16(unsigned int block) {
  return 256 + (int32_t)((block * 17u) & 127u);
}

static int8_t q8_value(unsigned int index) {
  return (int8_t)((int32_t)((index * 19u + 3u) % 255u) - 127);
}

#if TIER3_USE_GGUF_FIXTURE
static const uint8_t *q1_block(unsigned int row, unsigned int group) {
  const uint8_t *bytes = Q1_COLS == 6144u
      ? T3_Q1_6144_ROWS[(row + Q1_SEED) % T3_Q1_6144_ROW_COUNT]
      : T3_Q1_2048_ROWS[(row + Q1_SEED) % T3_Q1_2048_ROW_COUNT];
  return bytes + group * 18u;
}
#endif

static uint16_t q1_scale_payload(unsigned int row, unsigned int group) {
#if TIER3_USE_GGUF_FIXTURE
  return read_u16_le(q1_block(row, group));
#else
  return (uint16_t)(64u + ((row * 13u + group * 7u + Q1_SEED) & 63u));
#endif
}

#ifndef EXPECTED_CHECKSUM
static int32_t q1_scale_q8(unsigned int row, unsigned int group) {
#if TIER3_USE_GGUF_FIXTURE
  return fp16_to_q8(q1_scale_payload(row, group));
#else
  return (int32_t)(int16_t)q1_scale_payload(row, group);
#endif
}
#endif

static uint32_t q1_sign_word(unsigned int row,
                             unsigned int group,
                             unsigned int word) {
#if TIER3_USE_GGUF_FIXTURE
  return read_u32_le(q1_block(row, group) + 2u + word * 4u);
#else
  uint32_t packed = 0;
  for (unsigned int bit = 0; bit < 32u; ++bit) {
    const uint32_t col = group * Q1_GROUP_ELEMENTS + word * 32u + bit;
    const uint32_t sign =
        ((row * UINT32_C(1103515245)) ^ (col * UINT32_C(12345)) ^ Q1_SEED) >> 31;
    packed |= sign << bit;
  }
  return packed;
#endif
}

static uint32_t q8_transport_word(unsigned int tile, unsigned int word) {
  if (word == 0) return (uint32_t)q8_scale_q16(tile);

  uint32_t packed = 0;
  const unsigned int first = tile * Q8_BLOCK_ELEMENTS + (word - 1u) * 4u;
  for (unsigned int byte = 0; byte < 4u; ++byte) {
    packed |= (uint32_t)(uint8_t)q8_value(first + byte) << (byte * 8u);
  }
  return packed;
}

static uint32_t q1_transport_word(unsigned int tile, unsigned int word) {
  const unsigned int row = tile / Q1_GROUPS_PER_ROW;
  const unsigned int group = tile % Q1_GROUPS_PER_ROW;
  return word == 0 ? (uint32_t)q1_scale_payload(row, group)
                   : q1_sign_word(row, group, word - 1u);
}

// Tier 3 starts with packed Q1_0 and prequantized Q8_0 records already in
// memory. Build the equivalent CPU_PUSH image before launching the command so
// the measured service contains transport and acceleration, rather than test
// fixture generation.
static void prepare_payloads(void) {
  for (unsigned int tile = 0; tile < Q8_BLOCK_COUNT; ++tile) {
    for (unsigned int word = 0; word < Q8_BLOCK_WORDS; ++word) {
      q8_payload[tile * Q8_BLOCK_WORDS + word] =
          q8_transport_word(tile, word);
    }
  }
  for (unsigned int tile = 0; tile < Q1_ROWS * Q1_GROUPS_PER_ROW; ++tile) {
    for (unsigned int word = 0; word < Q1_GROUP_WORDS; ++word) {
      q1_payload[tile * Q1_GROUP_WORDS + word] =
          q1_transport_word(tile, word);
    }
  }
}

#ifndef EXPECTED_CHECKSUM
static int16_t reference_row(unsigned int row) {
  int64_t accumulator = 0;
  for (unsigned int group = 0; group < Q1_GROUPS_PER_ROW; ++group) {
    const int32_t weight_scale = q1_scale_q8(row, group);
    for (unsigned int block = 0; block < Q8_BLOCKS_PER_GROUP; ++block) {
      const unsigned int q8_block = group * Q8_BLOCKS_PER_GROUP + block;
      const uint32_t signs = q1_sign_word(row, group, block);
      int32_t sum = 0;
      for (unsigned int lane = 0; lane < Q8_BLOCK_ELEMENTS; ++lane) {
        const int32_t value = q8_value(q8_block * Q8_BLOCK_ELEMENTS + lane);
        sum += ((signs >> lane) & 1u) ? value : -value;
      }
      accumulator += ((int64_t)weight_scale * q8_scale_q16(q8_block) * sum) >> 16;
    }
  }

  if (accumulator > 32767) return 32767;
  if (accumulator < -32768) return -32768;
  return (int16_t)accumulator;
}
#endif

static int32_t checksum_i16(const int16_t *values, unsigned int count) {
  int32_t checksum = 0;
  for (unsigned int i = 0; i < count; ++i) {
    checksum += (int32_t)values[i] * (int32_t)((i % 31u) + 1u);
  }
  return checksum;
}

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

static int wait_input_tile(unsigned int expected_role,
                           unsigned int expected_tile,
                           unsigned int expected_words) {
  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    const uint32_t request = bonsai_accel_read(BONSAI_REG_REQUEST);
    if ((request & BONSAI_REQUEST_INPUT_VALID) != 0) {
      const unsigned int role =
          (request & BONSAI_REQUEST_INPUT_ROLE_MASK) >>
          BONSAI_REQUEST_INPUT_ROLE_SHIFT;
      const uint32_t tiles = bonsai_accel_read(BONSAI_REG_REQUEST_TILE);
      const uint32_t remaining =
          bonsai_accel_read(BONSAI_REG_REQUEST_REMAINING);
      return role == expected_role &&
             (tiles & 0xffffu) == expected_tile &&
             (remaining & 0xffffu) == expected_words;
    }
  }
  return 0;
}

static int push_input_tile(unsigned int role,
                           unsigned int tile,
                           const uint32_t *payload,
                           unsigned int words) {
  if (!wait_input_tile(role, tile, words)) return 0;

  // CFS stores are slower than the one-word-per-cycle frontend drain. Once a
  // tile request is active, consecutive MMIO writes remain within the
  // two-word FIFO capacity without per-word status polling.
  for (unsigned int word = 0; word < words; ++word) {
    bonsai_accel_write(BONSAI_REG_FIFO_IN, payload[word]);
  }
  return 1;
}

static int read_output_tile(unsigned int expected_tile, int16_t *value) {
  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    const uint32_t request = bonsai_accel_read(BONSAI_REG_REQUEST);
    if ((request & BONSAI_REQUEST_OUTPUT_VALID) != 0) {
      const unsigned int role =
          (request & BONSAI_REQUEST_OUTPUT_ROLE_MASK) >>
          BONSAI_REQUEST_OUTPUT_ROLE_SHIFT;
      const uint32_t tiles = bonsai_accel_read(BONSAI_REG_REQUEST_TILE);
      const uint32_t remaining =
          bonsai_accel_read(BONSAI_REG_REQUEST_REMAINING);
      if (role != BONSAI_ROLE_OUTPUT ||
          (tiles >> 16) != expected_tile ||
          (remaining >> 16) != 1u) {
        return 0;
      }
      while ((bonsai_accel_read(BONSAI_REG_FIFO_STATUS) &
              BONSAI_FIFO_OUTPUT_VALID) == 0) {
      }
      *value = (int16_t)bonsai_accel_read(BONSAI_REG_FIFO_OUT);
      return 1;
    }
  }
  return 0;
}

static int run_command(struct command_metrics *metrics) {
  uint32_t terminal_status = UINT32_MAX;

#if TIER3_USE_GGUF_FIXTURE
  const enum bonsai_accel_q1_scale_format scale_format = BONSAI_Q1_SCALE_FP16;
#else
  const enum bonsai_accel_q1_scale_format scale_format = BONSAI_Q1_SCALE_FIXED_Q8;
#endif

  bonsai_accel_write(
      BONSAI_REG_MATVEC_SHAPE,
      bonsai_accel_matvec_shape(Q1_ROWS, Q1_GROUPS_PER_ROW));
  bonsai_accel_write(
      BONSAI_REG_CONFIG,
      bonsai_accel_matvec_config(BONSAI_TRANSFER_CPU_PUSH, scale_format));
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_START);

  for (unsigned int row = 0; row < Q1_ROWS; ++row) {
    for (unsigned int group = 0; group < Q1_GROUPS_PER_ROW; ++group) {
      for (unsigned int block = 0; block < Q8_BLOCKS_PER_GROUP; ++block) {
        const unsigned int tile = group * Q8_BLOCKS_PER_GROUP + block;
        if (!push_input_tile(
                BONSAI_ROLE_Q8_INPUT, tile,
                &q8_payload[tile * Q8_BLOCK_WORDS], Q8_BLOCK_WORDS)) {
          return 0;
        }
      }
      const unsigned int tile = row * Q1_GROUPS_PER_ROW + group;
      if (!push_input_tile(
              BONSAI_ROLE_Q1_WEIGHTS, tile,
              &q1_payload[tile * Q1_GROUP_WORDS], Q1_GROUP_WORDS)) {
        return 0;
      }
    }
    if (!read_output_tile(row, &actual[row])) return 0;
  }

  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    terminal_status = bonsai_accel_read(BONSAI_REG_STATUS);
    if ((terminal_status & TERMINAL_MASK) != 0) break;
  }

  if (terminal_status == UINT32_MAX ||
      (terminal_status & BONSAI_STATUS_DONE) == 0 ||
      (terminal_status & BONSAI_STATUS_ERROR) != 0) {
    return 0;
  }

  read_metrics(metrics);
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
  return bonsai_accel_read(BONSAI_REG_STATUS) == 0;
}

int main(void) {
  struct command_metrics metrics = {0};

  neorv32_uart0_setup(19200, 0);
  if (neorv32_cfs_available() == 0 ||
      bonsai_accel_read(BONSAI_REG_ID) != BONSAI_ACCEL_ID ||
      bonsai_accel_read(BONSAI_REG_VERSION) != BONSAI_ACCEL_VERSION) {
    neorv32_uart0_printf("evaluation_status=FAIL_IDENTITY\n");
    return 1;
  }

#ifndef EXPECTED_CHECKSUM
  for (unsigned int row = 0; row < Q1_ROWS; ++row) {
    expected[row] = reference_row(row);
  }
#endif
  prepare_payloads();

  if (!run_command(&metrics)) {
    neorv32_uart0_printf("evaluation_status=FAIL_COMMAND\n");
    return 1;
  }

#ifndef EXPECTED_CHECKSUM
  for (unsigned int row = 0; row < Q1_ROWS; ++row) {
    if (actual[row] != expected[row]) {
      neorv32_uart0_printf("evaluation_status=FAIL_OUTPUT\n");
      return 1;
    }
  }
#else
  if (checksum_i16(actual, Q1_ROWS) != (int32_t)EXPECTED_CHECKSUM) {
    neorv32_uart0_printf("evaluation_status=FAIL_OUTPUT\n");
    return 1;
  }
#endif

  neorv32_uart0_printf("kernel=q1_matvec_engine\n");
  neorv32_uart0_printf("backend=hardware_neorv32_cfs\n");
  neorv32_uart0_printf("transfer_mode=cpu_push\n");
  neorv32_uart0_printf("cpu_push_strategy=tile_burst_prepacked\n");
  neorv32_uart0_printf("q1_input_source=%s\n", Q1_INPUT_SOURCE);
#if TIER3_USE_GGUF_FIXTURE
  neorv32_uart0_printf("q1_scale_format=fp16\n");
#else
  neorv32_uart0_printf("q1_scale_format=fixed_q8\n");
#endif
  neorv32_uart0_printf("rows=%u\n", (uint32_t)Q1_ROWS);
  neorv32_uart0_printf("cols=%u\n", (uint32_t)Q1_COLS);
  neorv32_uart0_printf("q1_group=%u\n", Q1_GROUP_ELEMENTS);
  neorv32_uart0_printf("q8_block=%u\n", Q8_BLOCK_ELEMENTS);
  neorv32_uart0_printf("dot_elements=%u\n", (uint32_t)(Q1_ROWS * Q1_COLS));
  neorv32_uart0_printf("q1_groups=%u\n", (uint32_t)(Q1_ROWS * Q1_GROUPS_PER_ROW));
  neorv32_uart0_printf("activation_q8_blocks=%u\n", (uint32_t)(Q1_COLS / Q8_BLOCK_ELEMENTS));
  neorv32_uart0_printf("physical_q8_block_transfers=%u\n",
                      (uint32_t)(Q1_ROWS * Q1_COLS / Q8_BLOCK_ELEMENTS));
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
  neorv32_uart0_printf("work_groups=%u\n", metrics.work);
  neorv32_uart0_printf("checksum=%i\n", checksum_i16(actual, Q1_ROWS));
#ifdef EXPECTED_CHECKSUM
  neorv32_uart0_printf("expected_checksum=%i\n", (int32_t)EXPECTED_CHECKSUM);
#else
  neorv32_uart0_printf("expected_checksum=%i\n", checksum_i16(expected, Q1_ROWS));
#endif
  neorv32_uart0_printf("evaluation_status=PASS\n");
  return 0;
}

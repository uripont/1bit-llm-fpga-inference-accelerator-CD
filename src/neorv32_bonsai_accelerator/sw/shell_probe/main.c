#include <stdint.h>

#include <neorv32.h>

#include "../bonsai_accel.h"
#include "q1_matvec_fixture.h"

#define TERMINAL_MASK (BONSAI_STATUS_DONE | BONSAI_STATUS_ERROR)
#define POLL_LIMIT UINT32_C(200000)
#define TEST_WORDS 4u

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

static int run_q1_contract(struct command_metrics *metrics,
                           uint32_t *output_word) {
  unsigned int q8_words[BONSAI_Q8_BLOCKS_PER_Q1] = {0};
  unsigned int q1_words = 0;
  unsigned int output_words = 0;
  uint32_t terminal_status = UINT32_MAX;

  const uint32_t shape =
      bonsai_accel_matvec_shape(Q1_FIXTURE_ROWS, Q1_FIXTURE_GROUPS);
  bonsai_accel_write(BONSAI_REG_MATVEC_SHAPE, shape);
  if (bonsai_accel_read(BONSAI_REG_MATVEC_SHAPE) != shape) return 0;

  bonsai_accel_write(
      BONSAI_REG_CONFIG,
      bonsai_accel_config(BONSAI_SERVICE_Q1_MATVEC, BONSAI_TRANSFER_CPU_PUSH));
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

      if (role == BONSAI_ROLE_Q8_INPUT &&
          tile < BONSAI_Q8_BLOCKS_PER_Q1 && words_left > 0 &&
          words_left <= BONSAI_Q8_BLOCK_WORDS &&
          q8_words[tile] == BONSAI_Q8_BLOCK_WORDS - words_left) {
        word = q1_fixture_q8_word(tile, q8_words[tile]++);
      } else if (role == BONSAI_ROLE_Q1_WEIGHTS && tile == 0 &&
                 words_left > 0 && words_left <= BONSAI_Q1_GROUP_WORDS &&
                 q1_words == BONSAI_Q1_GROUP_WORDS - words_left) {
        word = q1_fixture_q1_word(q1_words++);
      } else {
        return 0;
      }
      bonsai_accel_write(BONSAI_REG_FIFO_IN, word);
    }

    if ((request & BONSAI_REQUEST_OUTPUT_VALID) != 0 &&
        (fifo_status & BONSAI_FIFO_OUTPUT_VALID) != 0 && output_words == 0) {
      const unsigned int role =
          (request & BONSAI_REQUEST_OUTPUT_ROLE_MASK) >>
          BONSAI_REQUEST_OUTPUT_ROLE_SHIFT;
      const unsigned int tile = tiles >> 16;
      const unsigned int words_left = remaining >> 16;
      if (role != BONSAI_ROLE_OUTPUT || tile != 0 || words_left != 1) return 0;
      *output_word = bonsai_accel_read(BONSAI_REG_FIFO_OUT);
      ++output_words;
    }
  }

  if (terminal_status == UINT32_MAX ||
      (terminal_status & BONSAI_STATUS_DONE) == 0 ||
      (terminal_status & BONSAI_STATUS_ERROR) != 0 || q1_words != 5 ||
      output_words != 1) {
    return 0;
  }
  for (unsigned int block = 0; block < BONSAI_Q8_BLOCKS_PER_Q1; ++block) {
    if (q8_words[block] != BONSAI_Q8_BLOCK_WORDS) return 0;
  }

  read_metrics(metrics);
  const int valid =
      metrics_are_classified(metrics) &&
      metrics->active_cycles ==
          BONSAI_Q8_BLOCKS_PER_Q1 * BONSAI_Q8_BLOCK_WORDS +
              BONSAI_Q1_GROUP_WORDS + BONSAI_MATVEC_OUTPUT_WORDS &&
      metrics->input_wait_cycles != 0 && metrics->output_wait_cycles == 0 &&
      metrics->frontend_input_wait != 0 && metrics->frontend_output_wait != 0 &&
      metrics->input_bytes ==
          (BONSAI_Q8_BLOCKS_PER_Q1 * BONSAI_Q8_BLOCK_WORDS +
           BONSAI_Q1_GROUP_WORDS) * sizeof(uint32_t) &&
      metrics->output_bytes == sizeof(uint32_t) && metrics->work == 0 &&
      *output_word == (uint32_t)(int32_t)q1_fixture_reference_result();

  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
  return valid && bonsai_accel_read(BONSAI_REG_STATUS) == 0;
}

static int run_attention_probe(struct command_metrics *metrics) {
  static const uint32_t input[TEST_WORDS] = {
      UINT32_C(0x10), UINT32_C(0x20), UINT32_C(0x30), UINT32_C(0x40)};
  uint32_t output[TEST_WORDS] = {0};
  unsigned int input_index = 0;
  unsigned int output_index = 0;
  uint32_t terminal_status = UINT32_MAX;

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
    const uint32_t fifo_status = bonsai_accel_read(BONSAI_REG_FIFO_STATUS);
    if ((request & BONSAI_REQUEST_INPUT_VALID) != 0 &&
        (fifo_status & BONSAI_FIFO_INPUT_READY) != 0 &&
        input_index < TEST_WORDS) {
      bonsai_accel_write(BONSAI_REG_FIFO_IN, input[input_index++]);
    }
    if ((request & BONSAI_REQUEST_OUTPUT_VALID) != 0 &&
        (fifo_status & BONSAI_FIFO_OUTPUT_VALID) != 0 &&
        output_index < TEST_WORDS) {
      output[output_index++] = bonsai_accel_read(BONSAI_REG_FIFO_OUT);
    }
  }

  if (terminal_status == UINT32_MAX ||
      (terminal_status & BONSAI_STATUS_DONE) == 0 ||
      (terminal_status & BONSAI_STATUS_ERROR) != 0 ||
      input_index != TEST_WORDS || output_index != TEST_WORDS) return 0;

  uint32_t accumulator = 0;
  for (unsigned int i = 0; i < TEST_WORDS; ++i) accumulator ^= input[i];
  for (unsigned int i = 0; i < TEST_WORDS; ++i) {
    if (output[i] != accumulator + i) return 0;
  }

  read_metrics(metrics);
  const int valid = metrics_are_classified(metrics) &&
                    metrics->active_cycles == TEST_WORDS * 2u &&
                    metrics->output_wait_cycles == 0 &&
                    metrics->input_bytes == TEST_WORDS * sizeof(uint32_t) &&
                    metrics->output_bytes == TEST_WORDS * sizeof(uint32_t) &&
                    metrics->work == 1;
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
  struct command_metrics q1_metrics = {0};
  struct command_metrics attention_metrics = {0};
  uint32_t q1_output_word = 0;

  neorv32_uart0_setup(19200, 0);
  neorv32_uart0_printf("bonsai_shell_probe\n");

  if (neorv32_cfs_available() == 0 ||
      bonsai_accel_read(BONSAI_REG_ID) != BONSAI_ACCEL_ID ||
      bonsai_accel_read(BONSAI_REG_VERSION) != BONSAI_ACCEL_VERSION) {
    neorv32_uart0_printf("shell_probe=FAIL reason=identity\n");
    return 1;
  }

  const int16_t reference_result = q1_fixture_reference_result();
  if (reference_result != 64 ||
      !run_q1_contract(&q1_metrics, &q1_output_word) ||
      !run_attention_probe(&attention_metrics)) {
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
      "q1_fixture rows=1 groups=1 elements=128 reference=%i output=%i checksum=0x%x\n",
      (int32_t)reference_result, (int32_t)q1_output_word,
      q1_fixture_transport_checksum());
  print_metrics("q1_contract", &q1_metrics);
  print_metrics("attention_probe", &attention_metrics);
  neorv32_uart0_printf("unsupported_mode_error=%u\n", (uint32_t)unsupported_error);
  neorv32_uart0_printf("shell_probe=PASS\n");
  return 0;
}

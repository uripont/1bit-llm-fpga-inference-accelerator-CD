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
                                 uint16_t fixed_weight_scale_fp16,
                                 int32_t fixed_q8_scale_q16,
                                 uint32_t fixed_sign_word) {
  return mode == Q1_FIXTURE_BONSAI_ROW
             ? q1_fixture_bonsai_reference_result(row, groups)
             : q1_fixture_reference_result(fixed_weight_scale_fp16,
                                           fixed_q8_scale_q16,
                                           fixed_sign_word);
}

static int run_q1_arithmetic(enum q1_fixture_mode mode,
                             uint16_t rows,
                             uint16_t groups,
                             uint16_t weight_scale_fp16,
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
                               weight_scale_fp16, sign_word);
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
                       BONSAI_Q1_GROUP_WORDS + BONSAI_Q1_GROUP_ELEMENTS) +
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
                                 mode, row, groups, weight_scale_fp16,
                                 q8_scale_q16, sign_word)) {
      bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
      return 0;
    }
  }

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
  struct command_metrics q1_base_metrics = {0};
  struct command_metrics q1_saturation_metrics = {0};
  struct command_metrics q1_bonsai_row_metrics = {0};
  struct command_metrics q1_multi_row_metrics = {0};
  struct command_metrics attention_metrics = {0};
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

  const int16_t base_reference = q1_fixture_reference_result(
      Q1_FIXTURE_WEIGHT_SCALE_FP16, Q1_FIXTURE_Q8_SCALE_Q16,
      Q1_FIXTURE_SIGN_WORD);
  const int16_t saturation_reference = q1_fixture_reference_result(
      Q1_FIXTURE_WEIGHT_SCALE_FP16, Q1_FIXTURE_SATURATING_Q8_SCALE_Q16,
      Q1_FIXTURE_SIGN_WORD);
  const int16_t bonsai_row_reference =
      q1_fixture_bonsai_reference_result(0, Q1_FIXTURE_BONSAI_GROUPS);
  if (base_reference != 64 || saturation_reference != 32767 ||
      !run_q1_arithmetic(
          Q1_FIXTURE_FIXED, Q1_FIXTURE_ROWS, Q1_FIXTURE_GROUPS,
          Q1_FIXTURE_WEIGHT_SCALE_FP16, Q1_FIXTURE_Q8_SCALE_Q16,
          Q1_FIXTURE_SIGN_WORD, &q1_base_metrics, q1_base_output) ||
      !run_q1_arithmetic(
          Q1_FIXTURE_FIXED, Q1_FIXTURE_ROWS, Q1_FIXTURE_GROUPS,
          Q1_FIXTURE_WEIGHT_SCALE_FP16, Q1_FIXTURE_SATURATING_Q8_SCALE_Q16,
          Q1_FIXTURE_SIGN_WORD, &q1_saturation_metrics,
          q1_saturation_output) ||
      !run_q1_arithmetic(
          Q1_FIXTURE_BONSAI_ROW, Q1_FIXTURE_ROWS, Q1_FIXTURE_BONSAI_GROUPS,
          0, 0, 0, &q1_bonsai_row_metrics, q1_bonsai_row_output) ||
      !run_q1_arithmetic(
          Q1_FIXTURE_BONSAI_ROW, Q1_FIXTURE_MULTI_ROWS,
          Q1_FIXTURE_MULTI_GROUPS, 0, 0, 0,
          &q1_multi_row_metrics, q1_multi_row_output) ||
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
      "q1_base reference=%i output=%i checksum=0x%x\n",
      (int32_t)base_reference, (int32_t)q1_base_output[0],
      q1_fixture_transport_checksum(
          Q1_FIXTURE_WEIGHT_SCALE_FP16, Q1_FIXTURE_Q8_SCALE_Q16,
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
  print_metrics("attention_probe", &attention_metrics);
  neorv32_uart0_printf("unsupported_mode_error=%u\n", (uint32_t)unsupported_error);
  neorv32_uart0_printf("shell_probe=PASS\n");
  return 0;
}

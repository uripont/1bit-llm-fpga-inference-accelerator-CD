#include <stdint.h>

#include <neorv32.h>

#include "../bonsai_accel.h"

#define TERMINAL_MASK (BONSAI_STATUS_DONE | BONSAI_STATUS_ERROR)
#define POLL_LIMIT UINT32_C(100000)
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

static int run_cpu_push_command(enum bonsai_accel_service service,
                                const uint32_t input[TEST_WORDS],
                                uint32_t output[TEST_WORDS],
                                struct command_metrics *metrics) {
  unsigned int input_index = 0;
  unsigned int output_index = 0;
  uint32_t terminal_status = UINT32_MAX;

  bonsai_accel_write(
      BONSAI_REG_CONFIG,
      bonsai_accel_config(service, BONSAI_TRANSFER_CPU_PUSH));
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_START);

  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    const uint32_t status = bonsai_accel_read(BONSAI_REG_STATUS);
    if ((status & TERMINAL_MASK) != 0) {
      terminal_status = status;
      break;
    }

    const uint32_t request = bonsai_accel_read(BONSAI_REG_REQUEST);
    const uint32_t fifo_status = bonsai_accel_read(BONSAI_REG_FIFO_STATUS);

    if (((request & BONSAI_REQUEST_INPUT_VALID) != 0) &&
        ((fifo_status & BONSAI_FIFO_INPUT_READY) != 0) &&
        (input_index < TEST_WORDS)) {
      const uint32_t input_role =
          (request & BONSAI_REQUEST_INPUT_ROLE_MASK) >>
          BONSAI_REQUEST_INPUT_ROLE_SHIFT;
      if (input_role != BONSAI_ROLE_Q8_INPUT) {
        return 0;
      }
      bonsai_accel_write(BONSAI_REG_FIFO_IN, input[input_index]);
      ++input_index;
    }

    if (((request & BONSAI_REQUEST_OUTPUT_VALID) != 0) &&
        ((fifo_status & BONSAI_FIFO_OUTPUT_VALID) != 0) &&
        (output_index < TEST_WORDS)) {
      const uint32_t output_role =
          (request & BONSAI_REQUEST_OUTPUT_ROLE_MASK) >>
          BONSAI_REQUEST_OUTPUT_ROLE_SHIFT;
      if (output_role != BONSAI_ROLE_OUTPUT) {
        return 0;
      }
      output[output_index] = bonsai_accel_read(BONSAI_REG_FIFO_OUT);
      ++output_index;
    }
  }

  if ((terminal_status == UINT32_MAX) ||
      ((terminal_status & BONSAI_STATUS_DONE) == 0) ||
      ((terminal_status & BONSAI_STATUS_ERROR) != 0) ||
      (input_index != TEST_WORDS) || (output_index != TEST_WORDS)) {
    return 0;
  }

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

  const uint32_t classified_engine_cycles =
      metrics->active_cycles + metrics->input_wait_cycles +
      metrics->output_wait_cycles + metrics->control_cycles;

  uint32_t accumulator = 0;
  for (unsigned int i = 0; i < TEST_WORDS; ++i) {
    accumulator ^= input[i];
  }
  for (unsigned int i = 0; i < TEST_WORDS; ++i) {
    if (output[i] != accumulator + i) {
      return 0;
    }
  }

  const int counters_valid =
      (metrics->command_cycles >= metrics->engine_cycles) &&
      (metrics->engine_cycles == classified_engine_cycles) &&
      (metrics->active_cycles == TEST_WORDS * 2u) &&
      (metrics->input_wait_cycles != 0) &&
      (metrics->output_wait_cycles != 0) &&
      (metrics->frontend_input_wait != 0) &&
      (metrics->frontend_output_wait != 0) &&
      (metrics->input_bytes == TEST_WORDS * sizeof(uint32_t)) &&
      (metrics->output_bytes == TEST_WORDS * sizeof(uint32_t)) &&
      (metrics->work == 1);

  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
  return counters_valid && (bonsai_accel_read(BONSAI_REG_STATUS) == 0);
}

static uint32_t wait_for_terminal(void) {
  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    const uint32_t status = bonsai_accel_read(BONSAI_REG_STATUS);
    if ((status & TERMINAL_MASK) != 0) {
      return status;
    }
  }
  return UINT32_MAX;
}

static void print_metrics(const char *prefix, const struct command_metrics *metrics) {
  neorv32_uart0_printf(
      "%s_cycles command=%u engine=%u active=%u input_wait=%u output_wait=%u control=%u\n",
      prefix, metrics->command_cycles, metrics->engine_cycles,
      metrics->active_cycles, metrics->input_wait_cycles,
      metrics->output_wait_cycles, metrics->control_cycles);
  neorv32_uart0_printf(
      "%s_frontend input_wait=%u output_wait=%u input_bytes=%u output_bytes=%u\n",
      prefix, metrics->frontend_input_wait, metrics->frontend_output_wait,
      metrics->input_bytes, metrics->output_bytes);
}

int main(void) {
  static const uint32_t first_input[TEST_WORDS] = {1, 2, 3, 4};
  static const uint32_t second_input[TEST_WORDS] = {
      UINT32_C(0x10), UINT32_C(0x20), UINT32_C(0x30), UINT32_C(0x40)};
  uint32_t first_output[TEST_WORDS] = {0};
  uint32_t second_output[TEST_WORDS] = {0};
  struct command_metrics first_metrics = {0};
  struct command_metrics second_metrics = {0};

  neorv32_uart0_setup(19200, 0);
  neorv32_uart0_printf("bonsai_shell_probe\n");

  if (neorv32_cfs_available() == 0) {
    neorv32_uart0_printf("shell_probe=FAIL reason=cfs_unavailable\n");
    return 1;
  }

  const uint32_t accelerator_id = bonsai_accel_read(BONSAI_REG_ID);
  const uint32_t interface_version = bonsai_accel_read(BONSAI_REG_VERSION);
  if ((accelerator_id != BONSAI_ACCEL_ID) ||
      (interface_version != BONSAI_ACCEL_VERSION)) {
    neorv32_uart0_printf("shell_probe=FAIL reason=identity\n");
    return 1;
  }

  if (!run_cpu_push_command(BONSAI_SERVICE_Q1_MATVEC, first_input,
                            first_output, &first_metrics) ||
      !run_cpu_push_command(BONSAI_SERVICE_ATTN_KV, second_input,
                            second_output, &second_metrics)) {
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

  if ((unsupported_status == UINT32_MAX) ||
      ((unsupported_status & BONSAI_STATUS_ERROR) == 0) ||
      (unsupported_error != BONSAI_ERROR_UNSUPPORTED_MODE)) {
    neorv32_uart0_printf("shell_probe=FAIL reason=unsupported_mode\n");
    return 1;
  }
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);

  neorv32_uart0_printf("accelerator_id=0x%x\n", accelerator_id);
  neorv32_uart0_printf("interface_version=0x%x\n", interface_version);
  print_metrics("first", &first_metrics);
  print_metrics("second", &second_metrics);
  neorv32_uart0_printf("unsupported_mode_error=%u\n", (uint32_t) unsupported_error);
  neorv32_uart0_printf("shell_probe=PASS\n");
  return 0;
}

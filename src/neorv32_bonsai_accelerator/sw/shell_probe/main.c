#include <stdint.h>

#include <neorv32.h>

#include "../bonsai_accel.h"

#define TERMINAL_MASK (BONSAI_STATUS_DONE | BONSAI_STATUS_ERROR)
#define POLL_LIMIT UINT32_C(100000)

static uint32_t wait_for_terminal(void) {
  for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
    const uint32_t status = bonsai_accel_read(BONSAI_REG_STATUS);
    if ((status & TERMINAL_MASK) != 0) {
      return status;
    }
  }
  return UINT32_MAX;
}

static int run_successful_command(enum bonsai_accel_service service,
                                  uint32_t *command_cycles,
                                  uint32_t *engine_cycles) {
  bonsai_accel_write(
      BONSAI_REG_CONFIG,
      bonsai_accel_config(service, BONSAI_TRANSFER_CPU_PUSH));
  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_START);

  const uint32_t status = wait_for_terminal();
  if ((status == UINT32_MAX) || ((status & BONSAI_STATUS_DONE) == 0) ||
      ((status & BONSAI_STATUS_ERROR) != 0)) {
    return 0;
  }

  *command_cycles = bonsai_accel_read(BONSAI_REG_COUNTER_COMMAND);
  *engine_cycles = bonsai_accel_read(BONSAI_REG_COUNTER_ENGINE);
  const uint32_t active_cycles = bonsai_accel_read(BONSAI_REG_COUNTER_ACTIVE);
  const uint32_t input_wait = bonsai_accel_read(BONSAI_REG_COUNTER_INPUT_WAIT);
  const uint32_t output_wait = bonsai_accel_read(BONSAI_REG_COUNTER_OUTPUT_WAIT);
  const uint32_t control_cycles = bonsai_accel_read(BONSAI_REG_COUNTER_CONTROL);
  const uint32_t work = bonsai_accel_read(BONSAI_REG_COUNTER_WORK);

  const int counters_valid =
      (*command_cycles >= *engine_cycles) && (*engine_cycles != 0) &&
      (*engine_cycles == active_cycles + input_wait + output_wait + control_cycles) &&
      (work == 1);

  bonsai_accel_write(BONSAI_REG_COMMAND, BONSAI_COMMAND_ACK);
  return counters_valid && (bonsai_accel_read(BONSAI_REG_STATUS) == 0);
}

int main(void) {
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

  uint32_t first_command_cycles = 0;
  uint32_t first_engine_cycles = 0;
  uint32_t second_command_cycles = 0;
  uint32_t second_engine_cycles = 0;

  if (!run_successful_command(BONSAI_SERVICE_Q1_MATVEC,
                              &first_command_cycles,
                              &first_engine_cycles) ||
      !run_successful_command(BONSAI_SERVICE_ATTN_KV,
                              &second_command_cycles,
                              &second_engine_cycles)) {
    neorv32_uart0_printf("shell_probe=FAIL reason=command_or_counter\n");
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
  neorv32_uart0_printf("first_command_cycles=%u\n", first_command_cycles);
  neorv32_uart0_printf("first_engine_cycles=%u\n", first_engine_cycles);
  neorv32_uart0_printf("second_command_cycles=%u\n", second_command_cycles);
  neorv32_uart0_printf("second_engine_cycles=%u\n", second_engine_cycles);
  neorv32_uart0_printf("unsupported_mode_error=%u\n", (uint32_t) unsupported_error);
  neorv32_uart0_printf("shell_probe=PASS\n");
  return 0;
}


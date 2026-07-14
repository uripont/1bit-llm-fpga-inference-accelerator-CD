#include <stdint.h>

#include <neorv32.h>

#include "../bonsai_accel.h"

int main(void) {
  const uint32_t expected_config =
      bonsai_accel_config(BONSAI_SERVICE_Q1_MATVEC, BONSAI_TRANSFER_CPU_PUSH);

  neorv32_uart0_setup(19200, 0);
  neorv32_uart0_printf("bonsai_shell_probe\n");

  if (neorv32_cfs_available() == 0) {
    neorv32_uart0_printf("shell_probe=FAIL reason=cfs_unavailable\n");
    return 1;
  }

  const uint32_t accelerator_id = bonsai_accel_read(BONSAI_REG_ID);
  const uint32_t interface_version = bonsai_accel_read(BONSAI_REG_VERSION);

  bonsai_accel_write(BONSAI_REG_CONFIG, expected_config);
  const uint32_t config_readback = bonsai_accel_read(BONSAI_REG_CONFIG);

  neorv32_uart0_printf("accelerator_id=0x%x\n", accelerator_id);
  neorv32_uart0_printf("interface_version=0x%x\n", interface_version);
  neorv32_uart0_printf("config_readback=0x%x\n", config_readback);

  if ((accelerator_id != BONSAI_ACCEL_ID) ||
      (interface_version != BONSAI_ACCEL_VERSION) ||
      (config_readback != expected_config)) {
    neorv32_uart0_printf("shell_probe=FAIL reason=register_contract\n");
    return 1;
  }

  neorv32_uart0_printf("shell_probe=PASS\n");
  return 0;
}


-- Tang Nano 9K integration top for the NEORV32 Bonsai accelerator.

library ieee;
use ieee.std_logic_1164.all;

library neorv32;
use neorv32.neorv32_package.all;

entity bonsai_tang_nano_9k_top is
  port (
    clk_i       : in  std_ulogic;
    rstn_i      : in  std_ulogic;
    gpio_o      : out std_ulogic_vector(5 downto 0);
    uart0_txd_o : out std_ulogic;
    uart0_rxd_i : in  std_ulogic
  );
end entity;

architecture rtl of bonsai_tang_nano_9k_top is
  signal gpio : std_ulogic_vector(31 downto 0);
begin
  soc_inst : neorv32_top
    generic map (
      CLOCK_FREQUENCY  => 27000000,
      BOOT_MODE_SELECT => 0,
      RISCV_ISA_C      => true,
      RISCV_ISA_M      => true,
      RISCV_ISA_Zicntr => true,
      IMEM_EN          => true,
      IMEM_SIZE        => 16 * 1024,
      DMEM_EN          => true,
      DMEM_SIZE        => 8 * 1024,
      IO_GPIO_NUM      => 6,
      IO_CLINT_EN      => false,
      IO_UART0_EN      => true,
      IO_CFS_EN        => true
    )
    port map (
      clk_i       => clk_i,
      rstn_i      => rstn_i,
      gpio_o      => gpio,
      uart0_txd_o => uart0_txd_o,
      uart0_rxd_i => uart0_rxd_i
    );

  gpio_o <= gpio(5 downto 0);
end architecture;

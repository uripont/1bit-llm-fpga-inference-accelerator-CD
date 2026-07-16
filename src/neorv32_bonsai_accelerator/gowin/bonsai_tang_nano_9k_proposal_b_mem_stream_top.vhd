-- Tang Nano 9K Proposal B top with descriptor-driven PSRAM streaming.

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
    uart0_rxd_i : in  std_ulogic;
    O_psram_ck      : out std_logic_vector(1 downto 0);
    O_psram_ck_n    : out std_logic_vector(1 downto 0);
    IO_psram_dq     : inout std_logic_vector(15 downto 0);
    IO_psram_rwds   : inout std_logic_vector(1 downto 0);
    O_psram_cs_n    : out std_logic_vector(1 downto 0);
    O_psram_reset_n : out std_logic_vector(1 downto 0)
  );
end entity;

architecture rtl of bonsai_tang_nano_9k_top is
  component Gowin_rPLL is
    port (
      clkout : out std_logic;
      lock   : out std_logic;
      clkin  : in  std_logic
    );
  end component;

  signal gpio : std_ulogic_vector(31 downto 0);
  signal cfs_to_memory, memory_to_cfs : std_ulogic_vector(255 downto 0);
  signal memory_clk, pll_lock : std_logic;
  signal memory_cmd_ready, memory_write_done, memory_read_valid : std_ulogic;
  signal memory_init_done, memory_error : std_ulogic;
  signal memory_read_data : std_ulogic_vector(63 downto 0);
begin
  soc_inst : neorv32_top
    generic map (
      CLOCK_FREQUENCY  => 27000000,
      BOOT_MODE_SELECT => 2,
      RISCV_ISA_C      => false,
      RISCV_ISA_M      => false,
      RISCV_ISA_Zicntr => false,
      IMEM_EN          => true,
      IMEM_SIZE        => 16 * 1024,
      DMEM_EN          => true,
      DMEM_SIZE        => 8 * 1024,
      IO_GPIO_NUM      => 1,
      IO_CLINT_EN      => false,
      IO_UART0_EN      => false,
      IO_CFS_EN        => true
    )
    port map (
      clk_i       => clk_i,
      rstn_i      => rstn_i,
      gpio_o      => gpio,
      uart0_txd_o => open,
      uart0_rxd_i => uart0_rxd_i,
      cfs_in_i    => memory_to_cfs,
      cfs_out_o   => cfs_to_memory
    );

  pll_inst : Gowin_rPLL
    port map (
      clkout => memory_clk,
      lock => pll_lock,
      clkin => std_logic(clk_i)
    );

  memory_to_cfs <= (255 downto 69 => '0') & memory_error & memory_read_valid &
                   memory_read_data & memory_write_done & memory_cmd_ready &
                   memory_init_done;

  memory_boundary_inst : entity work.psram_stream_boundary
    port map (
      clk_i => clk_i,
      memory_clk_i => std_ulogic(memory_clk),
      pll_lock_i => std_ulogic(pll_lock),
      rstn_i => rstn_i,
      cmd_valid_i => cfs_to_memory(0),
      cmd_write_i => cfs_to_memory(1),
      cmd_address_i => cfs_to_memory(15 downto 2),
      cmd_ready_o => memory_cmd_ready,
      write_data_i => cfs_to_memory(79 downto 16),
      write_valid_i => cfs_to_memory(80),
      write_done_o => memory_write_done,
      read_data_o => memory_read_data,
      read_valid_o => memory_read_valid,
      init_done_o => memory_init_done,
      error_o => memory_error,
      O_psram_ck => O_psram_ck,
      O_psram_ck_n => O_psram_ck_n,
      IO_psram_dq => IO_psram_dq,
      IO_psram_rwds => IO_psram_rwds,
      O_psram_cs_n => O_psram_cs_n,
      O_psram_reset_n => O_psram_reset_n
    );

  gpio_o <= (5 downto 1 => '0') & gpio(0);
  uart0_txd_o <= '1';
end architecture;

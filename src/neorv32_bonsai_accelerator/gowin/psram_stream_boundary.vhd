-- Adapter between the Bonsai streamer and Gowin's PSRAM HS user interface.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity psram_stream_boundary is
  port (
    clk_i        : in  std_ulogic;
    memory_clk_i : in  std_ulogic;
    pll_lock_i   : in  std_ulogic;
    rstn_i       : in  std_ulogic;

    cmd_valid_i  : in  std_ulogic;
    cmd_write_i  : in  std_ulogic;
    cmd_address_i : in std_ulogic_vector(13 downto 0);
    cmd_ready_o  : out std_ulogic;
    write_data_i : in  std_ulogic_vector(63 downto 0);
    write_valid_i : in std_ulogic;
    write_done_o : out std_ulogic;
    read_data_o  : out std_ulogic_vector(63 downto 0);
    read_valid_o : out std_ulogic;
    init_done_o  : out std_ulogic;
    error_o      : out std_ulogic;

    O_psram_ck      : out std_logic_vector(1 downto 0);
    O_psram_ck_n    : out std_logic_vector(1 downto 0);
    IO_psram_dq     : inout std_logic_vector(15 downto 0);
    IO_psram_rwds   : inout std_logic_vector(1 downto 0);
    O_psram_cs_n    : out std_logic_vector(1 downto 0);
    O_psram_reset_n : out std_logic_vector(1 downto 0)
  );
end psram_stream_boundary;

architecture rtl of psram_stream_boundary is
  constant COMMAND_INTERVAL_CYCLES_C : natural := 18;
  component PSRAM_Memory_Interface_HS_Top is
    port (
      clk, memory_clk, pll_lock, rst_n : in std_logic;
      O_psram_ck, O_psram_ck_n : out std_logic_vector(1 downto 0);
      IO_psram_dq : inout std_logic_vector(15 downto 0);
      IO_psram_rwds : inout std_logic_vector(1 downto 0);
      O_psram_cs_n, O_psram_reset_n : out std_logic_vector(1 downto 0);
      wr_data : in std_logic_vector(63 downto 0);
      rd_data : out std_logic_vector(63 downto 0);
      rd_data_valid : out std_logic;
      addr : in std_logic_vector(20 downto 0);
      cmd, cmd_en : in std_logic;
      init_calib, clk_out : out std_logic;
      data_mask : in std_logic_vector(7 downto 0)
    );
  end component;

  type state_t is (IDLE, WRITE_BURST, READ_BURST);
  signal state : state_t;
  signal beat_count : natural range 0 to 3;
  signal command_cooldown : natural range 0 to COMMAND_INTERVAL_CYCLES_C - 1;
  signal controller_cmd_en, controller_cmd : std_logic;
  signal controller_init, controller_read_valid : std_logic;
  signal controller_addr : std_logic_vector(20 downto 0);
  signal controller_write_data, controller_read_data : std_logic_vector(63 downto 0);
begin
  cmd_ready_o <= '1' when state = IDLE and controller_init = '1' and
                          command_cooldown = 0 else '0';
  init_done_o <= std_ulogic(controller_init);
  read_data_o <= std_ulogic_vector(controller_read_data);
  read_valid_o <= std_ulogic(controller_read_valid) when state = READ_BURST else '0';
  error_o <= '0';

  -- In DQ16 single-channel mode, each controller address stores one 32-bit word.
  controller_addr <= (20 downto 14 => '0') & std_logic_vector(cmd_address_i);
  controller_cmd <= std_logic(cmd_write_i);
  controller_write_data <= std_logic_vector(write_data_i);

  protocol : process(rstn_i, clk_i)
  begin
    if rstn_i = '0' then
      state <= IDLE;
      beat_count <= 0;
      command_cooldown <= 0;
      controller_cmd_en <= '0';
      write_done_o <= '0';
    elsif rising_edge(clk_i) then
      controller_cmd_en <= '0';
      write_done_o <= '0';
      if command_cooldown > 0 then
        command_cooldown <= command_cooldown - 1;
      end if;
      case state is
        when IDLE =>
          beat_count <= 0;
          if cmd_valid_i = '1' and controller_init = '1' and command_cooldown = 0 then
            controller_cmd_en <= '1';
            command_cooldown <= COMMAND_INTERVAL_CYCLES_C - 1;
            if cmd_write_i = '1' then
              beat_count <= 1;
              state <= WRITE_BURST;
            else
              state <= READ_BURST;
            end if;
          end if;

        when WRITE_BURST =>
          if write_valid_i = '1' then
            if beat_count = 3 then
              write_done_o <= '1';
              state <= IDLE;
            else
              beat_count <= beat_count + 1;
            end if;
          end if;

        when READ_BURST =>
          if controller_read_valid = '1' then
            if beat_count = 3 then
              state <= IDLE;
            else
              beat_count <= beat_count + 1;
            end if;
          end if;
      end case;
    end if;
  end process protocol;

  controller_inst : PSRAM_Memory_Interface_HS_Top
    port map (
      clk => std_logic(clk_i),
      memory_clk => std_logic(memory_clk_i),
      pll_lock => std_logic(pll_lock_i),
      rst_n => std_logic(rstn_i),
      O_psram_ck => O_psram_ck,
      O_psram_ck_n => O_psram_ck_n,
      IO_psram_dq => IO_psram_dq,
      IO_psram_rwds => IO_psram_rwds,
      O_psram_cs_n => O_psram_cs_n,
      O_psram_reset_n => O_psram_reset_n,
      wr_data => controller_write_data,
      rd_data => controller_read_data,
      rd_data_valid => controller_read_valid,
      addr => controller_addr,
      cmd => controller_cmd,
      cmd_en => controller_cmd_en,
      init_calib => controller_init,
      clk_out => open,
      data_mask => (others => '0')
    );
end rtl;

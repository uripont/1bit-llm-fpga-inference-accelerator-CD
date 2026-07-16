-- Synthesis placeholder for the PSRAM-controller boundary.
-- The controller and physical PSRAM interface are added in the next checkpoint.

library ieee;
use ieee.std_logic_1164.all;

entity stream_memory is
  generic (
    INITIALIZATION_CYCLES : positive := 150;
    READ_LATENCY_CYCLES : positive := 6;
    COMMAND_INTERVAL_CYCLES : positive := 18
  );
  port (
    clk_i, rstn_i : in std_ulogic;

    cpu_write_i : in std_ulogic;
    cpu_address_i : in std_ulogic_vector(13 downto 0);
    cpu_write_data_i : in std_ulogic_vector(31 downto 0);
    cpu_read_data_o : out std_ulogic_vector(31 downto 0);

    init_done_o : out std_ulogic;
    cmd_valid_i, cmd_write_i : in std_ulogic;
    cmd_address_i : in std_ulogic_vector(13 downto 0);
    cmd_ready_o : out std_ulogic;
    write_data_i : in std_ulogic_vector(63 downto 0);
    write_valid_i : in std_ulogic;
    write_done_o : out std_ulogic;
    read_data_o : out std_ulogic_vector(63 downto 0);
    read_valid_o, error_o : out std_ulogic
  );
end stream_memory;

architecture psram_pending of stream_memory is
begin
  cpu_read_data_o <= (others => '0');
  init_done_o <= '0';
  cmd_ready_o <= '0';
  write_done_o <= '0';
  read_data_o <= (others => '0');
  read_valid_o <= '0';
  error_o <= '0';
end architecture;

-- Simulation backing store for the abstract descriptor memory interface.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity stream_memory is
  port (
    clk_i : in std_ulogic;

    cpu_write_i     : in  std_ulogic;
    cpu_address_i   : in  std_ulogic_vector(13 downto 0);
    cpu_write_data_i : in std_ulogic_vector(31 downto 0);
    cpu_read_data_o : out std_ulogic_vector(31 downto 0);

    stream_write_i      : in  std_ulogic;
    stream_address_i    : in  std_ulogic_vector(13 downto 0);
    stream_write_data_i : in  std_ulogic_vector(31 downto 0);
    stream_read_data_o  : out std_ulogic_vector(31 downto 0);
    stream_ready_o      : out std_ulogic;
    stream_error_o      : out std_ulogic
  );
end stream_memory;

architecture simulation_model of stream_memory is
  type memory_t is array (0 to MEM_WINDOW_WORDS_C - 1) of
    std_ulogic_vector(31 downto 0);
  signal memory : memory_t := (others => (others => '0'));
begin
  cpu_read_data_o <= memory(to_integer(unsigned(cpu_address_i)))
    when unsigned(cpu_address_i) < MEM_WINDOW_WORDS_C else (others => '0');
  stream_read_data_o <= memory(to_integer(unsigned(stream_address_i)))
    when unsigned(stream_address_i) < MEM_WINDOW_WORDS_C else (others => '0');
  stream_ready_o <= '1';
  stream_error_o <= '1' when unsigned(stream_address_i) >= MEM_WINDOW_WORDS_C else '0';

  write_memory : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if cpu_write_i = '1' then
        if unsigned(cpu_address_i) < MEM_WINDOW_WORDS_C then
          memory(to_integer(unsigned(cpu_address_i))) <= cpu_write_data_i;
        end if;
      elsif stream_write_i = '1' then
        if unsigned(stream_address_i) < MEM_WINDOW_WORDS_C then
          memory(to_integer(unsigned(stream_address_i))) <= stream_write_data_i;
        end if;
      end if;
    end if;
  end process write_memory;
end simulation_model;

-- Per-command hardware counters. Values freeze in terminal command states.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity counter_block is
  port (
    clk_i  : in std_ulogic;
    rstn_i : in std_ulogic;

    command_start_i   : in std_ulogic;
    command_active_i  : in std_ulogic;
    engine_interval_i : in std_ulogic;
    engine_active_i   : in std_ulogic;
    engine_input_wait_i  : in std_ulogic;
    engine_output_wait_i : in std_ulogic;
    engine_control_i     : in std_ulogic;
    frontend_input_wait_i  : in std_ulogic;
    frontend_output_wait_i : in std_ulogic;
    input_bytes_i  : in std_ulogic_vector(31 downto 0);
    output_bytes_i : in std_ulogic_vector(31 downto 0);
    work_i         : in std_ulogic_vector(31 downto 0);

    command_cycles_o      : out std_ulogic_vector(31 downto 0);
    engine_cycles_o       : out std_ulogic_vector(31 downto 0);
    active_cycles_o       : out std_ulogic_vector(31 downto 0);
    input_wait_cycles_o   : out std_ulogic_vector(31 downto 0);
    output_wait_cycles_o  : out std_ulogic_vector(31 downto 0);
    control_cycles_o      : out std_ulogic_vector(31 downto 0);
    frontend_input_wait_o : out std_ulogic_vector(31 downto 0);
    frontend_output_wait_o : out std_ulogic_vector(31 downto 0);
    input_bytes_o         : out std_ulogic_vector(31 downto 0);
    output_bytes_o        : out std_ulogic_vector(31 downto 0);
    work_o                : out std_ulogic_vector(31 downto 0)
  );
end counter_block;

architecture rtl of counter_block is

  subtype counter_t is unsigned(31 downto 0);
  constant COUNTER_MAX_C : counter_t := (others => '1');

  signal command_cycles       : counter_t;
  signal engine_cycles        : counter_t;
  signal active_cycles        : counter_t;
  signal input_wait_cycles    : counter_t;
  signal output_wait_cycles   : counter_t;
  signal control_cycles       : counter_t;
  signal frontend_input_wait  : counter_t;
  signal frontend_output_wait : counter_t;
  signal input_bytes          : counter_t;
  signal output_bytes         : counter_t;
  signal work                 : counter_t;

  function saturating_increment(value : counter_t) return counter_t is
  begin
    if value = COUNTER_MAX_C then
      return value;
    end if;
    return value + 1;
  end function;

  function saturating_add(value : counter_t; delta : counter_t) return counter_t is
  begin
    if delta > (COUNTER_MAX_C - value) then
      return COUNTER_MAX_C;
    end if;
    return value + delta;
  end function;

begin

  command_cycles_o       <= std_ulogic_vector(command_cycles);
  engine_cycles_o        <= std_ulogic_vector(engine_cycles);
  active_cycles_o        <= std_ulogic_vector(active_cycles);
  input_wait_cycles_o    <= std_ulogic_vector(input_wait_cycles);
  output_wait_cycles_o   <= std_ulogic_vector(output_wait_cycles);
  control_cycles_o       <= std_ulogic_vector(control_cycles);
  frontend_input_wait_o  <= std_ulogic_vector(frontend_input_wait);
  frontend_output_wait_o <= std_ulogic_vector(frontend_output_wait);
  input_bytes_o          <= std_ulogic_vector(input_bytes);
  output_bytes_o         <= std_ulogic_vector(output_bytes);
  work_o                 <= std_ulogic_vector(work);

  counters : process(rstn_i, clk_i)
  begin
    if rstn_i = '0' then
      command_cycles       <= (others => '0');
      engine_cycles        <= (others => '0');
      active_cycles        <= (others => '0');
      input_wait_cycles    <= (others => '0');
      output_wait_cycles   <= (others => '0');
      control_cycles       <= (others => '0');
      frontend_input_wait  <= (others => '0');
      frontend_output_wait <= (others => '0');
      input_bytes          <= (others => '0');
      output_bytes         <= (others => '0');
      work                 <= (others => '0');
    elsif rising_edge(clk_i) then
      if command_start_i = '1' then
        command_cycles       <= (others => '0');
        engine_cycles        <= (others => '0');
        active_cycles        <= (others => '0');
        input_wait_cycles    <= (others => '0');
        output_wait_cycles   <= (others => '0');
        control_cycles       <= (others => '0');
        frontend_input_wait  <= (others => '0');
        frontend_output_wait <= (others => '0');
        input_bytes          <= (others => '0');
        output_bytes         <= (others => '0');
        work                 <= (others => '0');
      else
        if command_active_i = '1' then
          command_cycles <= saturating_increment(command_cycles);
        end if;
        if engine_interval_i = '1' then
          engine_cycles <= saturating_increment(engine_cycles);
        end if;
        if engine_active_i = '1' then
          active_cycles <= saturating_increment(active_cycles);
        end if;
        if engine_input_wait_i = '1' then
          input_wait_cycles <= saturating_increment(input_wait_cycles);
        end if;
        if engine_output_wait_i = '1' then
          output_wait_cycles <= saturating_increment(output_wait_cycles);
        end if;
        if engine_control_i = '1' then
          control_cycles <= saturating_increment(control_cycles);
        end if;
        if frontend_input_wait_i = '1' then
          frontend_input_wait <= saturating_increment(frontend_input_wait);
        end if;
        if frontend_output_wait_i = '1' then
          frontend_output_wait <= saturating_increment(frontend_output_wait);
        end if;
        input_bytes  <= saturating_add(input_bytes, unsigned(input_bytes_i));
        output_bytes <= saturating_add(output_bytes, unsigned(output_bytes_i));
        work         <= saturating_add(work, unsigned(work_i));
      end if;
    end if;
  end process counters;

end rtl;


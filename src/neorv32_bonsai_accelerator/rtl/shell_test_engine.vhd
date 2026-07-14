-- Temporary engine used to validate the shared command and counter contract.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity shell_test_engine is
  generic (
    ACTIVE_CYCLES : positive := 16
  );
  port (
    clk_i  : in std_ulogic;
    rstn_i : in std_ulogic;
    launch_i : in std_ulogic;
    busy_o   : out std_ulogic;
    done_o   : out std_ulogic;
    error_o  : out std_ulogic;
    active_o : out std_ulogic;
    work_o   : out std_ulogic_vector(31 downto 0)
  );
end shell_test_engine;

architecture rtl of shell_test_engine is

  type state_t is (IDLE, ACTIVE);
  signal state : state_t;
  signal cycles_remaining : natural range 0 to ACTIVE_CYCLES;

begin

  busy_o   <= '1' when state = ACTIVE else '0';
  active_o <= '1' when state = ACTIVE else '0';
  done_o   <= '1' when (state = ACTIVE) and (cycles_remaining = 1) else '0';
  error_o  <= '0';
  work_o   <= x"00000001" when done_o = '1' else x"00000000";

  engine : process(rstn_i, clk_i)
  begin
    if rstn_i = '0' then
      state            <= IDLE;
      cycles_remaining <= 0;
    elsif rising_edge(clk_i) then
      case state is
        when IDLE =>
          if launch_i = '1' then
            cycles_remaining <= ACTIVE_CYCLES;
            state            <= ACTIVE;
          end if;
        when ACTIVE =>
          if cycles_remaining = 1 then
            cycles_remaining <= 0;
            state            <= IDLE;
          else
            cycles_remaining <= cycles_remaining - 1;
          end if;
      end case;
    end if;
  end process engine;

end rtl;


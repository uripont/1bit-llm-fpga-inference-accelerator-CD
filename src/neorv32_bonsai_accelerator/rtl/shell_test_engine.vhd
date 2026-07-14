-- Temporary streaming engine used to validate the shared CPU_PUSH contract.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity shell_test_engine is
  port (
    clk_i  : in std_ulogic;
    rstn_i : in std_ulogic;
    launch_i : in std_ulogic;

    transaction_valid_o     : out std_ulogic;
    transaction_ready_i     : in std_ulogic;
    transaction_direction_o : out std_ulogic;
    transaction_role_o      : out tile_role_t;
    transaction_tile_o      : out std_ulogic_vector(15 downto 0);
    transaction_length_o    : out std_ulogic_vector(15 downto 0);

    input_valid_i : in std_ulogic;
    input_ready_o : out std_ulogic;
    input_data_i  : in std_ulogic_vector(31 downto 0);
    output_valid_o : out std_ulogic;
    output_ready_i : in std_ulogic;
    output_data_o  : out std_ulogic_vector(31 downto 0);

    busy_o        : out std_ulogic;
    done_o        : out std_ulogic;
    error_o       : out std_ulogic;
    active_o      : out std_ulogic;
    input_wait_o  : out std_ulogic;
    output_wait_o : out std_ulogic;
    work_o        : out std_ulogic_vector(31 downto 0)
  );
end shell_test_engine;

architecture rtl of shell_test_engine is

  type state_t is (IDLE, REQUEST_INPUT, CONSUME_INPUT, REQUEST_OUTPUT, PRODUCE_OUTPUT);
  signal state : state_t;
  signal input_index, output_index : natural range 0 to 3;
  signal accumulator : unsigned(31 downto 0);
  signal input_accept, output_accept : std_ulogic;

begin

  transaction_valid_o <= '1' when
    (state = REQUEST_INPUT) or (state = REQUEST_OUTPUT) else '0';
  transaction_direction_o <= TILE_DIRECTION_OUTPUT_C when state = REQUEST_OUTPUT
    else TILE_DIRECTION_INPUT_C;
  transaction_role_o <= ROLE_OUTPUT_C when state = REQUEST_OUTPUT else ROLE_Q8_INPUT_C;
  transaction_tile_o <= (others => '0');
  transaction_length_o <= x"0004";

  input_ready_o <= '1' when state = CONSUME_INPUT else '0';
  input_accept <= input_valid_i and input_ready_o;

  output_valid_o <= '1' when state = PRODUCE_OUTPUT else '0';
  output_data_o <= std_ulogic_vector(accumulator + to_unsigned(output_index, 32));
  output_accept <= output_valid_o and output_ready_i;

  busy_o  <= '0' when state = IDLE else '1';
  done_o  <= '1' when (state = PRODUCE_OUTPUT) and (output_index = 3) and
                       (output_accept = '1') else '0';
  error_o <= '0';

  active_o      <= input_accept or output_accept;
  input_wait_o  <= '1' when (state = CONSUME_INPUT) and (input_valid_i = '0') else '0';
  output_wait_o <= '1' when (state = PRODUCE_OUTPUT) and (output_ready_i = '0') else '0';
  work_o        <= x"00000001" when done_o = '1' else x"00000000";

  engine : process(rstn_i, clk_i)
  begin
    if rstn_i = '0' then
      state        <= IDLE;
      input_index  <= 0;
      output_index <= 0;
      accumulator  <= (others => '0');
    elsif rising_edge(clk_i) then
      case state is
        when IDLE =>
          if launch_i = '1' then
            input_index  <= 0;
            output_index <= 0;
            accumulator  <= (others => '0');
            state        <= REQUEST_INPUT;
          end if;

        when REQUEST_INPUT =>
          if transaction_ready_i = '1' then
            state <= CONSUME_INPUT;
          end if;

        when CONSUME_INPUT =>
          if input_accept = '1' then
            accumulator <= accumulator xor unsigned(input_data_i);
            if input_index = 3 then
              input_index <= 0;
              state       <= REQUEST_OUTPUT;
            else
              input_index <= input_index + 1;
            end if;
          end if;

        when REQUEST_OUTPUT =>
          if transaction_ready_i = '1' then
            output_index <= 0;
            state        <= PRODUCE_OUTPUT;
          end if;

        when PRODUCE_OUTPUT =>
          if output_accept = '1' then
            if output_index = 3 then
              output_index <= 0;
              state        <= IDLE;
            else
              output_index <= output_index + 1;
            end if;
          end if;
      end case;
    end if;
  end process engine;

end rtl;


-- One-group Q1_0 x Q8_0 matvec engine for the Proposal A board work unit.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity q1_matvec_engine is
  port (
    clk_i  : in std_ulogic;
    rstn_i : in std_ulogic;
    launch_i : in std_ulogic;
    rows_i   : in std_ulogic_vector(15 downto 0);
    groups_i : in std_ulogic_vector(15 downto 0);

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
end q1_matvec_engine;

architecture rtl of q1_matvec_engine is
  type state_t is (
    IDLE, REQUEST_Q8, CONSUME_Q8, REQUEST_Q1, CONSUME_Q1,
    COMPUTE, REQUEST_OUTPUT, PRODUCE_OUTPUT, ERROR_STATE
  );
  type q8_value_array_t is array (0 to Q1_GROUP_ELEMENTS_C - 1) of signed(7 downto 0);
  type q8_scale_array_t is array (0 to Q8_BLOCKS_PER_Q1_C - 1) of signed(31 downto 0);

  signal state : state_t;
  signal q8_index, compute_block : natural range 0 to Q8_BLOCKS_PER_Q1_C - 1;
  signal word_index : natural range 0 to Q8_BLOCK_WORDS_C - 1;
  signal lane_index : natural range 0 to Q8_BLOCK_ELEMENTS_C - 1;
  signal q8_values : q8_value_array_t;
  signal q8_scales : q8_scale_array_t;
  signal q1_signs : std_ulogic_vector(Q1_GROUP_ELEMENTS_C - 1 downto 0);
  signal q1_scale_fp16 : std_ulogic_vector(15 downto 0);
  signal integer_partial : signed(31 downto 0);
  signal row_accumulator : signed(63 downto 0);
  signal output_result : std_ulogic_vector(31 downto 0);
  signal input_accept, output_accept : std_ulogic;

  function fp16_to_q8(h : std_ulogic_vector(15 downto 0)) return signed is
    variable sign_v, exponent_v, mantissa_v, value_v : integer;
  begin
    sign_v := 1;
    if h(15) = '1' then
      sign_v := -1;
    end if;
    exponent_v := to_integer(unsigned(h(14 downto 10)));
    mantissa_v := to_integer(unsigned(h(9 downto 0)));
    if exponent_v = 0 then
      if mantissa_v = 0 then
        value_v := 0;
      else
        value_v := (mantissa_v * 256) / (2 ** 24);
      end if;
    elsif exponent_v = 31 then
      value_v := 0;
    else
      mantissa_v := mantissa_v + 1024;
      exponent_v := exponent_v - 15;
      value_v := mantissa_v * 256;
      if exponent_v >= 10 then
        value_v := value_v * (2 ** (exponent_v - 10));
      else
        value_v := value_v / (2 ** (10 - exponent_v));
      end if;
    end if;
    return to_signed(sign_v * value_v, 32);
  end function;

  function saturate_i16(value : signed(63 downto 0)) return std_ulogic_vector is
  begin
    if value > to_signed(32767, 64) then
      return x"00007FFF";
    elsif value < to_signed(-32768, 64) then
      return x"FFFF8000";
    else
      return std_ulogic_vector(resize(value, 32));
    end if;
  end function;
begin
  transaction_valid_o <= '1' when
    (state = REQUEST_Q8) or (state = REQUEST_Q1) or
    (state = REQUEST_OUTPUT) else '0';
  transaction_direction_o <= TILE_DIRECTION_OUTPUT_C when state = REQUEST_OUTPUT
    else TILE_DIRECTION_INPUT_C;
  transaction_role_o <= ROLE_Q8_INPUT_C when state = REQUEST_Q8 else
                        ROLE_Q1_WEIGHTS_C when state = REQUEST_Q1 else
                        ROLE_OUTPUT_C;
  transaction_tile_o <= std_ulogic_vector(to_unsigned(q8_index, 16))
    when state = REQUEST_Q8 else (others => '0');
  transaction_length_o <= std_ulogic_vector(to_unsigned(Q8_BLOCK_WORDS_C, 16))
    when state = REQUEST_Q8 else
    std_ulogic_vector(to_unsigned(Q1_GROUP_WORDS_C, 16)) when state = REQUEST_Q1 else
    std_ulogic_vector(to_unsigned(MATVEC_OUTPUT_WORDS_C, 16));

  input_ready_o <= '1' when (state = CONSUME_Q8) or (state = CONSUME_Q1) else '0';
  input_accept <= input_valid_i and input_ready_o;
  output_valid_o <= '1' when state = PRODUCE_OUTPUT else '0';
  output_data_o <= output_result;
  output_accept <= output_valid_o and output_ready_i;

  busy_o  <= '0' when (state = IDLE) or (state = ERROR_STATE) else '1';
  done_o  <= '1' when (state = PRODUCE_OUTPUT) and (output_accept = '1') else '0';
  error_o <= '1' when state = ERROR_STATE else '0';
  active_o <= '1' when state = COMPUTE else input_accept or output_accept;
  input_wait_o <= '1' when
    ((state = CONSUME_Q8) or (state = CONSUME_Q1)) and input_valid_i = '0' else '0';
  output_wait_o <= '1' when state = PRODUCE_OUTPUT and output_ready_i = '0' else '0';
  work_o <= x"00000001" when done_o = '1' else (others => '0');

  control : process(rstn_i, clk_i)
    variable value_base_v, sign_base_v : natural;
    variable lane_v, next_partial_v : signed(31 downto 0);
    variable scale_product_v : signed(63 downto 0);
    variable scaled_wide_v : signed(95 downto 0);
    variable scaled_low_v, contribution_v, next_accumulator_v : signed(63 downto 0);
  begin
    if rstn_i = '0' then
      state             <= IDLE;
      q8_index          <= 0;
      compute_block     <= 0;
      word_index        <= 0;
      lane_index        <= 0;
      q1_signs          <= (others => '0');
      q1_scale_fp16     <= (others => '0');
      integer_partial   <= (others => '0');
      row_accumulator   <= (others => '0');
      output_result     <= (others => '0');
    elsif rising_edge(clk_i) then
      case state is
        when IDLE | ERROR_STATE =>
          if launch_i = '1' then
            q8_index        <= 0;
            compute_block   <= 0;
            word_index      <= 0;
            lane_index      <= 0;
            q1_signs        <= (others => '0');
            integer_partial <= (others => '0');
            row_accumulator <= (others => '0');
            output_result   <= (others => '0');
            if (unsigned(rows_i) = 1) and (unsigned(groups_i) = 1) then
              state <= REQUEST_Q8;
            else
              state <= ERROR_STATE;
            end if;
          end if;

        when REQUEST_Q8 =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= CONSUME_Q8;
          end if;

        when CONSUME_Q8 =>
          if input_accept = '1' then
            if word_index = 0 then
              q8_scales(q8_index) <= signed(input_data_i);
            else
              value_base_v := q8_index * Q8_BLOCK_ELEMENTS_C + (word_index - 1) * 4;
              for byte in 0 to 3 loop
                q8_values(value_base_v + byte) <=
                  signed(input_data_i(byte * 8 + 7 downto byte * 8));
              end loop;
            end if;
            if word_index = Q8_BLOCK_WORDS_C - 1 then
              word_index <= 0;
              if q8_index = Q8_BLOCKS_PER_Q1_C - 1 then
                state <= REQUEST_Q1;
              else
                q8_index <= q8_index + 1;
                state <= REQUEST_Q8;
              end if;
            else
              word_index <= word_index + 1;
            end if;
          end if;

        when REQUEST_Q1 =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= CONSUME_Q1;
          end if;

        when CONSUME_Q1 =>
          if input_accept = '1' then
            if word_index = 0 then
              q1_scale_fp16 <= input_data_i(15 downto 0);
            else
              sign_base_v := (word_index - 1) * 32;
              q1_signs(sign_base_v + 31 downto sign_base_v) <= input_data_i;
            end if;
            if word_index = Q1_GROUP_WORDS_C - 1 then
              compute_block   <= 0;
              lane_index      <= 0;
              integer_partial <= (others => '0');
              row_accumulator <= (others => '0');
              state <= COMPUTE;
            else
              word_index <= word_index + 1;
            end if;
          end if;

        when COMPUTE =>
          lane_v := resize(q8_values(
              compute_block * Q8_BLOCK_ELEMENTS_C + lane_index), 32);
          if q1_signs(compute_block * Q8_BLOCK_ELEMENTS_C + lane_index) = '1' then
            next_partial_v := integer_partial + lane_v;
          else
            next_partial_v := integer_partial - lane_v;
          end if;

          if lane_index = Q8_BLOCK_ELEMENTS_C - 1 then
            scale_product_v := fp16_to_q8(q1_scale_fp16) * q8_scales(compute_block);
            scaled_wide_v := scale_product_v * next_partial_v;
            scaled_low_v := resize(scaled_wide_v, 64);
            contribution_v := shift_right(scaled_low_v, 16);
            next_accumulator_v := row_accumulator + contribution_v;
            integer_partial <= (others => '0');
            lane_index <= 0;
            row_accumulator <= next_accumulator_v;
            if compute_block = Q8_BLOCKS_PER_Q1_C - 1 then
              output_result <= saturate_i16(next_accumulator_v);
              state <= REQUEST_OUTPUT;
            else
              compute_block <= compute_block + 1;
            end if;
          else
            integer_partial <= next_partial_v;
            lane_index <= lane_index + 1;
          end if;

        when REQUEST_OUTPUT =>
          if transaction_ready_i = '1' then
            state <= PRODUCE_OUTPUT;
          end if;

        when PRODUCE_OUTPUT =>
          if output_accept = '1' then
            state <= IDLE;
          end if;
      end case;
    end if;
  end process control;
end rtl;

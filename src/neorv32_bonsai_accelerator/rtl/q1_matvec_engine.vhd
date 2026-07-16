-- Streaming Q1_0 x Q8_0 row engine, processing one 128-element group at a time.

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
    scale_fixed_i : in std_ulogic;

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
  constant MAX_GROUPS_C : natural := 16384; -- Four 16-bit Q8 tile IDs per group.
  type state_t is (
    IDLE, REQUEST_Q8, CONSUME_Q8, REQUEST_Q1, CONSUME_Q1,
    REDUCE_BLOCK, SCALE_BLOCK, ACCUMULATE_BLOCK,
    REQUEST_OUTPUT, PRODUCE_OUTPUT, ERROR_STATE
  );
  type q8_value_array_t is array (0 to Q1_GROUP_ELEMENTS_C - 1) of signed(7 downto 0);
  type q8_scale_array_t is array (0 to Q8_BLOCKS_PER_Q1_C - 1) of signed(31 downto 0);

  signal state : state_t;
  signal q8_index, compute_block : natural range 0 to Q8_BLOCKS_PER_Q1_C - 1;
  signal reduce_step : natural range 0 to 7;
  signal group_index : natural range 0 to MAX_GROUPS_C - 1;
  signal group_count : natural range 1 to MAX_GROUPS_C;
  signal row_index : natural range 0 to 65534;
  signal row_count : natural range 1 to 65535;
  signal word_index : natural range 0 to Q8_BLOCK_WORDS_C - 1;
  signal q8_values : q8_value_array_t;
  signal q8_scales : q8_scale_array_t;
  signal q1_signs : std_ulogic_vector(Q1_GROUP_ELEMENTS_C - 1 downto 0);
  signal scale_fixed : std_ulogic;
  signal q1_scale_q8, block_sum, reduction_accumulator : signed(31 downto 0);
  signal scale_product : signed(63 downto 0);
  signal row_accumulator : signed(63 downto 0);
  signal output_result : std_ulogic_vector(31 downto 0);
  signal input_accept, output_accept : std_ulogic;

  function fp16_to_q8(h : std_ulogic_vector(15 downto 0)) return signed is
    variable exponent_v, mantissa_v : integer;
    variable value_v : signed(31 downto 0);
  begin
    exponent_v := to_integer(unsigned(h(14 downto 10)));
    mantissa_v := to_integer(unsigned(h(9 downto 0)));
    if exponent_v = 0 then
      value_v := (others => '0');
    elsif exponent_v = 31 then
      value_v := (others => '0');
    else
      mantissa_v := mantissa_v + 1024;
      exponent_v := exponent_v - 15;
      value_v := to_signed(mantissa_v * 256, 32);
      if exponent_v >= 10 then
        value_v := shift_left(value_v, exponent_v - 10);
      else
        value_v := shift_right(value_v, 10 - exponent_v);
      end if;
    end if;
    if h(15) = '1' then
      return -value_v;
    end if;
    return value_v;
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
  transaction_tile_o <=
    std_ulogic_vector(to_unsigned(group_index * Q8_BLOCKS_PER_Q1_C + q8_index, 16))
      when state = REQUEST_Q8 else
    std_ulogic_vector(to_unsigned(row_index * group_count + group_index, 16))
      when state = REQUEST_Q1 else
    std_ulogic_vector(to_unsigned(row_index, 16));
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
  done_o  <= '1' when (state = PRODUCE_OUTPUT) and (output_accept = '1') and
                       (row_index = row_count - 1) else '0';
  error_o <= '1' when state = ERROR_STATE else '0';
  active_o <= '1' when
    (state = REDUCE_BLOCK) or (state = SCALE_BLOCK) or
    (state = ACCUMULATE_BLOCK) else input_accept or output_accept;
  input_wait_o <= '1' when
    ((state = CONSUME_Q8) or (state = CONSUME_Q1)) and input_valid_i = '0' else '0';
  output_wait_o <= '1' when state = PRODUCE_OUTPUT and output_ready_i = '0' else '0';
  work_o <= x"00000001" when
    (state = ACCUMULATE_BLOCK) and
    (compute_block = Q8_BLOCKS_PER_Q1_C - 1) else (others => '0');

  control : process(rstn_i, clk_i)
    variable value_base_v, sign_base_v : natural;
    variable lane_v, reduction_v : signed(31 downto 0);
    variable scaled_wide_v : signed(95 downto 0);
    variable scaled_low_v, contribution_v, next_accumulator_v : signed(63 downto 0);
    variable requested_groups_v : natural range 0 to 65535;
    variable requested_rows_v : natural range 0 to 65535;
    variable q1_tile_count_v : unsigned(31 downto 0);
  begin
    if rstn_i = '0' then
      state             <= IDLE;
      q8_index          <= 0;
      compute_block     <= 0;
      reduce_step       <= 0;
      group_index       <= 0;
      group_count       <= 1;
      row_index         <= 0;
      row_count         <= 1;
      word_index        <= 0;
      q1_signs          <= (others => '0');
      scale_fixed       <= Q1_SCALE_FP16_C;
      q1_scale_q8       <= (others => '0');
      block_sum         <= (others => '0');
      reduction_accumulator <= (others => '0');
      scale_product     <= (others => '0');
      row_accumulator   <= (others => '0');
      output_result     <= (others => '0');
    elsif rising_edge(clk_i) then
      case state is
        when IDLE | ERROR_STATE =>
          if launch_i = '1' then
            q8_index        <= 0;
            compute_block   <= 0;
            reduce_step     <= 0;
            group_index     <= 0;
            row_index       <= 0;
            word_index      <= 0;
            scale_fixed     <= scale_fixed_i;
            q1_signs        <= (others => '0');
            q1_scale_q8     <= (others => '0');
            block_sum       <= (others => '0');
            reduction_accumulator <= (others => '0');
            scale_product   <= (others => '0');
            row_accumulator <= (others => '0');
            output_result   <= (others => '0');
            requested_groups_v := to_integer(unsigned(groups_i));
            requested_rows_v := to_integer(unsigned(rows_i));
            q1_tile_count_v := unsigned(rows_i) * unsigned(groups_i);
            if (requested_rows_v > 0) and
               (requested_groups_v > 0) and
               (requested_groups_v <= MAX_GROUPS_C) and
               (q1_tile_count_v <= to_unsigned(65536, 32)) then
              group_count <= requested_groups_v;
              row_count <= requested_rows_v;
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
              if scale_fixed = Q1_SCALE_FIXED_Q8_C then
                q1_scale_q8 <= resize(signed(input_data_i(15 downto 0)), 32);
              else
                q1_scale_q8 <= fp16_to_q8(input_data_i(15 downto 0));
              end if;
            else
              sign_base_v := (word_index - 1) * 32;
              q1_signs(sign_base_v + 31 downto sign_base_v) <= input_data_i;
            end if;
            if word_index = Q1_GROUP_WORDS_C - 1 then
              compute_block   <= 0;
              reduce_step     <= 0;
              reduction_accumulator <= (others => '0');
              state <= REDUCE_BLOCK;
            else
              word_index <= word_index + 1;
            end if;
          end if;

        when REDUCE_BLOCK =>
          reduction_v := reduction_accumulator;
          for lane in 0 to 3 loop
            lane_v := resize(q8_values(
                compute_block * Q8_BLOCK_ELEMENTS_C + reduce_step * 4 + lane), 32);
            if q1_signs(
                compute_block * Q8_BLOCK_ELEMENTS_C + reduce_step * 4 + lane) = '1' then
              reduction_v := reduction_v + lane_v;
            else
              reduction_v := reduction_v - lane_v;
            end if;
          end loop;
          if reduce_step = 7 then
            block_sum <= reduction_v;
            reduce_step <= 0;
            reduction_accumulator <= (others => '0');
            state <= SCALE_BLOCK;
          else
            reduce_step <= reduce_step + 1;
            reduction_accumulator <= reduction_v;
          end if;

        when SCALE_BLOCK =>
          scale_product <= q1_scale_q8 * q8_scales(compute_block);
          state <= ACCUMULATE_BLOCK;

        when ACCUMULATE_BLOCK =>
            scaled_wide_v := scale_product * block_sum;
            scaled_low_v := resize(scaled_wide_v, 64);
            contribution_v := shift_right(scaled_low_v, 16);
            next_accumulator_v := row_accumulator + contribution_v;
            row_accumulator <= next_accumulator_v;
            if compute_block = Q8_BLOCKS_PER_Q1_C - 1 then
              if group_index = group_count - 1 then
                output_result <= saturate_i16(next_accumulator_v);
                state <= REQUEST_OUTPUT;
              else
                group_index <= group_index + 1;
                q8_index <= 0;
                state <= REQUEST_Q8;
              end if;
            else
              compute_block <= compute_block + 1;
              reduce_step <= 0;
              reduction_accumulator <= (others => '0');
              state <= REDUCE_BLOCK;
            end if;

        when REQUEST_OUTPUT =>
          if transaction_ready_i = '1' then
            state <= PRODUCE_OUTPUT;
          end if;

        when PRODUCE_OUTPUT =>
          if output_accept = '1' then
            if row_index = row_count - 1 then
              state <= IDLE;
            else
              row_index         <= row_index + 1;
              group_index       <= 0;
              q8_index          <= 0;
              compute_block     <= 0;
              block_sum         <= (others => '0');
              reduce_step       <= 0;
              reduction_accumulator <= (others => '0');
              scale_product     <= (others => '0');
              row_accumulator   <= (others => '0');
              state <= REQUEST_Q8;
            end if;
          end if;
      end case;
    end if;
  end process control;
end rtl;

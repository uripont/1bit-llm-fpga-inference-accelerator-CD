-- Tiled attention/KV service with fixed-point score, softmax and value phases.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity attn_kv_engine is
  port (
    clk_i  : in std_ulogic;
    rstn_i : in std_ulogic;
    launch_i : in std_ulogic;
    heads_i           : in std_ulogic_vector(7 downto 0);
    kv_heads_i        : in std_ulogic_vector(7 downto 0);
    head_dim_i        : in std_ulogic_vector(15 downto 0);
    context_length_i  : in std_ulogic_vector(15 downto 0);
    append_position_i : in std_ulogic_vector(15 downto 0);

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
end attn_kv_engine;

architecture rtl of attn_kv_engine is
  constant MAX_SEGMENTS_C : natural :=
    (ATTN_MAX_HEAD_DIM_C + ATTN_VECTOR_TILE_ELEMENTS_C - 1) /
    ATTN_VECTOR_TILE_ELEMENTS_C;

  type state_t is (
    IDLE,
    REQUEST_CURRENT_K, CONSUME_CURRENT_K,
    REQUEST_APPEND_K, PRODUCE_APPEND_K,
    REQUEST_CURRENT_V, CONSUME_CURRENT_V,
    REQUEST_APPEND_V, PRODUCE_APPEND_V,
    PREPARE_HEAD,
    REQUEST_QUERY, CONSUME_QUERY,
    SELECT_K_POSITION, CAPTURE_CURRENT_K_SCORE, ACCUMULATE_CURRENT_K_SCORE,
    REQUEST_K_CACHE, CONSUME_K_CACHE, ACCUMULATE_K_CACHE_LOW,
    CAPTURE_K_CACHE_HIGH, ACCUMULATE_K_CACHE_HIGH, SCALE_SCORE, STORE_SCORE,
    NORMALIZE_FIND_MAX, NORMALIZE_EXP_CAPTURE, NORMALIZE_EXP_SUM,
    NORMALIZE_DIVIDE_CAPTURE, NORMALIZE_DIVIDE_PREPARE, NORMALIZE_DIVIDE_STEP,
    SELECT_V_POSITION, CAPTURE_CURRENT_V_WEIGHT, ACCUMULATE_CURRENT_V,
    REQUEST_V_CACHE, CONSUME_V_CACHE, ACCUMULATE_V_CACHE_LOW,
    CAPTURE_V_CACHE_HIGH, ACCUMULATE_V_CACHE_HIGH,
    REQUEST_OUTPUT, PREPARE_OUTPUT_LOW, PREPARE_OUTPUT_HIGH, PRODUCE_OUTPUT,
    ERROR_STATE
  );

  signal state : state_t;
  signal head_count : natural range 1 to ATTN_MAX_QUERY_HEADS_C;
  signal kv_head_count : natural range 1 to ATTN_MAX_KV_HEADS_C;
  signal head_dim_count : natural range 16 to ATTN_MAX_HEAD_DIM_C;
  signal context_count : natural range 1 to ATTN_SCORE_CAPACITY_C;
  signal append_position : natural range 0 to ATTN_SCORE_CAPACITY_C - 1;
  signal segment_count : natural range 1 to MAX_SEGMENTS_C;
  signal head_index : natural range 0 to ATTN_MAX_QUERY_HEADS_C - 1;
  signal kv_head_index : natural range 0 to ATTN_MAX_KV_HEADS_C - 1;
  signal context_index : natural range 0 to ATTN_SCORE_CAPACITY_C - 1;
  signal segment_index : natural range 0 to MAX_SEGMENTS_C - 1;
  signal word_index : natural range 0 to ATTN_VECTOR_TILE_WORDS_C - 1;
  type append_tile_t is array (0 to ATTN_VECTOR_TILE_WORDS_C - 1) of
    std_ulogic_vector(31 downto 0);
  signal append_tile : append_tile_t;
  type vector_t is array (0 to ATTN_MAX_HEAD_DIM_C - 1) of signed(15 downto 0);
  type kv_vector_t is array (
    0 to ATTN_MAX_KV_HEADS_C * ATTN_MAX_HEAD_DIM_C - 1) of signed(15 downto 0);
  type score_memory_t is array (0 to ATTN_SCORE_CAPACITY_C - 1) of signed(39 downto 0);
  type weight_memory_t is array (0 to ATTN_SCORE_CAPACITY_C - 1) of unsigned(15 downto 0);
  type output_accumulator_t is array (
    0 to ATTN_MAX_HEAD_DIM_C - 1) of signed(32 downto 0);
  signal query_values : vector_t;
  signal current_k_values, current_v_values : kv_vector_t;
  signal scores : score_memory_t;
  signal normalized_weights : weight_memory_t;
  signal output_accumulators : output_accumulator_t;
  signal score_accumulator : signed(39 downto 0);
  signal max_score : signed(39 downto 0);
  signal exp_sum : unsigned(24 downto 0);
  signal normalization_exp_value : unsigned(16 downto 0);
  signal score_word_index : natural range 0 to ATTN_MAX_HEAD_DIM_C - 1;
  signal value_word_index : natural range 0 to ATTN_MAX_HEAD_DIM_C - 1;
  signal normalization_index : natural range 0 to ATTN_SCORE_CAPACITY_C - 1;
  signal divide_bit : natural range 0 to 15;
  signal divide_remainder : unsigned(32 downto 0);
  signal divide_threshold : unsigned(32 downto 0);
  signal divide_quotient : unsigned(15 downto 0);
  signal input_accept, output_accept : std_ulogic;
  signal tile_words : natural range 1 to ATTN_VECTOR_TILE_WORDS_C;
  signal mapped_kv_head : natural range 0 to ATTN_MAX_KV_HEADS_C - 1;
  signal transaction_tile : natural range 0 to ATTN_SCORE_CAPACITY_C - 1;
  signal work_per_head : unsigned(31 downto 0);
  signal pending_input_high : signed(15 downto 0);
  signal arithmetic_a : signed(16 downto 0);
  signal arithmetic_b : signed(15 downto 0);
  signal arithmetic_product : signed(32 downto 0);
  signal scaled_score : signed(39 downto 0);
  signal output_low : signed(15 downto 0);
  signal output_word : std_ulogic_vector(31 downto 0);

  function inv_sqrt_q16(head_dim : natural) return signed is
  begin
    case head_dim is
      when 16 => return to_signed(16384, 16);
      when 32 => return to_signed(11585, 16);
      when 64 => return to_signed(8192, 16);
      when 128 => return to_signed(5793, 16);
      when others => return to_signed(0, 16);
    end case;
  end function;

  type exp_lut_t is array (natural range <>) of natural;
  -- Scores use Q16.16; exponentials and normalized weights use unsigned Q0.16.
  constant EXP_INTEGER_Q16_C : exp_lut_t(0 to 11) := (
    65536, 24109, 8869, 3263, 1200, 442, 162, 60, 22, 8, 3, 1);
  constant EXP_FRACTION_Q16_C : exp_lut_t(0 to 15) := (
    65536, 61565, 57835, 54331, 51039, 47947, 45042, 42313,
    39750, 37341, 35079, 32954, 30957, 29081, 27319, 25664);

  function exp_negative_q16(delta : signed(39 downto 0)) return unsigned is
    variable magnitude : unsigned(39 downto 0);
    variable integer_part, fraction_index : natural;
    variable product, rounded : unsigned(33 downto 0);
  begin
    if delta >= 0 then
      return to_unsigned(65536, 17);
    elsif delta <= to_signed(-12 * 65536, 40) then
      return to_unsigned(0, 17);
    end if;
    magnitude := unsigned(-delta);
    integer_part := to_integer(magnitude(19 downto 16));
    fraction_index := to_integer(magnitude(15 downto 12));
    product := to_unsigned(EXP_INTEGER_Q16_C(integer_part), 17) *
               to_unsigned(EXP_FRACTION_Q16_C(fraction_index), 17);
    rounded := product + to_unsigned(32768, 34);
    return resize(shift_right(rounded, 16), 17);
  end function;

  function rounded_output(value : signed(32 downto 0)) return signed is
    variable rounded, magnitude : signed(32 downto 0);
  begin
    if value >= 0 then
      rounded := shift_right(value + to_signed(32768, 33), 16);
    else
      magnitude := -value;
      rounded := -shift_right(magnitude + to_signed(32768, 33), 16);
    end if;
    if rounded > to_signed(32767, 33) then
      return to_signed(32767, 16);
    elsif rounded < to_signed(-32768, 33) then
      return to_signed(-32768, 16);
    end if;
    return resize(rounded, 16);
  end function;

  function words_for_segment(
      head_dim : natural; segment : natural) return natural is
    variable remaining, elements : natural;
  begin
    remaining := head_dim - segment * ATTN_VECTOR_TILE_ELEMENTS_C;
    if remaining > ATTN_VECTOR_TILE_ELEMENTS_C then
      elements := ATTN_VECTOR_TILE_ELEMENTS_C;
    else
      elements := remaining;
    end if;
    return (elements + 1) / 2;
  end function;

begin
  -- The board implementation supports one KV head; all query heads share it.
  mapped_kv_head <= 0;
  tile_words <= words_for_segment(head_dim_count, segment_index);
  work_per_head <= shift_left(to_unsigned(context_count, 32), 5)
    when head_dim_count = 16 else
    shift_left(to_unsigned(context_count, 32), 6);

  arithmetic_operands : process(all)
    variable element_v : natural range 0 to ATTN_MAX_HEAD_DIM_C - 1;
  begin
    arithmetic_a <= (others => '0');
    arithmetic_b <= (others => '0');
    element_v := 0;
    case state is
      when CAPTURE_CURRENT_K_SCORE =>
        arithmetic_a <= resize(query_values(score_word_index), 17);
        arithmetic_b <= current_k_values(score_word_index);
      when CONSUME_K_CACHE =>
        element_v := word_index * 2;
        arithmetic_a <= resize(query_values(element_v), 17);
        arithmetic_b <= signed(input_data_i(15 downto 0));
      when CAPTURE_K_CACHE_HIGH =>
        element_v := word_index * 2 + 1;
        arithmetic_a <= resize(query_values(element_v), 17);
        arithmetic_b <= pending_input_high;
      when CAPTURE_CURRENT_V_WEIGHT =>
        arithmetic_a <= signed(
          '0' & std_ulogic_vector(normalized_weights(context_index)));
        arithmetic_b <= current_v_values(value_word_index);
      when CONSUME_V_CACHE =>
        arithmetic_a <= signed(
          '0' & std_ulogic_vector(normalized_weights(context_index)));
        arithmetic_b <= signed(input_data_i(15 downto 0));
      when CAPTURE_V_CACHE_HIGH =>
        arithmetic_a <= signed(
          '0' & std_ulogic_vector(normalized_weights(context_index)));
        arithmetic_b <= pending_input_high;
      when others => null;
    end case;
  end process arithmetic_operands;

  arithmetic_pipeline : process(rstn_i, clk_i)
  begin
    if rstn_i = '0' then
      arithmetic_product <= (others => '0');
    elsif rising_edge(clk_i) then
      arithmetic_product <= arithmetic_a * arithmetic_b;
    end if;
  end process arithmetic_pipeline;

  transaction_valid_o <= '1' when
    (state = REQUEST_CURRENT_K) or (state = REQUEST_CURRENT_V) or
    (state = REQUEST_APPEND_K) or (state = REQUEST_APPEND_V) or
    (state = REQUEST_QUERY) or (state = REQUEST_K_CACHE) or
    (state = REQUEST_V_CACHE) or (state = REQUEST_OUTPUT) else '0';
  transaction_direction_o <= TILE_DIRECTION_OUTPUT_C when
    (state = REQUEST_APPEND_K) or (state = REQUEST_APPEND_V) or
    (state = REQUEST_OUTPUT)
    else TILE_DIRECTION_INPUT_C;
  transaction_role_o <=
    ROLE_CURRENT_K_C when
      (state = REQUEST_CURRENT_K) or (state = REQUEST_APPEND_K) else
    ROLE_CURRENT_V_C when
      (state = REQUEST_CURRENT_V) or (state = REQUEST_APPEND_V) else
    ROLE_QUERY_C when state = REQUEST_QUERY else
    ROLE_K_CACHE_C when state = REQUEST_K_CACHE else
    ROLE_V_CACHE_C when state = REQUEST_V_CACHE else
    ROLE_OUTPUT_C;

  transaction_tile <=
    0
      when (state = REQUEST_CURRENT_K) or (state = REQUEST_APPEND_K) or
           (state = REQUEST_CURRENT_V) or (state = REQUEST_APPEND_V) else
    head_index
      when (state = REQUEST_QUERY) or (state = REQUEST_OUTPUT) else
    context_index;
  transaction_tile_o <= std_ulogic_vector(to_unsigned(transaction_tile, 16));
  transaction_length_o <= std_ulogic_vector(to_unsigned(tile_words, 16));

  input_ready_o <= '1' when
    (state = CONSUME_CURRENT_K) or (state = CONSUME_CURRENT_V) or
    (state = CONSUME_QUERY) or (state = CONSUME_K_CACHE) or
    (state = CONSUME_V_CACHE) else '0';
  input_accept <= input_valid_i and input_ready_o;

  output_valid_o <= '1' when
    (state = PRODUCE_APPEND_K) or (state = PRODUCE_APPEND_V) or
    (state = PRODUCE_OUTPUT) else '0';
  output_data_o <= append_tile(word_index) when
    (state = PRODUCE_APPEND_K) or (state = PRODUCE_APPEND_V) else
    output_word;
  output_accept <= output_valid_o and output_ready_i;

  busy_o <= '0' when (state = IDLE) or (state = ERROR_STATE) else '1';
  done_o <= '1' when
    (state = PRODUCE_OUTPUT) and (output_accept = '1') and
    (head_index = head_count - 1) and (segment_index = segment_count - 1) and
    (word_index = tile_words - 1) else '0';
  error_o <= '1' when state = ERROR_STATE else '0';
  active_o <= '1' when
    (state = CAPTURE_CURRENT_K_SCORE) or
    (state = ACCUMULATE_CURRENT_K_SCORE) or
    (state = ACCUMULATE_K_CACHE_LOW) or
    (state = CAPTURE_K_CACHE_HIGH) or
    (state = ACCUMULATE_K_CACHE_HIGH) or
    (state = SCALE_SCORE) or
    (state = STORE_SCORE) or
    (state = NORMALIZE_FIND_MAX) or
    (state = NORMALIZE_EXP_CAPTURE) or
    (state = NORMALIZE_EXP_SUM) or
    (state = NORMALIZE_DIVIDE_CAPTURE) or
    (state = NORMALIZE_DIVIDE_PREPARE) or
    (state = NORMALIZE_DIVIDE_STEP) or
    (state = CAPTURE_CURRENT_V_WEIGHT) or
    (state = ACCUMULATE_CURRENT_V) or
    (state = ACCUMULATE_V_CACHE_LOW) or
    (state = CAPTURE_V_CACHE_HIGH) or
    (state = ACCUMULATE_V_CACHE_HIGH)
    else input_accept or output_accept;
  input_wait_o <= '1' when input_ready_o = '1' and input_valid_i = '0' else '0';
  output_wait_o <= '1' when
    output_valid_o = '1' and (output_ready_i = '0') else '0';
  work_o <= std_ulogic_vector(work_per_head) when
    (state = PRODUCE_OUTPUT) and (output_accept = '1') and
    (segment_index = segment_count - 1) and (word_index = tile_words - 1)
    else (others => '0');

  control : process(rstn_i, clk_i)
    variable heads_v, kv_heads_v, head_dim_v : natural;
    variable context_v, append_v, segments_v : natural;
    variable element_base_v, current_base_v : natural;
    variable next_score_v : signed(39 downto 0);
    variable scaled_wide_v : signed(55 downto 0);
    variable next_exp_sum_v : unsigned(24 downto 0);
    variable divide_threshold_v, divide_remainder_v : unsigned(32 downto 0);
    variable divide_quotient_v : unsigned(15 downto 0);
  begin
    if rstn_i = '0' then
      state           <= IDLE;
      head_count      <= 1;
      kv_head_count   <= 1;
      head_dim_count  <= 16;
      context_count   <= 1;
      append_position <= 0;
      segment_count   <= 1;
      head_index      <= 0;
      kv_head_index   <= 0;
      context_index   <= 0;
      segment_index   <= 0;
      word_index      <= 0;
      score_accumulator <= (others => '0');
      max_score <= (others => '0');
      exp_sum <= (others => '0');
      normalization_exp_value <= (others => '0');
      score_word_index <= 0;
      value_word_index <= 0;
      normalization_index <= 0;
      divide_bit <= 0;
      divide_remainder <= (others => '0');
      divide_threshold <= (others => '0');
      divide_quotient <= (others => '0');
      pending_input_high <= (others => '0');
      output_low <= (others => '0');
      output_word <= (others => '0');
      scaled_score <= (others => '0');
    elsif rising_edge(clk_i) then
      case state is
        when IDLE | ERROR_STATE =>
          if launch_i = '1' then
            heads_v := to_integer(unsigned(heads_i));
            kv_heads_v := to_integer(unsigned(kv_heads_i));
            head_dim_v := to_integer(unsigned(head_dim_i));
            context_v := to_integer(unsigned(context_length_i));
            append_v := to_integer(unsigned(append_position_i));
            segments_v := 1;
            if (heads_v > 0) and (heads_v <= ATTN_MAX_QUERY_HEADS_C) and
               (kv_heads_v = 1) and
               (context_v > 0) and (append_v < context_v) and
               ((head_dim_v = 16) or (head_dim_v = 32)) and
               (context_v <= ATTN_SCORE_CAPACITY_C) then
              head_count      <= heads_v;
              kv_head_count   <= 1;
              head_dim_count  <= head_dim_v;
              context_count   <= context_v;
              append_position <= append_v;
              segment_count   <= 1;
              head_index      <= 0;
              kv_head_index   <= 0;
              context_index   <= 0;
              segment_index   <= 0;
              word_index      <= 0;
              score_accumulator <= (others => '0');
              max_score <= (others => '0');
              exp_sum <= (others => '0');
              normalization_exp_value <= (others => '0');
              score_word_index <= 0;
              value_word_index <= 0;
              normalization_index <= 0;
              divide_bit <= 0;
              divide_remainder <= (others => '0');
              divide_threshold <= (others => '0');
              divide_quotient <= (others => '0');
              pending_input_high <= (others => '0');
              output_low <= (others => '0');
              output_word <= (others => '0');
              scaled_score <= (others => '0');
              state           <= REQUEST_CURRENT_K;
            else
              state <= ERROR_STATE;
            end if;
          end if;

        when REQUEST_CURRENT_K =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= CONSUME_CURRENT_K;
          end if;

        when CONSUME_CURRENT_K =>
          if input_accept = '1' then
            append_tile(word_index) <= input_data_i;
            element_base_v := segment_index * ATTN_VECTOR_TILE_ELEMENTS_C +
                              word_index * 2;
            current_base_v := element_base_v;
            current_k_values(current_base_v) <= signed(input_data_i(15 downto 0));
            if element_base_v + 1 < head_dim_count then
              current_k_values(current_base_v + 1) <= signed(input_data_i(31 downto 16));
            end if;
            if word_index = tile_words - 1 then
              word_index <= 0;
              state <= REQUEST_APPEND_K;
            else
              word_index <= word_index + 1;
            end if;
          end if;

        when REQUEST_APPEND_K =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= PRODUCE_APPEND_K;
          end if;

        when PRODUCE_APPEND_K =>
          if output_accept = '1' then
            if word_index = tile_words - 1 then
              word_index <= 0;
              if segment_index = segment_count - 1 then
                segment_index <= 0;
                state <= REQUEST_CURRENT_V;
              else
                segment_index <= segment_index + 1;
                state <= REQUEST_CURRENT_K;
              end if;
            else
              word_index <= word_index + 1;
            end if;
          end if;

        when REQUEST_CURRENT_V =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= CONSUME_CURRENT_V;
          end if;

        when CONSUME_CURRENT_V =>
          if input_accept = '1' then
            append_tile(word_index) <= input_data_i;
            element_base_v := segment_index * ATTN_VECTOR_TILE_ELEMENTS_C +
                              word_index * 2;
            current_base_v := element_base_v;
            current_v_values(current_base_v) <= signed(input_data_i(15 downto 0));
            if element_base_v + 1 < head_dim_count then
              current_v_values(current_base_v + 1) <= signed(input_data_i(31 downto 16));
            end if;
            if word_index = tile_words - 1 then
              word_index <= 0;
              state <= REQUEST_APPEND_V;
            else
              word_index <= word_index + 1;
            end if;
          end if;

        when REQUEST_APPEND_V =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= PRODUCE_APPEND_V;
          end if;

        when PRODUCE_APPEND_V =>
          if output_accept = '1' then
            if word_index = tile_words - 1 then
              word_index <= 0;
              if segment_index = segment_count - 1 then
                segment_index <= 0;
                if kv_head_index = kv_head_count - 1 then
                  kv_head_index <= 0;
                  state <= PREPARE_HEAD;
                else
                  kv_head_index <= kv_head_index + 1;
                  state <= REQUEST_CURRENT_K;
                end if;
              else
                segment_index <= segment_index + 1;
                state <= REQUEST_CURRENT_V;
              end if;
            else
              word_index <= word_index + 1;
            end if;
          end if;

        when PREPARE_HEAD =>
          segment_index <= 0;
          word_index <= 0;
          score_accumulator <= (others => '0');
          exp_sum <= (others => '0');
          score_word_index <= 0;
          normalization_index <= 0;
          output_accumulators(value_word_index) <= (others => '0');
          if value_word_index = head_dim_count - 1 then
            value_word_index <= 0;
            state <= REQUEST_QUERY;
          else
            value_word_index <= value_word_index + 1;
          end if;

        when REQUEST_QUERY =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= CONSUME_QUERY;
          end if;

        when CONSUME_QUERY =>
          if input_accept = '1' then
            element_base_v := segment_index * ATTN_VECTOR_TILE_ELEMENTS_C +
                              word_index * 2;
            query_values(element_base_v) <= signed(input_data_i(15 downto 0));
            if element_base_v + 1 < head_dim_count then
              query_values(element_base_v + 1) <= signed(input_data_i(31 downto 16));
            end if;
            if word_index = tile_words - 1 then
              word_index <= 0;
              if segment_index = segment_count - 1 then
                segment_index <= 0;
                context_index <= 0;
                state <= SELECT_K_POSITION;
              else
                segment_index <= segment_index + 1;
                state <= REQUEST_QUERY;
              end if;
            else
              word_index <= word_index + 1;
            end if;
          end if;

        when SELECT_K_POSITION =>
          if context_index = append_position then
            score_accumulator <= (others => '0');
            score_word_index <= 0;
            state <= CAPTURE_CURRENT_K_SCORE;
          else
            segment_index <= 0;
            score_accumulator <= (others => '0');
            state <= REQUEST_K_CACHE;
          end if;

        when CAPTURE_CURRENT_K_SCORE =>
          state <= ACCUMULATE_CURRENT_K_SCORE;

        when ACCUMULATE_CURRENT_K_SCORE =>
          next_score_v := score_accumulator + resize(arithmetic_product, 40);
          score_accumulator <= next_score_v;
          if score_word_index = head_dim_count - 1 then
            score_word_index <= 0;
            state <= SCALE_SCORE;
          else
            score_word_index <= score_word_index + 1;
            state <= CAPTURE_CURRENT_K_SCORE;
          end if;

        when REQUEST_K_CACHE =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= CONSUME_K_CACHE;
          end if;

        when CONSUME_K_CACHE =>
          if input_accept = '1' then
            pending_input_high <= signed(input_data_i(31 downto 16));
            state <= ACCUMULATE_K_CACHE_LOW;
          end if;

        when ACCUMULATE_K_CACHE_LOW =>
            next_score_v := score_accumulator + resize(arithmetic_product, 40);
            score_accumulator <= next_score_v;
            state <= CAPTURE_K_CACHE_HIGH;

        when CAPTURE_K_CACHE_HIGH =>
            state <= ACCUMULATE_K_CACHE_HIGH;

        when ACCUMULATE_K_CACHE_HIGH =>
            next_score_v := score_accumulator + resize(arithmetic_product, 40);
            score_accumulator <= next_score_v;
            if word_index = tile_words - 1 then
              word_index <= 0;
              if segment_index = segment_count - 1 then
                segment_index <= 0;
                state <= SCALE_SCORE;
              else
                segment_index <= segment_index + 1;
                state <= REQUEST_K_CACHE;
              end if;
            else
              word_index <= word_index + 1;
              state <= CONSUME_K_CACHE;
            end if;

        when SCALE_SCORE =>
          scaled_wide_v := score_accumulator * inv_sqrt_q16(head_dim_count);
          scaled_score <= resize(shift_right(scaled_wide_v, 16), 40);
          state <= STORE_SCORE;

        when STORE_SCORE =>
          scores(context_index) <= scaled_score;
          score_accumulator <= (others => '0');
          if context_index = context_count - 1 then
            context_index <= 0;
            normalization_index <= 0;
            state <= NORMALIZE_FIND_MAX;
          else
            context_index <= context_index + 1;
            state <= SELECT_K_POSITION;
          end if;

        when NORMALIZE_FIND_MAX =>
          if (normalization_index = 0) or
             (scores(normalization_index) > max_score) then
            max_score <= scores(normalization_index);
          end if;
          if normalization_index = context_count - 1 then
            normalization_index <= 0;
            exp_sum <= (others => '0');
            state <= NORMALIZE_EXP_CAPTURE;
          else
            normalization_index <= normalization_index + 1;
          end if;

        when NORMALIZE_EXP_CAPTURE =>
          normalization_exp_value <= exp_negative_q16(
            scores(normalization_index) - max_score);
          state <= NORMALIZE_EXP_SUM;

        when NORMALIZE_EXP_SUM =>
          next_exp_sum_v := exp_sum + resize(normalization_exp_value, 25);
          exp_sum <= next_exp_sum_v;
          if normalization_index = context_count - 1 then
            normalization_index <= 0;
            state <= NORMALIZE_DIVIDE_CAPTURE;
          else
            normalization_index <= normalization_index + 1;
            state <= NORMALIZE_EXP_CAPTURE;
          end if;

        when NORMALIZE_DIVIDE_CAPTURE =>
          normalization_exp_value <= exp_negative_q16(
            scores(normalization_index) - max_score);
          state <= NORMALIZE_DIVIDE_PREPARE;

        when NORMALIZE_DIVIDE_PREPARE =>
          divide_remainder <=
            shift_left(resize(normalization_exp_value, 33), 16) -
            resize(normalization_exp_value, 33) +
            resize(shift_right(exp_sum, 1), 33);
          divide_quotient <= (others => '0');
          divide_threshold <= shift_left(resize(exp_sum, 33), 15);
          divide_bit <= 15;
          state <= NORMALIZE_DIVIDE_STEP;

        when NORMALIZE_DIVIDE_STEP =>
          divide_threshold_v := divide_threshold;
          divide_remainder_v := divide_remainder;
          divide_quotient_v := divide_quotient;
          if divide_remainder >= divide_threshold_v then
            divide_remainder_v := divide_remainder - divide_threshold_v;
            divide_quotient_v(divide_bit) := '1';
          end if;
          divide_remainder <= divide_remainder_v;
          divide_threshold <= shift_right(divide_threshold, 1);
          divide_quotient <= divide_quotient_v;
          if divide_bit = 0 then
            normalized_weights(normalization_index) <= divide_quotient_v;
            if normalization_index = context_count - 1 then
              normalization_index <= 0;
              context_index <= 0;
              segment_index <= 0;
              state <= SELECT_V_POSITION;
            else
              normalization_index <= normalization_index + 1;
              state <= NORMALIZE_DIVIDE_CAPTURE;
            end if;
          else
            divide_bit <= divide_bit - 1;
          end if;

        when SELECT_V_POSITION =>
          if context_index = append_position then
            value_word_index <= 0;
            state <= CAPTURE_CURRENT_V_WEIGHT;
          else
            segment_index <= 0;
            state <= REQUEST_V_CACHE;
          end if;

        when CAPTURE_CURRENT_V_WEIGHT =>
          state <= ACCUMULATE_CURRENT_V;

        when ACCUMULATE_CURRENT_V =>
          output_accumulators(value_word_index) <=
            output_accumulators(value_word_index) + resize(arithmetic_product, 33);
          if value_word_index = head_dim_count - 1 then
            value_word_index <= 0;
            if context_index = context_count - 1 then
              context_index <= 0;
              state <= REQUEST_OUTPUT;
            else
              context_index <= context_index + 1;
              state <= SELECT_V_POSITION;
            end if;
          else
            value_word_index <= value_word_index + 1;
            state <= CAPTURE_CURRENT_V_WEIGHT;
          end if;

        when REQUEST_V_CACHE =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= CONSUME_V_CACHE;
          end if;

        when CONSUME_V_CACHE =>
          if input_accept = '1' then
            pending_input_high <= signed(input_data_i(31 downto 16));
            state <= ACCUMULATE_V_CACHE_LOW;
          end if;

        when ACCUMULATE_V_CACHE_LOW =>
            element_base_v := segment_index * ATTN_VECTOR_TILE_ELEMENTS_C +
                              word_index * 2;
            output_accumulators(element_base_v) <=
              output_accumulators(element_base_v) + resize(arithmetic_product, 33);
            state <= CAPTURE_V_CACHE_HIGH;

        when CAPTURE_V_CACHE_HIGH =>
            state <= ACCUMULATE_V_CACHE_HIGH;

        when ACCUMULATE_V_CACHE_HIGH =>
            element_base_v := segment_index * ATTN_VECTOR_TILE_ELEMENTS_C +
                              word_index * 2 + 1;
            output_accumulators(element_base_v) <=
              output_accumulators(element_base_v) + resize(arithmetic_product, 33);
            if word_index = tile_words - 1 then
              word_index <= 0;
              if segment_index = segment_count - 1 then
                segment_index <= 0;
                if context_index = context_count - 1 then
                  context_index <= 0;
                  state <= REQUEST_OUTPUT;
                else
                  context_index <= context_index + 1;
                  state <= SELECT_V_POSITION;
                end if;
              else
                segment_index <= segment_index + 1;
                state <= REQUEST_V_CACHE;
              end if;
            else
              word_index <= word_index + 1;
              state <= CONSUME_V_CACHE;
            end if;

        when REQUEST_OUTPUT =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= PREPARE_OUTPUT_LOW;
          end if;

        when PREPARE_OUTPUT_LOW =>
          output_low <= rounded_output(output_accumulators(word_index * 2));
          state <= PREPARE_OUTPUT_HIGH;

        when PREPARE_OUTPUT_HIGH =>
          output_word <= std_ulogic_vector(
            rounded_output(output_accumulators(word_index * 2 + 1))) &
            std_ulogic_vector(output_low);
          state <= PRODUCE_OUTPUT;

        when PRODUCE_OUTPUT =>
          if output_accept = '1' then
            if word_index = tile_words - 1 then
              word_index <= 0;
              if segment_index = segment_count - 1 then
                segment_index <= 0;
                if head_index = head_count - 1 then
                  head_index <= 0;
                  state <= IDLE;
                else
                  head_index <= head_index + 1;
                  state <= PREPARE_HEAD;
                end if;
              else
                segment_index <= segment_index + 1;
                state <= REQUEST_OUTPUT;
              end if;
            else
              word_index <= word_index + 1;
              state <= PREPARE_OUTPUT_LOW;
            end if;
          end if;
      end case;
    end if;
  end process control;

end rtl;

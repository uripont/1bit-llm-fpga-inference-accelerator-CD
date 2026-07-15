-- Attention/KV engine with tiled transport and fixed-point QK score computation.

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
    SELECT_K_POSITION, SCORE_CURRENT_K, REQUEST_K_CACHE, CONSUME_K_CACHE,
    NORMALIZE,
    SELECT_V_POSITION, REQUEST_V_CACHE, CONSUME_V_CACHE,
    REQUEST_OUTPUT, PRODUCE_OUTPUT,
    ERROR_STATE
  );

  signal state : state_t;
  signal head_count, kv_head_count : natural range 1 to 255;
  signal head_dim_count, context_count : natural range 1 to 65535;
  signal append_position : natural range 0 to 65534;
  signal segment_count : natural range 1 to MAX_SEGMENTS_C;
  signal head_index, kv_head_index : natural range 0 to 254;
  signal context_index : natural range 0 to 65534;
  signal segment_index : natural range 0 to MAX_SEGMENTS_C - 1;
  signal word_index : natural range 0 to ATTN_VECTOR_TILE_WORDS_C - 1;
  signal append_checksum, head_checksum : unsigned(31 downto 0);
  type append_tile_t is array (0 to ATTN_VECTOR_TILE_WORDS_C - 1) of
    std_ulogic_vector(31 downto 0);
  signal append_tile : append_tile_t;
  type vector_t is array (0 to ATTN_MAX_HEAD_DIM_C - 1) of signed(15 downto 0);
  type kv_vector_t is array (
    0 to ATTN_MAX_KV_HEADS_C * ATTN_MAX_HEAD_DIM_C - 1) of signed(15 downto 0);
  type score_memory_t is array (0 to ATTN_SCORE_CAPACITY_C - 1) of signed(39 downto 0);
  signal query_values : vector_t;
  signal current_k_values, current_v_values : kv_vector_t;
  signal scores : score_memory_t;
  signal score_accumulator : signed(39 downto 0);
  signal score_checksum : unsigned(31 downto 0);
  signal score_word_index : natural range 0 to ATTN_MAX_HEAD_DIM_C / 2 - 1;
  signal input_accept, output_accept : std_ulogic;
  signal tile_words : natural range 1 to ATTN_VECTOR_TILE_WORDS_C;
  signal mapped_kv_head, transaction_tile : natural range 0 to 65535;
  signal work_per_head : unsigned(31 downto 0);

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

  function fold_score(value : signed(39 downto 0)) return unsigned is
    variable extended : signed(63 downto 0);
  begin
    extended := resize(value, 64);
    return unsigned(extended(31 downto 0)) xor
           unsigned(extended(63 downto 32));
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
  mapped_kv_head <= head_index * kv_head_count / head_count;
  tile_words <= words_for_segment(head_dim_count, segment_index);
  work_per_head <= shift_left(
    resize(to_unsigned(context_count, 16) * to_unsigned(head_dim_count, 16), 32), 1);

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
    kv_head_index * segment_count + segment_index
      when (state = REQUEST_CURRENT_K) or (state = REQUEST_APPEND_K) or
           (state = REQUEST_CURRENT_V) or (state = REQUEST_APPEND_V) else
    head_index * segment_count + segment_index
      when (state = REQUEST_QUERY) or (state = REQUEST_OUTPUT) else
    (mapped_kv_head * context_count + context_index) * segment_count + segment_index;
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
    std_ulogic_vector(
    head_checksum xor score_checksum xor
    shift_left(to_unsigned(head_index, 32), 24) xor
    shift_left(to_unsigned(segment_index, 32), 16) xor
    to_unsigned(word_index, 32));
  output_accept <= output_valid_o and output_ready_i;

  busy_o <= '0' when (state = IDLE) or (state = ERROR_STATE) else '1';
  done_o <= '1' when
    (state = PRODUCE_OUTPUT) and (output_accept = '1') and
    (head_index = head_count - 1) and (segment_index = segment_count - 1) and
    (word_index = tile_words - 1) else '0';
  error_o <= '1' when state = ERROR_STATE else '0';
  active_o <= '1' when
    (state = SCORE_CURRENT_K) or (state = NORMALIZE)
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
    variable cache_tiles_per_head_v : natural;
    variable element_base_v, current_base_v : natural;
    variable pair_sum_v : signed(32 downto 0);
    variable next_score_v : signed(39 downto 0);
    variable scaled_wide_v : signed(55 downto 0);
    variable scaled_score_v : signed(39 downto 0);
  begin
    if rstn_i = '0' then
      state           <= IDLE;
      head_count      <= 1;
      kv_head_count   <= 1;
      head_dim_count  <= 1;
      context_count   <= 1;
      append_position <= 0;
      segment_count   <= 1;
      head_index      <= 0;
      kv_head_index   <= 0;
      context_index   <= 0;
      segment_index   <= 0;
      word_index      <= 0;
      append_checksum <= (others => '0');
      head_checksum   <= (others => '0');
      score_accumulator <= (others => '0');
      score_checksum <= (others => '0');
      score_word_index <= 0;
    elsif rising_edge(clk_i) then
      case state is
        when IDLE | ERROR_STATE =>
          if launch_i = '1' then
            heads_v := to_integer(unsigned(heads_i));
            kv_heads_v := to_integer(unsigned(kv_heads_i));
            head_dim_v := to_integer(unsigned(head_dim_i));
            context_v := to_integer(unsigned(context_length_i));
            append_v := to_integer(unsigned(append_position_i));
            segments_v := (head_dim_v + ATTN_VECTOR_TILE_ELEMENTS_C - 1) /
                          ATTN_VECTOR_TILE_ELEMENTS_C;
            if (heads_v > 0) and (kv_heads_v > 0) and (head_dim_v > 0) and
               (context_v > 0) and (append_v < context_v) and
               ((heads_v mod kv_heads_v) = 0) and
               (head_dim_v <= ATTN_MAX_HEAD_DIM_C) and
               (kv_heads_v <= ATTN_MAX_KV_HEADS_C) and
               (context_v <= ATTN_SCORE_CAPACITY_C) and
               (segments_v <= MAX_SEGMENTS_C) and
               (heads_v * segments_v <= 65536) and
               (kv_heads_v * segments_v <= 65536) then
              cache_tiles_per_head_v := context_v * segments_v;
              if kv_heads_v <= 65536 / cache_tiles_per_head_v then
                head_count      <= heads_v;
                kv_head_count   <= kv_heads_v;
                head_dim_count  <= head_dim_v;
                context_count   <= context_v;
                append_position <= append_v;
                segment_count   <= segments_v;
                head_index      <= 0;
                kv_head_index   <= 0;
                context_index   <= 0;
                segment_index   <= 0;
                word_index      <= 0;
                append_checksum <= (others => '0');
                head_checksum   <= (others => '0');
                score_accumulator <= (others => '0');
                score_checksum <= (others => '0');
                score_word_index <= 0;
                state           <= REQUEST_CURRENT_K;
              else
                state <= ERROR_STATE;
              end if;
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
            append_checksum <= append_checksum xor unsigned(input_data_i);
            append_tile(word_index) <= input_data_i;
            element_base_v := segment_index * ATTN_VECTOR_TILE_ELEMENTS_C +
                              word_index * 2;
            current_base_v := kv_head_index * ATTN_MAX_HEAD_DIM_C + element_base_v;
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
            append_checksum <= append_checksum xor unsigned(input_data_i);
            append_tile(word_index) <= input_data_i;
            element_base_v := segment_index * ATTN_VECTOR_TILE_ELEMENTS_C +
                              word_index * 2;
            current_base_v := kv_head_index * ATTN_MAX_HEAD_DIM_C + element_base_v;
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
          head_checksum <= append_checksum;
          score_checksum <= (others => '0');
          score_accumulator <= (others => '0');
          score_word_index <= 0;
          state <= REQUEST_QUERY;

        when REQUEST_QUERY =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= CONSUME_QUERY;
          end if;

        when CONSUME_QUERY =>
          if input_accept = '1' then
            head_checksum <= head_checksum xor unsigned(input_data_i);
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
            state <= SCORE_CURRENT_K;
          else
            segment_index <= 0;
            score_accumulator <= (others => '0');
            state <= REQUEST_K_CACHE;
          end if;

        when SCORE_CURRENT_K =>
          element_base_v := score_word_index * 2;
          current_base_v := mapped_kv_head * ATTN_MAX_HEAD_DIM_C + element_base_v;
          pair_sum_v := resize(
            query_values(element_base_v) * current_k_values(current_base_v), 33);
          if element_base_v + 1 < head_dim_count then
            pair_sum_v := pair_sum_v + resize(
              query_values(element_base_v + 1) * current_k_values(current_base_v + 1), 33);
          end if;
          next_score_v := score_accumulator + resize(pair_sum_v, 40);
          score_accumulator <= next_score_v;
          if score_word_index = (head_dim_count + 1) / 2 - 1 then
            scaled_wide_v := next_score_v * inv_sqrt_q16(head_dim_count);
            scaled_score_v := resize(shift_right(scaled_wide_v, 16), 40);
            scores(context_index) <= scaled_score_v;
            score_checksum <= score_checksum xor fold_score(scaled_score_v);
            score_word_index <= 0;
            score_accumulator <= (others => '0');
            if context_index = context_count - 1 then
              context_index <= 0;
              state <= NORMALIZE;
            else
              context_index <= context_index + 1;
              state <= SELECT_K_POSITION;
            end if;
          else
            score_word_index <= score_word_index + 1;
          end if;

        when REQUEST_K_CACHE =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= CONSUME_K_CACHE;
          end if;

        when CONSUME_K_CACHE =>
          if input_accept = '1' then
            head_checksum <= head_checksum xor unsigned(input_data_i);
            element_base_v := segment_index * ATTN_VECTOR_TILE_ELEMENTS_C +
                              word_index * 2;
            pair_sum_v := resize(
              query_values(element_base_v) * signed(input_data_i(15 downto 0)), 33);
            if element_base_v + 1 < head_dim_count then
              pair_sum_v := pair_sum_v + resize(
                query_values(element_base_v + 1) * signed(input_data_i(31 downto 16)), 33);
            end if;
            next_score_v := score_accumulator + resize(pair_sum_v, 40);
            score_accumulator <= next_score_v;
            if word_index = tile_words - 1 then
              word_index <= 0;
              if segment_index = segment_count - 1 then
                segment_index <= 0;
                scaled_wide_v := next_score_v * inv_sqrt_q16(head_dim_count);
                scaled_score_v := resize(shift_right(scaled_wide_v, 16), 40);
                scores(context_index) <= scaled_score_v;
                score_checksum <= score_checksum xor fold_score(scaled_score_v);
                score_accumulator <= (others => '0');
                if context_index = context_count - 1 then
                  context_index <= 0;
                  state <= NORMALIZE;
                else
                  context_index <= context_index + 1;
                  state <= SELECT_K_POSITION;
                end if;
              else
                segment_index <= segment_index + 1;
                state <= REQUEST_K_CACHE;
              end if;
            else
              word_index <= word_index + 1;
            end if;
          end if;

        when NORMALIZE =>
          context_index <= 0;
          segment_index <= 0;
          state <= SELECT_V_POSITION;

        when SELECT_V_POSITION =>
          if context_index = append_position then
            if context_index = context_count - 1 then
              context_index <= 0;
              state <= REQUEST_OUTPUT;
            else
              context_index <= context_index + 1;
            end if;
          else
            segment_index <= 0;
            state <= REQUEST_V_CACHE;
          end if;

        when REQUEST_V_CACHE =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= CONSUME_V_CACHE;
          end if;

        when CONSUME_V_CACHE =>
          if input_accept = '1' then
            head_checksum <= head_checksum xor unsigned(input_data_i);
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
            end if;
          end if;

        when REQUEST_OUTPUT =>
          if transaction_ready_i = '1' then
            word_index <= 0;
            state <= PRODUCE_OUTPUT;
          end if;

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
            end if;
          end if;
      end case;
    end if;
  end process control;

end rtl;

-- Descriptor-driven tile mover for the Gowin PSRAM controller user interface.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity memory_streamer is
  port (
    clk_i, rstn_i, command_start_i : in std_ulogic;
    head_dim_i, context_length_i, append_position_i : in std_ulogic_vector(15 downto 0);

    transaction_valid_i, transaction_direction_i : in std_ulogic;
    transaction_ready_o : out std_ulogic;
    transaction_role_i : in tile_role_t;
    transaction_tile_i, transaction_length_i : in std_ulogic_vector(15 downto 0);

    engine_input_valid_o : out std_ulogic;
    engine_input_ready_i : in std_ulogic;
    engine_input_data_o : out std_ulogic_vector(31 downto 0);
    engine_output_valid_i : in std_ulogic;
    engine_output_ready_o : out std_ulogic;
    engine_output_data_i : in std_ulogic_vector(31 downto 0);

    descriptor_role_o : out tile_role_t;
    descriptor_length_i, descriptor_base_i, descriptor_stride_i : in std_ulogic_vector(31 downto 0);
    descriptor_valid_i : in std_ulogic;

    memory_init_done_i : in std_ulogic;
    memory_cmd_valid_o, memory_cmd_write_o : out std_ulogic;
    memory_cmd_address_o : out std_ulogic_vector(13 downto 0);
    memory_cmd_ready_i : in std_ulogic;
    memory_write_data_o : out std_ulogic_vector(63 downto 0);
    memory_write_valid_o : out std_ulogic;
    memory_write_done_i : in std_ulogic;
    memory_read_data_i : in std_ulogic_vector(63 downto 0);
    memory_read_valid_i, memory_error_i : in std_ulogic;

    input_wait_o, output_wait_o : out std_ulogic;
    input_bytes_o, output_bytes_o : out std_ulogic_vector(31 downto 0);
    idle_o, error_o : out std_ulogic
  );
end memory_streamer;

architecture rtl of memory_streamer is
  -- A DQ16 32-byte burst yields four 64-bit beats, or eight local words.
  constant BURST_WORDS_C : natural := 8;
  constant BURST_BEATS_C : natural := 4;
  type state_t is (
    IDLE, READ_COMMAND, READ_DATA, READ_DRAIN,
    WRITE_COLLECT, WRITE_COMMAND, WRITE_DATA, WRITE_COMPLETE, FAILED
  );
  type tile_buffer_t is array (0 to ATTN_VECTOR_TILE_WORDS_C - 1) of
    std_ulogic_vector(31 downto 0);
  signal state : state_t;
  signal tile_buffer : tile_buffer_t;
  signal base_word_reg, stride_word_reg, tile_reg : unsigned(31 downto 0);
  signal length_reg, word_index : unsigned(15 downto 0);
  signal burst_index : natural range 0 to 1;
  signal beat_index : natural range 0 to BURST_BEATS_C - 1;
  signal lookup_role : tile_role_t;
  signal mapped_tile, burst_address : unsigned(31 downto 0);
  signal write_word_index : natural range 0 to ATTN_VECTOR_TILE_WORDS_C - 2;
begin
  descriptor_mapping : process(all)
    variable segments_v, tile_v, kv_head_v, segment_v : natural;
  begin
    lookup_role <= transaction_role_i;
    mapped_tile <= resize(unsigned(transaction_tile_i), 32);
    tile_v := 0;
    kv_head_v := 0;
    segment_v := 0;
    segments_v := (to_integer(unsigned(head_dim_i)) + ATTN_VECTOR_TILE_ELEMENTS_C - 1) /
                  ATTN_VECTOR_TILE_ELEMENTS_C;
    if (transaction_direction_i = TILE_DIRECTION_OUTPUT_C) and
       ((transaction_role_i = ROLE_CURRENT_K_C) or
        (transaction_role_i = ROLE_CURRENT_V_C)) and (segments_v > 0) then
      if transaction_role_i = ROLE_CURRENT_K_C then
        lookup_role <= ROLE_K_CACHE_C;
      else
        lookup_role <= ROLE_V_CACHE_C;
      end if;
      tile_v := to_integer(unsigned(transaction_tile_i));
      kv_head_v := tile_v / segments_v;
      segment_v := tile_v mod segments_v;
      mapped_tile <= to_unsigned(
        (kv_head_v * to_integer(unsigned(context_length_i)) +
         to_integer(unsigned(append_position_i))) * segments_v + segment_v, 32);
    end if;
  end process descriptor_mapping;
  descriptor_role_o <= lookup_role;

  burst_address <= base_word_reg + resize(tile_reg * stride_word_reg, 32) +
                   to_unsigned(burst_index * BURST_WORDS_C, 32);
  memory_cmd_address_o <= std_ulogic_vector(burst_address(13 downto 0));
  memory_cmd_valid_o <= '1' when state = READ_COMMAND or state = WRITE_COMMAND else '0';
  memory_cmd_write_o <= '1' when state = WRITE_COMMAND else '0';
  write_word_index <= burst_index * BURST_WORDS_C + beat_index * 2;
  memory_write_data_o <= tile_buffer(write_word_index + 1) & tile_buffer(write_word_index);
  memory_write_valid_o <= '1' when state = WRITE_COMMAND or state = WRITE_DATA else '0';

  engine_input_valid_o <= '1' when state = READ_DRAIN else '0';
  engine_input_data_o <= tile_buffer(to_integer(word_index));
  engine_output_ready_o <= '1' when state = WRITE_COLLECT else '0';
  transaction_ready_o <= '1' when state = IDLE and memory_init_done_i = '1' else '0';
  idle_o <= '1' when state = IDLE else '0';
  error_o <= '1' when state = FAILED else '0';

  input_wait_o <= '1' when state = READ_COMMAND or state = READ_DATA or
                            (state = READ_DRAIN and engine_input_ready_i = '0') else '0';
  output_wait_o <= '1' when (state = WRITE_COLLECT and engine_output_valid_i = '0') or
                             state = WRITE_COMMAND or state = WRITE_DATA or
                             state = WRITE_COMPLETE else '0';
  input_bytes_o <= x"00000004" when state = READ_DRAIN and engine_input_ready_i = '1'
                   else (others => '0');
  output_bytes_o <= x"00000004" when state = WRITE_COLLECT and engine_output_valid_i = '1'
                    else (others => '0');

  transfer : process(rstn_i, clk_i)
    variable last_word_v : unsigned(31 downto 0);
    variable store_word_v : natural;
  begin
    if rstn_i = '0' then
      state <= IDLE;
      base_word_reg <= (others => '0');
      stride_word_reg <= (others => '0');
      tile_reg <= (others => '0');
      length_reg <= (others => '0');
      word_index <= (others => '0');
      burst_index <= 0;
      beat_index <= 0;
      tile_buffer <= (others => (others => '0'));
    elsif rising_edge(clk_i) then
      if command_start_i = '1' then
        state <= IDLE;
      else
        case state is
          when IDLE =>
            if transaction_valid_i = '1' and memory_init_done_i = '1' then
              last_word_v := shift_right(unsigned(descriptor_base_i), 2) +
                resize(mapped_tile * shift_right(unsigned(descriptor_stride_i), 2), 32) +
                resize(unsigned(transaction_length_i), 32) - 1;
              if descriptor_valid_i = '0' or unsigned(transaction_length_i) = 0 or
                 unsigned(transaction_length_i) > ATTN_VECTOR_TILE_WORDS_C or
                 (to_integer(unsigned(transaction_length_i)) mod BURST_WORDS_C) /= 0 or
                 mapped_tile >= unsigned(descriptor_length_i) or
                 last_word_v >= MEM_WINDOW_WORDS_C then
                state <= FAILED;
              else
                base_word_reg <= shift_right(unsigned(descriptor_base_i), 2);
                stride_word_reg <= shift_right(unsigned(descriptor_stride_i), 2);
                tile_reg <= mapped_tile;
                length_reg <= unsigned(transaction_length_i);
                word_index <= (others => '0');
                burst_index <= 0;
                beat_index <= 0;
                if transaction_direction_i = TILE_DIRECTION_INPUT_C then
                  state <= READ_COMMAND;
                else
                  state <= WRITE_COLLECT;
                end if;
              end if;
            end if;

          when READ_COMMAND =>
            if memory_error_i = '1' then
              state <= FAILED;
            elsif memory_cmd_ready_i = '1' then
              beat_index <= 0;
              state <= READ_DATA;
            end if;

          when READ_DATA =>
            if memory_error_i = '1' then
              state <= FAILED;
            elsif memory_read_valid_i = '1' then
              store_word_v := burst_index * BURST_WORDS_C + beat_index * 2;
              tile_buffer(store_word_v) <= memory_read_data_i(31 downto 0);
              tile_buffer(store_word_v + 1) <= memory_read_data_i(63 downto 32);
              if beat_index + 1 = BURST_BEATS_C then
                if (burst_index + 1) * BURST_WORDS_C >= to_integer(length_reg) then
                  word_index <= (others => '0');
                  state <= READ_DRAIN;
                else
                  burst_index <= burst_index + 1;
                  beat_index <= 0;
                  state <= READ_COMMAND;
                end if;
              else
                beat_index <= beat_index + 1;
              end if;
            end if;

          when READ_DRAIN =>
            if engine_input_ready_i = '1' then
              if word_index + 1 = length_reg then
                state <= IDLE;
              else
                word_index <= word_index + 1;
              end if;
            end if;

          when WRITE_COLLECT =>
            if engine_output_valid_i = '1' then
              tile_buffer(to_integer(word_index)) <= engine_output_data_i;
              if word_index + 1 = length_reg then
                burst_index <= 0;
                beat_index <= 0;
                state <= WRITE_COMMAND;
              else
                word_index <= word_index + 1;
              end if;
            end if;

          when WRITE_COMMAND =>
            if memory_error_i = '1' then
              state <= FAILED;
            elsif memory_cmd_ready_i = '1' then
              beat_index <= 1;
              state <= WRITE_DATA;
            end if;

          when WRITE_DATA =>
            if memory_error_i = '1' then
              state <= FAILED;
            elsif beat_index + 1 = BURST_BEATS_C then
              state <= WRITE_COMPLETE;
            else
              beat_index <= beat_index + 1;
            end if;

          when WRITE_COMPLETE =>
            if memory_error_i = '1' then
              state <= FAILED;
            elsif memory_write_done_i = '1' then
              if (burst_index + 1) * BURST_WORDS_C >= to_integer(length_reg) then
                state <= IDLE;
              else
                burst_index <= burst_index + 1;
                beat_index <= 0;
                state <= WRITE_COMMAND;
              end if;
            end if;

          when FAILED => null;
        end case;
      end if;
    end if;
  end process transfer;
end rtl;

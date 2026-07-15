-- Descriptor-driven tile mover for the MEM_STREAM frontend.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity memory_streamer is
  generic (BURST_SETUP_CYCLES : natural := 4);
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

    memory_write_o : out std_ulogic;
    memory_address_o : out std_ulogic_vector(13 downto 0);
    memory_write_data_o : out std_ulogic_vector(31 downto 0);
    memory_read_data_i : in std_ulogic_vector(31 downto 0);
    memory_ready_i, memory_error_i : in std_ulogic;

    input_wait_o, output_wait_o : out std_ulogic;
    input_bytes_o, output_bytes_o : out std_ulogic_vector(31 downto 0);
    idle_o, error_o : out std_ulogic
  );
end memory_streamer;

architecture rtl of memory_streamer is
  type state_t is (IDLE, SETUP, READ_TILE, WRITE_TILE, FAILED);
  signal state : state_t;
  signal direction_reg : std_ulogic;
  signal base_word_reg, stride_word_reg, tile_reg : unsigned(31 downto 0);
  signal length_reg, word_index : unsigned(15 downto 0);
  signal setup_remaining : natural range 0 to BURST_SETUP_CYCLES;
  signal lookup_role : tile_role_t;
  signal mapped_tile : unsigned(31 downto 0);
  signal current_address : unsigned(31 downto 0);
begin
  descriptor_mapping : process(all)
    variable segments_v, tile_v, kv_head_v, segment_v : natural;
  begin
    lookup_role <= transaction_role_i;
    mapped_tile <= resize(unsigned(transaction_tile_i), 32);
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

  current_address <= base_word_reg + resize(tile_reg * stride_word_reg, 32) +
                     resize(word_index, 32);
  memory_address_o <= std_ulogic_vector(current_address(13 downto 0));
  memory_write_data_o <= engine_output_data_i;
  memory_write_o <= '1' when state = WRITE_TILE and engine_output_valid_i = '1' and
                             memory_ready_i = '1' else '0';
  engine_input_valid_o <= '1' when state = READ_TILE and memory_ready_i = '1' else '0';
  engine_input_data_o <= memory_read_data_i;
  engine_output_ready_o <= '1' when state = WRITE_TILE and memory_ready_i = '1' else '0';
  transaction_ready_o <= '1' when state = IDLE else '0';
  idle_o <= '1' when state = IDLE else '0';
  error_o <= '1' when state = FAILED else '0';
  input_wait_o <= '1' when (state = SETUP and direction_reg = TILE_DIRECTION_INPUT_C) or
                            (state = READ_TILE and
                             (memory_ready_i = '0' or engine_input_ready_i = '0')) else '0';
  output_wait_o <= '1' when (state = SETUP and direction_reg = TILE_DIRECTION_OUTPUT_C) or
                             (state = WRITE_TILE and
                              (memory_ready_i = '0' or engine_output_valid_i = '0')) else '0';
  input_bytes_o <= x"00000004" when state = READ_TILE and memory_ready_i = '1' and
                                      engine_input_ready_i = '1' else (others => '0');
  output_bytes_o <= x"00000004" when state = WRITE_TILE and memory_ready_i = '1' and
                                       engine_output_valid_i = '1' else (others => '0');

  transfer : process(rstn_i, clk_i)
    variable last_word_v : unsigned(31 downto 0);
  begin
    if rstn_i = '0' then
      state <= IDLE;
      direction_reg <= TILE_DIRECTION_INPUT_C;
      base_word_reg <= (others => '0');
      stride_word_reg <= (others => '0');
      tile_reg <= (others => '0');
      length_reg <= (others => '0');
      word_index <= (others => '0');
      setup_remaining <= 0;
    elsif rising_edge(clk_i) then
      if command_start_i = '1' then
        state <= IDLE;
      else
        case state is
          when IDLE =>
            if transaction_valid_i = '1' then
              last_word_v := shift_right(unsigned(descriptor_base_i), 2) +
                resize(mapped_tile * shift_right(unsigned(descriptor_stride_i), 2), 32) +
                resize(unsigned(transaction_length_i), 32) - 1;
              if descriptor_valid_i = '0' or unsigned(transaction_length_i) = 0 or
                 unsigned(transaction_length_i) > ATTN_VECTOR_TILE_WORDS_C or
                 mapped_tile >= unsigned(descriptor_length_i) or
                 last_word_v >= MEM_WINDOW_WORDS_C then
                state <= FAILED;
              else
                direction_reg <= transaction_direction_i;
                base_word_reg <= shift_right(unsigned(descriptor_base_i), 2);
                stride_word_reg <= shift_right(unsigned(descriptor_stride_i), 2);
                tile_reg <= mapped_tile;
                length_reg <= unsigned(transaction_length_i);
                word_index <= (others => '0');
                setup_remaining <= BURST_SETUP_CYCLES;
                state <= SETUP;
              end if;
            end if;
          when SETUP =>
            if setup_remaining > 1 then
              setup_remaining <= setup_remaining - 1;
            elsif direction_reg = TILE_DIRECTION_INPUT_C then
              state <= READ_TILE;
            else
              state <= WRITE_TILE;
            end if;
          when READ_TILE =>
            if memory_error_i = '1' then
              state <= FAILED;
            elsif memory_ready_i = '1' and engine_input_ready_i = '1' then
              if word_index + 1 = length_reg then state <= IDLE;
              else word_index <= word_index + 1; end if;
            end if;
          when WRITE_TILE =>
            if memory_error_i = '1' then
              state <= FAILED;
            elsif memory_ready_i = '1' and engine_output_valid_i = '1' then
              if word_index + 1 = length_reg then state <= IDLE;
              else word_index <= word_index + 1; end if;
            end if;
          when FAILED => null;
        end case;
      end if;
    end if;
  end process transfer;
end rtl;

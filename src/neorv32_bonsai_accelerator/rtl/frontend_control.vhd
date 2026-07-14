-- Assigns engine tile transactions to input/output local buffer banks.

library ieee;
use ieee.std_logic_1164.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity frontend_control is
  generic (
    TILE_WORD_CAPACITY : positive := 4
  );
  port (
    clk_i  : in std_ulogic;
    rstn_i : in std_ulogic;
    command_start_i : in std_ulogic;

    engine_transaction_valid_i     : in std_ulogic;
    engine_transaction_ready_o     : out std_ulogic;
    engine_transaction_direction_i : in std_ulogic;
    engine_transaction_role_i      : in tile_role_t;
    engine_transaction_tile_i      : in std_ulogic_vector(15 downto 0);
    engine_transaction_length_i    : in std_ulogic_vector(15 downto 0);

    engine_input_valid_o : out std_ulogic;
    engine_input_ready_i : in std_ulogic;
    engine_input_data_o  : out std_ulogic_vector(31 downto 0);
    engine_output_valid_i : in std_ulogic;
    engine_output_ready_o : out std_ulogic;
    engine_output_data_i  : in std_ulogic_vector(31 downto 0);

    stream_transaction_valid_o     : out std_ulogic;
    stream_transaction_ready_i     : in std_ulogic;
    stream_transaction_direction_o : out std_ulogic;
    stream_transaction_role_o      : out tile_role_t;
    stream_transaction_tile_o      : out std_ulogic_vector(15 downto 0);
    stream_transaction_length_o    : out std_ulogic_vector(15 downto 0);

    stream_input_valid_i : in std_ulogic;
    stream_input_ready_o : out std_ulogic;
    stream_input_data_i  : in std_ulogic_vector(31 downto 0);
    stream_output_valid_o : out std_ulogic;
    stream_output_ready_i : in std_ulogic;
    stream_output_data_o  : out std_ulogic_vector(31 downto 0);

    stream_idle_i  : in std_ulogic;
    stream_error_i : in std_ulogic;
    idle_o  : out std_ulogic;
    error_o : out std_ulogic
  );
end frontend_control;

architecture rtl of frontend_control is

  signal input_bank_allocate, output_bank_allocate : std_ulogic;
  signal input_bank_empty, output_bank_empty : std_ulogic;
  signal input_bank_error, output_bank_error : std_ulogic;
  signal selected_bank_empty : std_ulogic;

begin

  selected_bank_empty <= input_bank_empty
    when engine_transaction_direction_i = TILE_DIRECTION_INPUT_C else output_bank_empty;

  engine_transaction_ready_o <= stream_transaction_ready_i and selected_bank_empty;
  stream_transaction_valid_o <= engine_transaction_valid_i and selected_bank_empty;
  stream_transaction_direction_o <= engine_transaction_direction_i;
  stream_transaction_role_o      <= engine_transaction_role_i;
  stream_transaction_tile_o      <= engine_transaction_tile_i;
  stream_transaction_length_o    <= engine_transaction_length_i;

  input_bank_allocate <= engine_transaction_valid_i and engine_transaction_ready_o
    when engine_transaction_direction_i = TILE_DIRECTION_INPUT_C else '0';
  output_bank_allocate <= engine_transaction_valid_i and engine_transaction_ready_o
    when engine_transaction_direction_i = TILE_DIRECTION_OUTPUT_C else '0';

  idle_o  <= stream_idle_i and input_bank_empty and output_bank_empty;
  error_o <= stream_error_i or input_bank_error or output_bank_error;

  input_bank_inst : entity neorv32.local_buffer_bank
    generic map (
      WORD_CAPACITY => TILE_WORD_CAPACITY
    )
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      command_start_i => command_start_i,
      allocate_i => input_bank_allocate,
      role_i => engine_transaction_role_i,
      tile_i => engine_transaction_tile_i,
      length_i => engine_transaction_length_i,
      producer_valid_i => stream_input_valid_i,
      producer_ready_o => stream_input_ready_o,
      producer_data_i => stream_input_data_i,
      consumer_valid_o => engine_input_valid_o,
      consumer_ready_i => engine_input_ready_i,
      consumer_data_o => engine_input_data_o,
      empty_o => input_bank_empty,
      ready_o => open,
      role_o => open,
      tile_o => open,
      length_o => open,
      error_o => input_bank_error
    );

  output_bank_inst : entity neorv32.local_buffer_bank
    generic map (
      WORD_CAPACITY => TILE_WORD_CAPACITY
    )
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      command_start_i => command_start_i,
      allocate_i => output_bank_allocate,
      role_i => engine_transaction_role_i,
      tile_i => engine_transaction_tile_i,
      length_i => engine_transaction_length_i,
      producer_valid_i => engine_output_valid_i,
      producer_ready_o => engine_output_ready_o,
      producer_data_i => engine_output_data_i,
      consumer_valid_o => stream_output_valid_o,
      consumer_ready_i => stream_output_ready_i,
      consumer_data_o => stream_output_data_o,
      empty_o => output_bank_empty,
      ready_o => open,
      role_o => open,
      tile_o => open,
      length_o => open,
      error_o => output_bank_error
    );

end rtl;

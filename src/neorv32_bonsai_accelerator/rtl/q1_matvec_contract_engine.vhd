-- Proposal A transport probe. Arithmetic is added by the following increment.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity q1_matvec_contract_engine is
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
end q1_matvec_contract_engine;

architecture rtl of q1_matvec_contract_engine is
  constant FIXTURE_CHECKSUM_C : std_ulogic_vector(31 downto 0) := x"CAE94A4B";
  constant FIXTURE_RESULT_C   : std_ulogic_vector(31 downto 0) := x"00000040";
  type state_t is (
    IDLE, REQUEST_Q8, CONSUME_Q8, REQUEST_Q1, CONSUME_Q1,
    REQUEST_OUTPUT, PRODUCE_OUTPUT, ERROR_STATE
  );
  signal state : state_t;
  signal q8_index : natural range 0 to Q8_BLOCKS_PER_Q1_C - 1;
  signal word_index : natural range 0 to Q8_BLOCK_WORDS_C - 1;
  signal checksum : std_ulogic_vector(31 downto 0);
  signal input_accept, output_accept : std_ulogic;
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
  output_data_o <= FIXTURE_RESULT_C;
  output_accept <= output_valid_o and output_ready_i;

  busy_o  <= '0' when (state = IDLE) or (state = ERROR_STATE) else '1';
  done_o  <= '1' when (state = PRODUCE_OUTPUT) and (output_accept = '1') else '0';
  error_o <= '1' when state = ERROR_STATE else '0';
  active_o <= input_accept or output_accept;
  input_wait_o <= '1' when
    ((state = CONSUME_Q8) or (state = CONSUME_Q1)) and input_valid_i = '0' else '0';
  output_wait_o <= '1' when state = PRODUCE_OUTPUT and output_ready_i = '0' else '0';
  work_o <= (others => '0');

  control : process(rstn_i, clk_i)
    variable next_checksum_v : std_ulogic_vector(31 downto 0);
  begin
    if rstn_i = '0' then
      state      <= IDLE;
      q8_index   <= 0;
      word_index <= 0;
      checksum   <= (others => '0');
    elsif rising_edge(clk_i) then
      case state is
        when IDLE | ERROR_STATE =>
          if launch_i = '1' then
            q8_index   <= 0;
            word_index <= 0;
            checksum   <= (others => '0');
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
            checksum <= (checksum(30 downto 0) & checksum(31)) xor input_data_i;
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
            next_checksum_v := (checksum(30 downto 0) & checksum(31)) xor input_data_i;
            checksum <= next_checksum_v;
            if word_index = Q1_GROUP_WORDS_C - 1 then
              word_index <= 0;
              if next_checksum_v = FIXTURE_CHECKSUM_C then
                state <= REQUEST_OUTPUT;
              else
                state <= ERROR_STATE;
              end if;
            else
              word_index <= word_index + 1;
            end if;
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

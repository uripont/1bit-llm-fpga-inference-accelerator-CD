-- CPU_PUSH ingress and egress channels with independent MMIO-facing FIFOs.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity stream_frontend is
  generic (
    FIFO_DEPTH : positive := 4
  );
  port (
    clk_i  : in std_ulogic;
    rstn_i : in std_ulogic;
    command_start_i : in std_ulogic;

    transaction_valid_i     : in std_ulogic;
    transaction_ready_o     : out std_ulogic;
    transaction_direction_i : in std_ulogic;
    transaction_role_i      : in tile_role_t;
    transaction_tile_i      : in std_ulogic_vector(15 downto 0);
    transaction_length_i    : in std_ulogic_vector(15 downto 0);

    engine_input_valid_o : out std_ulogic;
    engine_input_ready_i : in std_ulogic;
    engine_input_data_o  : out std_ulogic_vector(31 downto 0);
    engine_output_valid_i : in std_ulogic;
    engine_output_ready_o : out std_ulogic;
    engine_output_data_i  : in std_ulogic_vector(31 downto 0);

    cpu_input_write_i : in std_ulogic;
    cpu_input_data_i  : in std_ulogic_vector(31 downto 0);
    cpu_input_ready_o : out std_ulogic;
    cpu_output_read_i : in std_ulogic;
    cpu_output_data_o : out std_ulogic_vector(31 downto 0);
    cpu_output_valid_o : out std_ulogic;

    input_request_valid_o     : out std_ulogic;
    input_request_role_o      : out tile_role_t;
    input_request_tile_o      : out std_ulogic_vector(15 downto 0);
    input_request_remaining_o : out std_ulogic_vector(15 downto 0);
    output_request_valid_o     : out std_ulogic;
    output_request_role_o      : out tile_role_t;
    output_request_tile_o      : out std_ulogic_vector(15 downto 0);
    output_request_remaining_o : out std_ulogic_vector(15 downto 0);
    input_fifo_level_o         : out std_ulogic_vector(7 downto 0);
    output_fifo_level_o        : out std_ulogic_vector(7 downto 0);

    input_wait_o  : out std_ulogic;
    output_wait_o : out std_ulogic;
    input_bytes_o  : out std_ulogic_vector(31 downto 0);
    output_bytes_o : out std_ulogic_vector(31 downto 0);
    idle_o  : out std_ulogic;
    error_o : out std_ulogic
  );
end stream_frontend;

architecture rtl of stream_frontend is

  type fifo_memory_t is array (natural range <>) of std_ulogic_vector(31 downto 0);
  signal input_fifo  : fifo_memory_t(0 to FIFO_DEPTH - 1);
  signal output_fifo : fifo_memory_t(0 to FIFO_DEPTH - 1);

  signal input_active, output_active : std_ulogic;
  signal input_role, output_role : tile_role_t;
  signal input_tile, output_tile : std_ulogic_vector(15 downto 0);
  signal input_length, output_length : natural range 0 to 65535;
  signal input_written, input_consumed : natural range 0 to 65535;
  signal output_produced, output_read : natural range 0 to 65535;
  signal input_write_pointer, input_read_pointer : natural range 0 to FIFO_DEPTH - 1;
  signal output_write_pointer, output_read_pointer : natural range 0 to FIFO_DEPTH - 1;
  signal input_occupancy, output_occupancy : natural range 0 to FIFO_DEPTH;

  signal input_write_accept, input_read_accept : std_ulogic;
  signal output_write_accept, output_read_accept : std_ulogic;
  signal ingress_error, egress_error : std_ulogic;

begin

  assert FIFO_DEPTH <= 255
    report "stream_frontend FIFO_DEPTH exceeds the 8-bit level register"
    severity failure;

  transaction_ready_o <= '1' when
    ((transaction_direction_i = TILE_DIRECTION_INPUT_C) and (input_active = '0')) or
    ((transaction_direction_i = TILE_DIRECTION_OUTPUT_C) and (output_active = '0'))
    else '0';

  cpu_input_ready_o <= '1' when
    (input_active = '1') and (input_written < input_length) and
    (input_occupancy < FIFO_DEPTH)
    else '0';
  input_write_accept <= cpu_input_write_i and cpu_input_ready_o;

  engine_input_valid_o <= '1' when (input_active = '1') and (input_occupancy > 0) else '0';
  engine_input_data_o <= input_fifo(input_read_pointer);
  input_read_accept <= engine_input_valid_o and engine_input_ready_i;

  engine_output_ready_o <= '1' when
    (output_active = '1') and (output_produced < output_length) and
    (output_occupancy < FIFO_DEPTH)
    else '0';
  output_write_accept <= engine_output_valid_i and engine_output_ready_o;

  cpu_output_valid_o <= '1' when (output_active = '1') and (output_occupancy > 0) else '0';
  cpu_output_data_o <= output_fifo(output_read_pointer);
  output_read_accept <= cpu_output_read_i and cpu_output_valid_o;

  input_request_valid_o <= '1' when
    (input_active = '1') and (input_written < input_length) else '0';
  input_request_role_o <= input_role;
  input_request_tile_o <= input_tile;
  input_request_remaining_o <= std_ulogic_vector(to_unsigned(input_length - input_written, 16))
    when input_active = '1' else (others => '0');

  output_request_valid_o <= '1' when
    (output_active = '1') and (output_read < output_length) else '0';
  output_request_role_o <= output_role;
  output_request_tile_o <= output_tile;
  output_request_remaining_o <= std_ulogic_vector(to_unsigned(output_length - output_read, 16))
    when output_active = '1' else (others => '0');

  input_fifo_level_o  <= std_ulogic_vector(to_unsigned(input_occupancy, 8));
  output_fifo_level_o <= std_ulogic_vector(to_unsigned(output_occupancy, 8));

  input_wait_o <= input_request_valid_o and not input_write_accept;
  output_wait_o <= output_request_valid_o and cpu_output_valid_o and not output_read_accept;
  input_bytes_o  <= x"00000004" when input_write_accept = '1' else x"00000000";
  output_bytes_o <= x"00000004" when output_read_accept = '1' else x"00000000";
  idle_o <= not input_active and not output_active;
  error_o <= ingress_error or egress_error;

  ingress : process(rstn_i, clk_i)
    variable next_written, next_consumed : natural range 0 to 65535;
  begin
    if rstn_i = '0' then
      input_active       <= '0';
      input_role         <= ROLE_NONE_C;
      input_tile         <= (others => '0');
      input_length       <= 0;
      input_written      <= 0;
      input_consumed     <= 0;
      input_write_pointer <= 0;
      input_read_pointer  <= 0;
      input_occupancy    <= 0;
      ingress_error      <= '0';
    elsif rising_edge(clk_i) then
      ingress_error <= '0';

      if command_start_i = '1' then
        input_active       <= '0';
        input_role         <= ROLE_NONE_C;
        input_tile         <= (others => '0');
        input_length       <= 0;
        input_written      <= 0;
        input_consumed     <= 0;
        input_write_pointer <= 0;
        input_read_pointer  <= 0;
        input_occupancy    <= 0;
      elsif (transaction_valid_i = '1') and (transaction_ready_o = '1') and
            (transaction_direction_i = TILE_DIRECTION_INPUT_C) then
        if unsigned(transaction_length_i) = 0 then
          ingress_error <= '1';
        else
          input_active       <= '1';
          input_role         <= transaction_role_i;
          input_tile         <= transaction_tile_i;
          input_length       <= to_integer(unsigned(transaction_length_i));
          input_written      <= 0;
          input_consumed     <= 0;
          input_write_pointer <= 0;
          input_read_pointer  <= 0;
          input_occupancy    <= 0;
        end if;
      else
        next_written  := input_written;
        next_consumed := input_consumed;

        if input_write_accept = '1' then
          input_fifo(input_write_pointer) <= cpu_input_data_i;
          if input_write_pointer = FIFO_DEPTH - 1 then
            input_write_pointer <= 0;
          else
            input_write_pointer <= input_write_pointer + 1;
          end if;
          next_written := input_written + 1;
          input_written <= next_written;
        elsif cpu_input_write_i = '1' then
          ingress_error <= '1';
        end if;

        if input_read_accept = '1' then
          if input_read_pointer = FIFO_DEPTH - 1 then
            input_read_pointer <= 0;
          else
            input_read_pointer <= input_read_pointer + 1;
          end if;
          next_consumed := input_consumed + 1;
          input_consumed <= next_consumed;
        end if;

        if (input_write_accept = '1') and (input_read_accept = '0') then
          input_occupancy <= input_occupancy + 1;
        elsif (input_write_accept = '0') and (input_read_accept = '1') then
          input_occupancy <= input_occupancy - 1;
        end if;

        if (input_active = '1') and
           (next_written = input_length) and (next_consumed = input_length) then
          input_active <= '0';
          input_role   <= ROLE_NONE_C;
        end if;
      end if;
    end if;
  end process ingress;

  egress : process(rstn_i, clk_i)
    variable next_produced, next_read : natural range 0 to 65535;
  begin
    if rstn_i = '0' then
      output_active        <= '0';
      output_role          <= ROLE_NONE_C;
      output_tile          <= (others => '0');
      output_length        <= 0;
      output_produced      <= 0;
      output_read          <= 0;
      output_write_pointer <= 0;
      output_read_pointer  <= 0;
      output_occupancy     <= 0;
      egress_error         <= '0';
    elsif rising_edge(clk_i) then
      egress_error <= '0';

      if command_start_i = '1' then
        output_active        <= '0';
        output_role          <= ROLE_NONE_C;
        output_tile          <= (others => '0');
        output_length        <= 0;
        output_produced      <= 0;
        output_read          <= 0;
        output_write_pointer <= 0;
        output_read_pointer  <= 0;
        output_occupancy     <= 0;
      elsif (transaction_valid_i = '1') and (transaction_ready_o = '1') and
            (transaction_direction_i = TILE_DIRECTION_OUTPUT_C) then
        if unsigned(transaction_length_i) = 0 then
          egress_error <= '1';
        else
          output_active        <= '1';
          output_role          <= transaction_role_i;
          output_tile          <= transaction_tile_i;
          output_length        <= to_integer(unsigned(transaction_length_i));
          output_produced      <= 0;
          output_read          <= 0;
          output_write_pointer <= 0;
          output_read_pointer  <= 0;
          output_occupancy     <= 0;
        end if;
      else
        next_produced := output_produced;
        next_read     := output_read;

        if output_write_accept = '1' then
          output_fifo(output_write_pointer) <= engine_output_data_i;
          if output_write_pointer = FIFO_DEPTH - 1 then
            output_write_pointer <= 0;
          else
            output_write_pointer <= output_write_pointer + 1;
          end if;
          next_produced := output_produced + 1;
          output_produced <= next_produced;
        end if;

        if output_read_accept = '1' then
          if output_read_pointer = FIFO_DEPTH - 1 then
            output_read_pointer <= 0;
          else
            output_read_pointer <= output_read_pointer + 1;
          end if;
          next_read := output_read + 1;
          output_read <= next_read;
        elsif cpu_output_read_i = '1' then
          egress_error <= '1';
        end if;

        if (output_write_accept = '1') and (output_read_accept = '0') then
          output_occupancy <= output_occupancy + 1;
        elsif (output_write_accept = '0') and (output_read_accept = '1') then
          output_occupancy <= output_occupancy - 1;
        end if;

        if (output_active = '1') and
           (next_produced = output_length) and (next_read = output_length) then
          output_active <= '0';
          output_role   <= ROLE_NONE_C;
        end if;
      end if;
    end if;
  end process egress;

end rtl;


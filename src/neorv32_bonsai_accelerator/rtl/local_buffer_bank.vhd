-- One role-tagged local tile buffer with explicit producer/consumer ownership.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity local_buffer_bank is
  generic (
    WORD_CAPACITY : positive := 4
  );
  port (
    clk_i  : in std_ulogic;
    rstn_i : in std_ulogic;
    command_start_i : in std_ulogic;

    allocate_i  : in std_ulogic;
    role_i      : in tile_role_t;
    tile_i      : in std_ulogic_vector(15 downto 0);
    length_i    : in std_ulogic_vector(15 downto 0);

    producer_valid_i : in std_ulogic;
    producer_ready_o : out std_ulogic;
    producer_data_i  : in std_ulogic_vector(31 downto 0);
    consumer_valid_o : out std_ulogic;
    consumer_ready_i : in std_ulogic;
    consumer_data_o  : out std_ulogic_vector(31 downto 0);

    empty_o  : out std_ulogic;
    ready_o  : out std_ulogic;
    role_o   : out tile_role_t;
    tile_o   : out std_ulogic_vector(15 downto 0);
    length_o : out std_ulogic_vector(15 downto 0);
    error_o  : out std_ulogic
  );
end local_buffer_bank;

architecture rtl of local_buffer_bank is

  type state_t is (EMPTY, FILLING, READY, IN_USE);
  type memory_t is array (0 to WORD_CAPACITY - 1) of std_ulogic_vector(31 downto 0);

  signal state : state_t;
  signal memory : memory_t;
  signal role : tile_role_t;
  signal tile : std_ulogic_vector(15 downto 0);
  signal length : natural range 0 to WORD_CAPACITY;
  signal write_index, read_index : natural range 0 to WORD_CAPACITY - 1;
  signal producer_accept, consumer_accept : std_ulogic;
  signal error : std_ulogic;

begin

  empty_o <= '1' when state = EMPTY else '0';
  ready_o <= '1' when (state = READY) or (state = IN_USE) else '0';
  role_o  <= role;
  tile_o  <= tile;
  length_o <= std_ulogic_vector(to_unsigned(length, 16));
  error_o <= error;

  producer_ready_o <= '1' when state = FILLING else '0';
  producer_accept <= producer_valid_i and producer_ready_o;

  consumer_valid_o <= '1' when (state = READY) or (state = IN_USE) else '0';
  consumer_data_o <= memory(read_index);
  consumer_accept <= consumer_valid_o and consumer_ready_i;

  bank_control : process(rstn_i, clk_i)
    variable requested_length_v : natural range 0 to 65535;
  begin
    if rstn_i = '0' then
      state       <= EMPTY;
      role        <= ROLE_NONE_C;
      tile        <= (others => '0');
      length      <= 0;
      write_index <= 0;
      read_index  <= 0;
      error       <= '0';
    elsif rising_edge(clk_i) then
      error <= '0';

      if command_start_i = '1' then
        state       <= EMPTY;
        role        <= ROLE_NONE_C;
        tile        <= (others => '0');
        length      <= 0;
        write_index <= 0;
        read_index  <= 0;
      else
        case state is
          when EMPTY =>
            if allocate_i = '1' then
              requested_length_v := to_integer(unsigned(length_i));
              if (requested_length_v = 0) or (requested_length_v > WORD_CAPACITY) then
                error <= '1';
              else
                role        <= role_i;
                tile        <= tile_i;
                length      <= requested_length_v;
                write_index <= 0;
                read_index  <= 0;
                state       <= FILLING;
              end if;
            end if;

          when FILLING =>
            if allocate_i = '1' then
              error <= '1';
            end if;
            if producer_accept = '1' then
              memory(write_index) <= producer_data_i;
              if write_index = length - 1 then
                write_index <= 0;
                state       <= READY;
              else
                write_index <= write_index + 1;
              end if;
            end if;

          when READY =>
            if allocate_i = '1' then
              error <= '1';
            end if;
            if consumer_accept = '1' then
              if read_index = length - 1 then
                state      <= EMPTY;
                role       <= ROLE_NONE_C;
                read_index <= 0;
              else
                read_index <= read_index + 1;
                state      <= IN_USE;
              end if;
            end if;

          when IN_USE =>
            if allocate_i = '1' then
              error <= '1';
            end if;
            if consumer_accept = '1' then
              if read_index = length - 1 then
                state      <= EMPTY;
                role       <= ROLE_NONE_C;
                read_index <= 0;
              else
                read_index <= read_index + 1;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process bank_control;

end rtl;


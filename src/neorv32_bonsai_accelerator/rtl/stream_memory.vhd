-- Behavioral Gowin PSRAM HS controller model at its user-side interface.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity stream_memory is
  generic (
    INITIALIZATION_CYCLES : positive := 150;
    READ_LATENCY_CYCLES : positive := 6;
    COMMAND_INTERVAL_CYCLES : positive := 18
  );
  port (
    clk_i, rstn_i : in std_ulogic;

    cpu_write_i : in std_ulogic;
    cpu_address_i : in std_ulogic_vector(13 downto 0);
    cpu_write_data_i : in std_ulogic_vector(31 downto 0);
    cpu_read_data_o : out std_ulogic_vector(31 downto 0);

    init_done_o : out std_ulogic;
    cmd_valid_i, cmd_write_i : in std_ulogic;
    cmd_address_i : in std_ulogic_vector(13 downto 0);
    cmd_ready_o : out std_ulogic;
    write_data_i : in std_ulogic_vector(63 downto 0);
    write_valid_i : in std_ulogic;
    write_done_o : out std_ulogic;
    read_data_o : out std_ulogic_vector(63 downto 0);
    read_valid_o, error_o : out std_ulogic
  );
end stream_memory;

architecture controller_model of stream_memory is
  -- Tang Nano 9K DQ16 configuration: a 32-byte burst is four 64-bit user beats.
  constant USER_BEATS_PER_BURST_C : natural := 4;
  constant WORDS_PER_USER_BEAT_C : natural := 2;
  type memory_t is array (0 to MEM_WINDOW_WORDS_C - 1) of
    std_ulogic_vector(31 downto 0);
  type operation_t is (OP_IDLE, OP_READ_WAIT, OP_READ_TRANSFER, OP_WRITE_TRANSFER);
  signal memory : memory_t := (others => (others => '0'));
  signal operation : operation_t;
  signal init_count : natural range 0 to INITIALIZATION_CYCLES;
  signal init_done : std_ulogic;
  signal cooldown : natural range 0 to COMMAND_INTERVAL_CYCLES - 1;
  signal latency_count : natural range 0 to READ_LATENCY_CYCLES;
  signal beat_index : natural range 0 to USER_BEATS_PER_BURST_C - 1;
  signal address_reg : unsigned(13 downto 0);
  signal read_data_reg : std_ulogic_vector(63 downto 0);
  signal read_valid_reg, write_done_reg, error_reg : std_ulogic;
begin
  cpu_read_data_o <= memory(to_integer(unsigned(cpu_address_i)))
    when unsigned(cpu_address_i) < MEM_WINDOW_WORDS_C else (others => '0');
  init_done_o <= init_done;
  cmd_ready_o <= '1' when init_done = '1' and operation = OP_IDLE and cooldown = 0 else '0';
  read_data_o <= read_data_reg;
  read_valid_o <= read_valid_reg;
  write_done_o <= write_done_reg;
  error_o <= error_reg;

  controller : process(rstn_i, clk_i)
    variable word_v : natural;
  begin
    if rstn_i = '0' then
      operation <= OP_IDLE;
      init_count <= 0;
      init_done <= '0';
      cooldown <= 0;
      latency_count <= 0;
      beat_index <= 0;
      address_reg <= (others => '0');
      read_data_reg <= (others => '0');
      read_valid_reg <= '0';
      write_done_reg <= '0';
      error_reg <= '0';
    elsif rising_edge(clk_i) then
      read_valid_reg <= '0';
      write_done_reg <= '0';

      if init_done = '0' then
        if init_count + 1 = INITIALIZATION_CYCLES then
          init_done <= '1';
        else
          init_count <= init_count + 1;
        end if;
      end if;
      if cooldown > 0 then
        cooldown <= cooldown - 1;
      end if;

      if cpu_write_i = '1' and unsigned(cpu_address_i) < MEM_WINDOW_WORDS_C then
        memory(to_integer(unsigned(cpu_address_i))) <= cpu_write_data_i;
      end if;

      case operation is
        when OP_IDLE =>
          if cmd_valid_i = '1' and init_done = '1' and cooldown = 0 then
            word_v := to_integer(unsigned(cmd_address_i));
            if word_v + 7 >= MEM_WINDOW_WORDS_C then
              error_reg <= '1';
            else
              address_reg <= unsigned(cmd_address_i);
              beat_index <= 0;
              cooldown <= COMMAND_INTERVAL_CYCLES - 1;
              if cmd_write_i = '1' then
                if write_valid_i = '0' then
                  error_reg <= '1';
                else
                  memory(word_v) <= write_data_i(31 downto 0);
                  memory(word_v + 1) <= write_data_i(63 downto 32);
                  beat_index <= 1;
                  operation <= OP_WRITE_TRANSFER;
                end if;
              else
                latency_count <= READ_LATENCY_CYCLES;
                operation <= OP_READ_WAIT;
              end if;
            end if;
          end if;

        when OP_READ_WAIT =>
          if latency_count > 1 then
            latency_count <= latency_count - 1;
          else
            word_v := to_integer(address_reg);
            read_data_reg <= memory(word_v + 1) & memory(word_v);
            read_valid_reg <= '1';
            beat_index <= 1;
            operation <= OP_READ_TRANSFER;
          end if;

        when OP_READ_TRANSFER =>
          word_v := to_integer(address_reg) + beat_index * WORDS_PER_USER_BEAT_C;
          read_data_reg <= memory(word_v + 1) & memory(word_v);
          read_valid_reg <= '1';
          if beat_index + 1 = USER_BEATS_PER_BURST_C then
            operation <= OP_IDLE;
          else
            beat_index <= beat_index + 1;
          end if;

        when OP_WRITE_TRANSFER =>
          if write_valid_i = '0' then
            error_reg <= '1';
            operation <= OP_IDLE;
          else
            word_v := to_integer(address_reg) + beat_index * WORDS_PER_USER_BEAT_C;
            memory(word_v) <= write_data_i(31 downto 0);
            memory(word_v + 1) <= write_data_i(63 downto 32);
            if beat_index + 1 = USER_BEATS_PER_BURST_C then
              write_done_reg <= '1';
              operation <= OP_IDLE;
            else
              beat_index <= beat_index + 1;
            end if;
          end if;
      end case;
    end if;
  end process controller;
end controller_model;

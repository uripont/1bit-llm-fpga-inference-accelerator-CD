-- Common command lifecycle controller shared by both accelerator engines.

library ieee;
use ieee.std_logic_1164.all;

library neorv32;
use neorv32.bonsai_accel_pkg.all;

entity accel_top is
  port (
    clk_i  : in std_ulogic;
    rstn_i : in std_ulogic;

    start_i         : in std_ulogic;
    acknowledge_i   : in std_ulogic;
    service_i       : in service_t;
    transfer_mode_i : in transfer_mode_t;
    service_config_valid_i : in std_ulogic;

    engine_busy_i  : in std_ulogic;
    engine_done_i  : in std_ulogic;
    engine_error_i : in std_ulogic;
    engine_launch_o : out std_ulogic;
    frontend_idle_i  : in std_ulogic;
    frontend_error_i : in std_ulogic;

    busy_o              : out std_ulogic;
    done_o              : out std_ulogic;
    error_o             : out std_ulogic;
    selected_service_o  : out service_t;
    selected_transfer_o : out transfer_mode_t;
    error_code_o        : out error_code_t;

    command_start_o  : out std_ulogic;
    command_active_o : out std_ulogic;
    engine_interval_o : out std_ulogic
  );
end accel_top;

architecture rtl of accel_top is

  type state_t is (IDLE, PREPARE, RUN, DRAIN, DONE, ERROR);
  signal state : state_t;

  signal selected_service  : service_t;
  signal selected_transfer : transfer_mode_t;
  signal error_code        : error_code_t;
  signal command_valid     : std_ulogic;

begin

  command_valid <= '1' when
    ((selected_service = SERVICE_Q1_MATVEC_C) or
     (selected_service = SERVICE_ATTN_KV_C)) and
    (selected_transfer = TRANSFER_CPU_PUSH_C) and
    (service_config_valid_i = '1')
    else '0';

  engine_launch_o <= '1' when (state = PREPARE) and (command_valid = '1') else '0';

  busy_o  <= '1' when (state = PREPARE) or (state = RUN) or (state = DRAIN) else '0';
  done_o  <= '1' when state = DONE else '0';
  error_o <= '1' when state = ERROR else '0';

  command_start_o  <= '1' when (state = IDLE) and (start_i = '1') else '0';
  command_active_o <= busy_o;
  engine_interval_o <= '1' when state = RUN else '0';

  selected_service_o  <= selected_service;
  selected_transfer_o <= selected_transfer;
  error_code_o        <= error_code;

  control : process(rstn_i, clk_i)
  begin
    if rstn_i = '0' then
      state             <= IDLE;
      selected_service  <= SERVICE_NONE_C;
      selected_transfer <= TRANSFER_CPU_PUSH_C;
      error_code        <= ERROR_NONE_C;
    elsif rising_edge(clk_i) then
      case state is
        when IDLE =>
          if start_i = '1' then
            selected_service  <= service_i;
            selected_transfer <= transfer_mode_i;
            error_code        <= ERROR_NONE_C;
            state             <= PREPARE;
          end if;

        when PREPARE =>
          if (selected_service /= SERVICE_Q1_MATVEC_C) and
             (selected_service /= SERVICE_ATTN_KV_C) then
            error_code <= ERROR_BAD_COMMAND_C;
            state      <= ERROR;
          elsif selected_transfer /= TRANSFER_CPU_PUSH_C then
            error_code <= ERROR_UNSUPPORTED_MODE_C;
            state      <= ERROR;
          elsif service_config_valid_i = '0' then
            error_code <= ERROR_BAD_COMMAND_C;
            state      <= ERROR;
          else
            state <= RUN;
          end if;

        when RUN =>
          if frontend_error_i = '1' then
            error_code <= ERROR_FRONTEND_C;
            state      <= ERROR;
          elsif engine_error_i = '1' then
            error_code <= ERROR_ENGINE_C;
            state      <= ERROR;
          elsif engine_done_i = '1' then
            state <= DRAIN;
          end if;

        when DRAIN =>
          if frontend_error_i = '1' then
            error_code <= ERROR_FRONTEND_C;
            state      <= ERROR;
          elsif frontend_idle_i = '1' then
            state <= DONE;
          end if;

        when DONE =>
          if acknowledge_i = '1' then
            selected_service  <= SERVICE_NONE_C;
            selected_transfer <= TRANSFER_CPU_PUSH_C;
            state             <= IDLE;
          end if;

        when ERROR =>
          if acknowledge_i = '1' then
            selected_service  <= SERVICE_NONE_C;
            selected_transfer <= TRANSFER_CPU_PUSH_C;
            error_code        <= ERROR_NONE_C;
            state             <= IDLE;
          end if;
      end case;
    end if;
  end process control;

end rtl;

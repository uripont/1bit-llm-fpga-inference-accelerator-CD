-- Project-owned NEORV32 CFS implementation for the Bonsai accelerator.

library ieee;
use ieee.std_logic_1164.all;

library neorv32;
use neorv32.neorv32_package.all;
use neorv32.bonsai_accel_pkg.all;

entity neorv32_cfs is
  port (
    clk_i     : in  std_ulogic;
    rstn_i    : in  std_ulogic;
    bus_req_i : in  bus_req_t;
    bus_rsp_o : out bus_rsp_t;
    irq_o     : out std_ulogic;
    cfs_in_i  : in  std_ulogic_vector(255 downto 0);
    cfs_out_o : out std_ulogic_vector(255 downto 0)
  );
end neorv32_cfs;

architecture bonsai_accel_rtl of neorv32_cfs is

  signal command_start, command_acknowledge : std_ulogic;
  signal config_service : service_t;
  signal config_transfer : transfer_mode_t;

  signal status_busy, status_done, status_error : std_ulogic;
  signal selected_service : service_t;
  signal selected_transfer : transfer_mode_t;
  signal status_error_code : error_code_t;

  signal input_request_valid, output_request_valid : std_ulogic;
  signal input_request_role, output_request_role : tile_role_t;
  signal input_request_tile, output_request_tile : std_ulogic_vector(15 downto 0);
  signal input_request_remaining, output_request_remaining : std_ulogic_vector(15 downto 0);
  signal fifo_input_ready, fifo_output_valid : std_ulogic;
  signal fifo_input_level, fifo_output_level : std_ulogic_vector(7 downto 0);
  signal fifo_input_write, fifo_output_read : std_ulogic;
  signal fifo_input_data, fifo_output_data : std_ulogic_vector(31 downto 0);

  signal transaction_valid, transaction_ready, transaction_direction : std_ulogic;
  signal transaction_role : tile_role_t;
  signal transaction_tile, transaction_length : std_ulogic_vector(15 downto 0);
  signal engine_input_valid, engine_input_ready : std_ulogic;
  signal engine_output_valid, engine_output_ready : std_ulogic;
  signal engine_input_data, engine_output_data : std_ulogic_vector(31 downto 0);

  signal engine_launch, engine_busy, engine_done, engine_error : std_ulogic;
  signal engine_active, engine_input_wait, engine_output_wait : std_ulogic;
  signal engine_work : std_ulogic_vector(31 downto 0);
  signal command_counter_start, command_active, engine_interval, engine_control : std_ulogic;
  signal frontend_idle, frontend_error, frontend_input_wait, frontend_output_wait : std_ulogic;
  signal frontend_input_bytes, frontend_output_bytes : std_ulogic_vector(31 downto 0);

  signal counter_command, counter_engine, counter_active : std_ulogic_vector(31 downto 0);
  signal counter_input_wait, counter_output_wait, counter_control : std_ulogic_vector(31 downto 0);
  signal counter_frontend_in, counter_frontend_out : std_ulogic_vector(31 downto 0);
  signal counter_input_bytes, counter_output_bytes, counter_work : std_ulogic_vector(31 downto 0);

begin

  irq_o     <= '0';
  cfs_out_o <= (others => '0');

  engine_control <= engine_interval and not engine_active and
                    not engine_input_wait and not engine_output_wait;

  reg_file_inst : entity neorv32.cfs_reg_file
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      bus_req_i => bus_req_i,
      bus_rsp_o => bus_rsp_o,
      start_o => command_start,
      acknowledge_o => command_acknowledge,
      service_o => config_service,
      transfer_mode_o => config_transfer,
      busy_i => status_busy,
      done_i => status_done,
      error_i => status_error,
      selected_service_i => selected_service,
      selected_transfer_i => selected_transfer,
      error_code_i => status_error_code,
      input_request_valid_i => input_request_valid,
      input_request_role_i => input_request_role,
      input_request_tile_i => input_request_tile,
      input_request_remaining_i => input_request_remaining,
      output_request_valid_i => output_request_valid,
      output_request_role_i => output_request_role,
      output_request_tile_i => output_request_tile,
      output_request_remaining_i => output_request_remaining,
      fifo_input_ready_i => fifo_input_ready,
      fifo_output_valid_i => fifo_output_valid,
      fifo_input_level_i => fifo_input_level,
      fifo_output_level_i => fifo_output_level,
      fifo_output_data_i => fifo_output_data,
      fifo_input_write_o => fifo_input_write,
      fifo_input_data_o => fifo_input_data,
      fifo_output_read_o => fifo_output_read,
      counter_command_i => counter_command,
      counter_engine_i => counter_engine,
      counter_active_i => counter_active,
      counter_input_wait_i => counter_input_wait,
      counter_output_wait_i => counter_output_wait,
      counter_control_i => counter_control,
      counter_frontend_in_i => counter_frontend_in,
      counter_frontend_out_i => counter_frontend_out,
      counter_input_bytes_i => counter_input_bytes,
      counter_output_bytes_i => counter_output_bytes,
      counter_work_i => counter_work
    );

  top_inst : entity neorv32.accel_top
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      start_i => command_start,
      acknowledge_i => command_acknowledge,
      service_i => config_service,
      transfer_mode_i => config_transfer,
      engine_busy_i => engine_busy,
      engine_done_i => engine_done,
      engine_error_i => engine_error,
      engine_launch_o => engine_launch,
      frontend_idle_i => frontend_idle,
      frontend_error_i => frontend_error,
      busy_o => status_busy,
      done_o => status_done,
      error_o => status_error,
      selected_service_o => selected_service,
      selected_transfer_o => selected_transfer,
      error_code_o => status_error_code,
      command_start_o => command_counter_start,
      command_active_o => command_active,
      engine_interval_o => engine_interval
    );

  frontend_inst : entity neorv32.stream_frontend
    generic map (
      FIFO_DEPTH => 2
    )
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      command_start_i => command_counter_start,
      transaction_valid_i => transaction_valid,
      transaction_ready_o => transaction_ready,
      transaction_direction_i => transaction_direction,
      transaction_role_i => transaction_role,
      transaction_tile_i => transaction_tile,
      transaction_length_i => transaction_length,
      engine_input_valid_o => engine_input_valid,
      engine_input_ready_i => engine_input_ready,
      engine_input_data_o => engine_input_data,
      engine_output_valid_i => engine_output_valid,
      engine_output_ready_o => engine_output_ready,
      engine_output_data_i => engine_output_data,
      cpu_input_write_i => fifo_input_write,
      cpu_input_data_i => fifo_input_data,
      cpu_input_ready_o => fifo_input_ready,
      cpu_output_read_i => fifo_output_read,
      cpu_output_data_o => fifo_output_data,
      cpu_output_valid_o => fifo_output_valid,
      input_request_valid_o => input_request_valid,
      input_request_role_o => input_request_role,
      input_request_tile_o => input_request_tile,
      input_request_remaining_o => input_request_remaining,
      output_request_valid_o => output_request_valid,
      output_request_role_o => output_request_role,
      output_request_tile_o => output_request_tile,
      output_request_remaining_o => output_request_remaining,
      input_fifo_level_o => fifo_input_level,
      output_fifo_level_o => fifo_output_level,
      input_wait_o => frontend_input_wait,
      output_wait_o => frontend_output_wait,
      input_bytes_o => frontend_input_bytes,
      output_bytes_o => frontend_output_bytes,
      idle_o => frontend_idle,
      error_o => frontend_error
    );

  test_engine_inst : entity neorv32.shell_test_engine
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      launch_i => engine_launch,
      transaction_valid_o => transaction_valid,
      transaction_ready_i => transaction_ready,
      transaction_direction_o => transaction_direction,
      transaction_role_o => transaction_role,
      transaction_tile_o => transaction_tile,
      transaction_length_o => transaction_length,
      input_valid_i => engine_input_valid,
      input_ready_o => engine_input_ready,
      input_data_i => engine_input_data,
      output_valid_o => engine_output_valid,
      output_ready_i => engine_output_ready,
      output_data_o => engine_output_data,
      busy_o => engine_busy,
      done_o => engine_done,
      error_o => engine_error,
      active_o => engine_active,
      input_wait_o => engine_input_wait,
      output_wait_o => engine_output_wait,
      work_o => engine_work
    );

  counters_inst : entity neorv32.counter_block
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      command_start_i => command_counter_start,
      command_active_i => command_active,
      engine_interval_i => engine_interval,
      engine_active_i => engine_active,
      engine_input_wait_i => engine_input_wait,
      engine_output_wait_i => engine_output_wait,
      engine_control_i => engine_control,
      frontend_input_wait_i => frontend_input_wait,
      frontend_output_wait_i => frontend_output_wait,
      input_bytes_i => frontend_input_bytes,
      output_bytes_i => frontend_output_bytes,
      work_i => engine_work,
      command_cycles_o => counter_command,
      engine_cycles_o => counter_engine,
      active_cycles_o => counter_active,
      input_wait_cycles_o => counter_input_wait,
      output_wait_cycles_o => counter_output_wait,
      control_cycles_o => counter_control,
      frontend_input_wait_o => counter_frontend_in,
      frontend_output_wait_o => counter_frontend_out,
      input_bytes_o => counter_input_bytes,
      output_bytes_o => counter_output_bytes,
      work_o => counter_work
    );

end bonsai_accel_rtl;

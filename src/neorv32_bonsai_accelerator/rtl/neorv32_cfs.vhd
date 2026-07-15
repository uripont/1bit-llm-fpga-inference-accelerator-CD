-- Project-owned NEORV32 CFS implementation for the Bonsai accelerator.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

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
  signal config_matvec_rows, config_matvec_groups : std_ulogic_vector(15 downto 0);
  signal config_matvec_scale_fixed : std_ulogic;
  signal config_attn_heads, config_attn_kv_heads : std_ulogic_vector(7 downto 0);
  signal config_attn_head_dim, config_attn_context_length : std_ulogic_vector(15 downto 0);
  signal config_attn_append_position : std_ulogic_vector(15 downto 0);
  signal service_config_valid : std_ulogic;

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

  signal q1_transaction_valid, q1_transaction_ready, q1_transaction_direction : std_ulogic;
  signal q1_transaction_role : tile_role_t;
  signal q1_transaction_tile, q1_transaction_length : std_ulogic_vector(15 downto 0);
  signal q1_input_valid, q1_input_ready, q1_output_valid, q1_output_ready : std_ulogic;
  signal q1_input_data, q1_output_data : std_ulogic_vector(31 downto 0);
  signal q1_launch, q1_busy, q1_done, q1_error : std_ulogic;
  signal q1_active, q1_input_wait, q1_output_wait : std_ulogic;
  signal q1_work : std_ulogic_vector(31 downto 0);

  signal attn_transaction_valid, attn_transaction_ready, attn_transaction_direction : std_ulogic;
  signal attn_transaction_role : tile_role_t;
  signal attn_transaction_tile, attn_transaction_length : std_ulogic_vector(15 downto 0);
  signal attn_input_valid, attn_input_ready, attn_output_valid, attn_output_ready : std_ulogic;
  signal attn_input_data, attn_output_data : std_ulogic_vector(31 downto 0);
  signal attn_launch, attn_busy, attn_done, attn_error : std_ulogic;
  signal attn_active, attn_input_wait, attn_output_wait : std_ulogic;
  signal attn_work : std_ulogic_vector(31 downto 0);

  signal stream_transaction_valid, stream_transaction_ready : std_ulogic;
  signal stream_transaction_direction : std_ulogic;
  signal stream_transaction_role : tile_role_t;
  signal stream_transaction_tile, stream_transaction_length : std_ulogic_vector(15 downto 0);
  signal stream_input_valid, stream_input_ready : std_ulogic;
  signal stream_output_valid, stream_output_ready : std_ulogic;
  signal stream_input_data, stream_output_data : std_ulogic_vector(31 downto 0);
  signal cpu_transaction_valid, cpu_transaction_ready, cpu_input_valid, cpu_output_ready : std_ulogic;
  signal cpu_input_data : std_ulogic_vector(31 downto 0);
  signal cpu_idle, cpu_error, cpu_input_wait, cpu_output_wait : std_ulogic;
  signal cpu_input_bytes, cpu_output_bytes : std_ulogic_vector(31 downto 0);
  signal mem_transaction_valid, mem_transaction_ready, mem_input_valid, mem_output_ready : std_ulogic;
  signal mem_input_data : std_ulogic_vector(31 downto 0);
  signal mem_idle, mem_error, mem_input_wait, mem_output_wait : std_ulogic;
  signal mem_input_bytes, mem_output_bytes : std_ulogic_vector(31 downto 0);
  signal descriptor_role : tile_role_t;
  signal descriptor_length, descriptor_base, descriptor_stride : std_ulogic_vector(31 downto 0);
  signal descriptor_valid : std_ulogic;
  signal descriptor_valid_mask : std_ulogic_vector(DESCRIPTOR_COUNT_C - 1 downto 0);
  signal memory_cpu_write, memory_init_done, memory_cmd_valid : std_ulogic;
  signal memory_cmd_write, memory_cmd_ready, memory_write_valid : std_ulogic;
  signal memory_write_done, memory_read_valid, memory_error : std_ulogic;
  signal memory_cpu_address, memory_cmd_address : std_ulogic_vector(13 downto 0);
  signal memory_cpu_write_data, memory_cpu_read_data : std_ulogic_vector(31 downto 0);
  signal memory_write_data, memory_read_data : std_ulogic_vector(63 downto 0);

  signal engine_launch, engine_busy, engine_done, engine_error : std_ulogic;
  signal engine_active, engine_input_wait, engine_output_wait : std_ulogic;
  signal engine_work : std_ulogic_vector(31 downto 0);
  signal command_counter_start, command_active, engine_interval, engine_control : std_ulogic;
  signal frontend_idle, frontend_error, frontend_input_wait, frontend_output_wait : std_ulogic;
  signal stream_idle, stream_error : std_ulogic;
  signal frontend_input_bytes, frontend_output_bytes : std_ulogic_vector(31 downto 0);

  signal counter_command, counter_engine, counter_active : std_ulogic_vector(31 downto 0);
  signal counter_input_wait, counter_output_wait, counter_control : std_ulogic_vector(31 downto 0);
  signal counter_frontend_in, counter_frontend_out : std_ulogic_vector(31 downto 0);
  signal counter_input_bytes, counter_output_bytes, counter_work : std_ulogic_vector(31 downto 0);

begin

  irq_o     <= '0';
  cfs_out_o <= (others => '0');

  shape_validation : process(all)
    variable heads_v, kv_heads_v : natural;
    variable head_dim_v, context_v, append_v : natural;
    variable segments_v, kv_tiles_per_position_v : natural;
  begin
    service_config_valid <= '1';
    if selected_service = SERVICE_ATTN_KV_C then
      heads_v := to_integer(unsigned(config_attn_heads));
      kv_heads_v := to_integer(unsigned(config_attn_kv_heads));
      head_dim_v := to_integer(unsigned(config_attn_head_dim));
      context_v := to_integer(unsigned(config_attn_context_length));
      append_v := to_integer(unsigned(config_attn_append_position));
      segments_v := (head_dim_v + ATTN_VECTOR_TILE_ELEMENTS_C - 1) /
                    ATTN_VECTOR_TILE_ELEMENTS_C;
      if (heads_v = 0) or (kv_heads_v = 0) or (head_dim_v = 0) or
         (context_v = 0) or (append_v >= context_v) then
        service_config_valid <= '0';
      elsif (kv_heads_v > ATTN_MAX_KV_HEADS_C) or
            (head_dim_v > ATTN_MAX_HEAD_DIM_C) or
            (context_v > ATTN_SCORE_CAPACITY_C) then
        service_config_valid <= '0';
      elsif (head_dim_v /= 16) and (head_dim_v /= 32) and
            (head_dim_v /= 64) and (head_dim_v /= 128) then
        service_config_valid <= '0';
      elsif (heads_v mod kv_heads_v) /= 0 then
        service_config_valid <= '0';
      elsif (segments_v > 65536 / heads_v) or
            (segments_v > 65536 / kv_heads_v) then
        service_config_valid <= '0';
      else
        kv_tiles_per_position_v := kv_heads_v * segments_v;
        if context_v > 65536 / kv_tiles_per_position_v then
          service_config_valid <= '0';
        end if;
      end if;
      if (selected_transfer = TRANSFER_MEM_STREAM_C) and
         ((descriptor_valid_mask(to_integer(unsigned(ROLE_QUERY_C))) = '0') or
          (descriptor_valid_mask(to_integer(unsigned(ROLE_CURRENT_K_C))) = '0') or
          (descriptor_valid_mask(to_integer(unsigned(ROLE_CURRENT_V_C))) = '0') or
          (descriptor_valid_mask(to_integer(unsigned(ROLE_K_CACHE_C))) = '0') or
          (descriptor_valid_mask(to_integer(unsigned(ROLE_V_CACHE_C))) = '0') or
          (descriptor_valid_mask(to_integer(unsigned(ROLE_OUTPUT_C))) = '0')) then
        service_config_valid <= '0';
      end if;
    end if;
  end process shape_validation;

  engine_control <= engine_interval and not engine_active and
                    not engine_input_wait and not engine_output_wait;

  q1_launch <= engine_launch when selected_service = SERVICE_Q1_MATVEC_C else '0';
  attn_launch <= engine_launch when selected_service = SERVICE_ATTN_KV_C else '0';

  transaction_valid <= q1_transaction_valid when selected_service = SERVICE_Q1_MATVEC_C
    else attn_transaction_valid;
  transaction_direction <= q1_transaction_direction when selected_service = SERVICE_Q1_MATVEC_C
    else attn_transaction_direction;
  transaction_role <= q1_transaction_role when selected_service = SERVICE_Q1_MATVEC_C
    else attn_transaction_role;
  transaction_tile <= q1_transaction_tile when selected_service = SERVICE_Q1_MATVEC_C
    else attn_transaction_tile;
  transaction_length <= q1_transaction_length when selected_service = SERVICE_Q1_MATVEC_C
    else attn_transaction_length;
  q1_transaction_ready <= transaction_ready when selected_service = SERVICE_Q1_MATVEC_C else '0';
  attn_transaction_ready <= transaction_ready when selected_service = SERVICE_ATTN_KV_C else '0';

  q1_input_valid <= engine_input_valid when selected_service = SERVICE_Q1_MATVEC_C else '0';
  attn_input_valid <= engine_input_valid when selected_service = SERVICE_ATTN_KV_C else '0';
  q1_input_data <= engine_input_data;
  attn_input_data <= engine_input_data;
  engine_input_ready <= q1_input_ready when selected_service = SERVICE_Q1_MATVEC_C
    else attn_input_ready;

  engine_output_valid <= q1_output_valid when selected_service = SERVICE_Q1_MATVEC_C
    else attn_output_valid;
  engine_output_data <= q1_output_data when selected_service = SERVICE_Q1_MATVEC_C
    else attn_output_data;
  q1_output_ready <= engine_output_ready when selected_service = SERVICE_Q1_MATVEC_C else '0';
  attn_output_ready <= engine_output_ready when selected_service = SERVICE_ATTN_KV_C else '0';

  engine_busy <= q1_busy when selected_service = SERVICE_Q1_MATVEC_C else attn_busy;
  engine_done <= q1_done when selected_service = SERVICE_Q1_MATVEC_C else attn_done;
  engine_error <= q1_error when selected_service = SERVICE_Q1_MATVEC_C else attn_error;
  engine_active <= q1_active when selected_service = SERVICE_Q1_MATVEC_C else attn_active;
  engine_input_wait <= q1_input_wait when selected_service = SERVICE_Q1_MATVEC_C else attn_input_wait;
  engine_output_wait <= q1_output_wait when selected_service = SERVICE_Q1_MATVEC_C else attn_output_wait;
  engine_work <= q1_work when selected_service = SERVICE_Q1_MATVEC_C else attn_work;

  stream_transaction_ready <= cpu_transaction_ready
    when selected_transfer = TRANSFER_CPU_PUSH_C else mem_transaction_ready;
  stream_input_valid <= cpu_input_valid
    when selected_transfer = TRANSFER_CPU_PUSH_C else mem_input_valid;
  stream_input_data <= cpu_input_data
    when selected_transfer = TRANSFER_CPU_PUSH_C else mem_input_data;
  stream_output_ready <= cpu_output_ready
    when selected_transfer = TRANSFER_CPU_PUSH_C else mem_output_ready;
  stream_idle <= cpu_idle when selected_transfer = TRANSFER_CPU_PUSH_C else mem_idle;
  stream_error <= cpu_error when selected_transfer = TRANSFER_CPU_PUSH_C else mem_error;
  frontend_input_wait <= cpu_input_wait
    when selected_transfer = TRANSFER_CPU_PUSH_C else mem_input_wait;
  frontend_output_wait <= cpu_output_wait
    when selected_transfer = TRANSFER_CPU_PUSH_C else mem_output_wait;
  frontend_input_bytes <= cpu_input_bytes
    when selected_transfer = TRANSFER_CPU_PUSH_C else mem_input_bytes;
  frontend_output_bytes <= cpu_output_bytes
    when selected_transfer = TRANSFER_CPU_PUSH_C else mem_output_bytes;
  cpu_transaction_valid <= stream_transaction_valid
    when selected_transfer = TRANSFER_CPU_PUSH_C else '0';
  mem_transaction_valid <= stream_transaction_valid
    when selected_transfer = TRANSFER_MEM_STREAM_C else '0';

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
      matvec_rows_o => config_matvec_rows,
      matvec_groups_o => config_matvec_groups,
      matvec_scale_fixed_o => config_matvec_scale_fixed,
      attn_heads_o => config_attn_heads,
      attn_kv_heads_o => config_attn_kv_heads,
      attn_head_dim_o => config_attn_head_dim,
      attn_context_length_o => config_attn_context_length,
      attn_append_position_o => config_attn_append_position,
      descriptor_role_i => descriptor_role,
      descriptor_length_o => descriptor_length,
      descriptor_base_o => descriptor_base,
      descriptor_stride_o => descriptor_stride,
      descriptor_valid_o => descriptor_valid,
      descriptor_valid_mask_o => descriptor_valid_mask,
      memory_cpu_write_o => memory_cpu_write,
      memory_cpu_address_o => memory_cpu_address,
      memory_cpu_data_o => memory_cpu_write_data,
      memory_cpu_data_i => memory_cpu_read_data,
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
      service_config_valid_i => service_config_valid,
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

  frontend_control_inst : entity neorv32.frontend_control
    generic map (
      TILE_WORD_CAPACITY => ATTN_VECTOR_TILE_WORDS_C
    )
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      command_start_i => command_counter_start,
      engine_transaction_valid_i => transaction_valid,
      engine_transaction_ready_o => transaction_ready,
      engine_transaction_direction_i => transaction_direction,
      engine_transaction_role_i => transaction_role,
      engine_transaction_tile_i => transaction_tile,
      engine_transaction_length_i => transaction_length,
      engine_input_valid_o => engine_input_valid,
      engine_input_ready_i => engine_input_ready,
      engine_input_data_o => engine_input_data,
      engine_output_valid_i => engine_output_valid,
      engine_output_ready_o => engine_output_ready,
      engine_output_data_i => engine_output_data,
      stream_transaction_valid_o => stream_transaction_valid,
      stream_transaction_ready_i => stream_transaction_ready,
      stream_transaction_direction_o => stream_transaction_direction,
      stream_transaction_role_o => stream_transaction_role,
      stream_transaction_tile_o => stream_transaction_tile,
      stream_transaction_length_o => stream_transaction_length,
      stream_input_valid_i => stream_input_valid,
      stream_input_ready_o => stream_input_ready,
      stream_input_data_i => stream_input_data,
      stream_output_valid_o => stream_output_valid,
      stream_output_ready_i => stream_output_ready,
      stream_output_data_o => stream_output_data,
      stream_idle_i => stream_idle,
      stream_error_i => stream_error,
      idle_o => frontend_idle,
      error_o => frontend_error
    );

  stream_frontend_inst : entity neorv32.stream_frontend
    generic map (
      FIFO_DEPTH => 2
    )
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      command_start_i => command_counter_start,
      transaction_valid_i => cpu_transaction_valid,
      transaction_ready_o => cpu_transaction_ready,
      transaction_direction_i => stream_transaction_direction,
      transaction_role_i => stream_transaction_role,
      transaction_tile_i => stream_transaction_tile,
      transaction_length_i => stream_transaction_length,
      engine_input_valid_o => cpu_input_valid,
      engine_input_ready_i => stream_input_ready,
      engine_input_data_o => cpu_input_data,
      engine_output_valid_i => stream_output_valid,
      engine_output_ready_o => cpu_output_ready,
      engine_output_data_i => stream_output_data,
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
      input_wait_o => cpu_input_wait,
      output_wait_o => cpu_output_wait,
      input_bytes_o => cpu_input_bytes,
      output_bytes_o => cpu_output_bytes,
      idle_o => cpu_idle,
      error_o => cpu_error
    );

  memory_streamer_inst : entity neorv32.memory_streamer
    port map (
      clk_i => clk_i, rstn_i => rstn_i, command_start_i => command_counter_start,
      head_dim_i => config_attn_head_dim,
      context_length_i => config_attn_context_length,
      append_position_i => config_attn_append_position,
      transaction_valid_i => mem_transaction_valid,
      transaction_ready_o => mem_transaction_ready,
      transaction_direction_i => stream_transaction_direction,
      transaction_role_i => stream_transaction_role,
      transaction_tile_i => stream_transaction_tile,
      transaction_length_i => stream_transaction_length,
      engine_input_valid_o => mem_input_valid,
      engine_input_ready_i => stream_input_ready,
      engine_input_data_o => mem_input_data,
      engine_output_valid_i => stream_output_valid,
      engine_output_ready_o => mem_output_ready,
      engine_output_data_i => stream_output_data,
      descriptor_role_o => descriptor_role,
      descriptor_length_i => descriptor_length,
      descriptor_base_i => descriptor_base,
      descriptor_stride_i => descriptor_stride,
      descriptor_valid_i => descriptor_valid,
      memory_init_done_i => memory_init_done,
      memory_cmd_valid_o => memory_cmd_valid,
      memory_cmd_write_o => memory_cmd_write,
      memory_cmd_address_o => memory_cmd_address,
      memory_cmd_ready_i => memory_cmd_ready,
      memory_write_data_o => memory_write_data,
      memory_write_valid_o => memory_write_valid,
      memory_write_done_i => memory_write_done,
      memory_read_data_i => memory_read_data,
      memory_read_valid_i => memory_read_valid,
      memory_error_i => memory_error,
      input_wait_o => mem_input_wait,
      output_wait_o => mem_output_wait,
      input_bytes_o => mem_input_bytes,
      output_bytes_o => mem_output_bytes,
      idle_o => mem_idle,
      error_o => mem_error
    );

  stream_memory_inst : entity neorv32.stream_memory
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      cpu_write_i => memory_cpu_write,
      cpu_address_i => memory_cpu_address,
      cpu_write_data_i => memory_cpu_write_data,
      cpu_read_data_o => memory_cpu_read_data,
      init_done_o => memory_init_done,
      cmd_valid_i => memory_cmd_valid,
      cmd_write_i => memory_cmd_write,
      cmd_address_i => memory_cmd_address,
      cmd_ready_o => memory_cmd_ready,
      write_data_i => memory_write_data,
      write_valid_i => memory_write_valid,
      write_done_o => memory_write_done,
      read_data_o => memory_read_data,
      read_valid_o => memory_read_valid,
      error_o => memory_error
    );

  q1_matvec_engine_inst : entity neorv32.q1_matvec_engine
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      launch_i => q1_launch,
      rows_i => config_matvec_rows,
      groups_i => config_matvec_groups,
      scale_fixed_i => config_matvec_scale_fixed,
      transaction_valid_o => q1_transaction_valid,
      transaction_ready_i => q1_transaction_ready,
      transaction_direction_o => q1_transaction_direction,
      transaction_role_o => q1_transaction_role,
      transaction_tile_o => q1_transaction_tile,
      transaction_length_o => q1_transaction_length,
      input_valid_i => q1_input_valid,
      input_ready_o => q1_input_ready,
      input_data_i => q1_input_data,
      output_valid_o => q1_output_valid,
      output_ready_i => q1_output_ready,
      output_data_o => q1_output_data,
      busy_o => q1_busy,
      done_o => q1_done,
      error_o => q1_error,
      active_o => q1_active,
      input_wait_o => q1_input_wait,
      output_wait_o => q1_output_wait,
      work_o => q1_work
    );

  attn_engine_inst : entity neorv32.attn_kv_engine
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      launch_i => attn_launch,
      heads_i => config_attn_heads,
      kv_heads_i => config_attn_kv_heads,
      head_dim_i => config_attn_head_dim,
      context_length_i => config_attn_context_length,
      append_position_i => config_attn_append_position,
      transaction_valid_o => attn_transaction_valid,
      transaction_ready_i => attn_transaction_ready,
      transaction_direction_o => attn_transaction_direction,
      transaction_role_o => attn_transaction_role,
      transaction_tile_o => attn_transaction_tile,
      transaction_length_o => attn_transaction_length,
      input_valid_i => attn_input_valid,
      input_ready_o => attn_input_ready,
      input_data_i => attn_input_data,
      output_valid_o => attn_output_valid,
      output_ready_i => attn_output_ready,
      output_data_o => attn_output_data,
      busy_o => attn_busy,
      done_o => attn_done,
      error_o => attn_error,
      active_o => attn_active,
      input_wait_o => attn_input_wait,
      output_wait_o => attn_output_wait,
      work_o => attn_work
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

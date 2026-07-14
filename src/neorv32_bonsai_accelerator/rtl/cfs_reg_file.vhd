-- CPU-visible register file for the Bonsai accelerator CFS.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;
use neorv32.bonsai_accel_pkg.all;

entity cfs_reg_file is
  port (
    clk_i     : in  std_ulogic;
    rstn_i    : in  std_ulogic;
    bus_req_i : in  bus_req_t;
    bus_rsp_o : out bus_rsp_t;

    start_o         : out std_ulogic;
    acknowledge_o   : out std_ulogic;
    service_o       : out service_t;
    transfer_mode_o : out transfer_mode_t;

    busy_i          : in std_ulogic;
    done_i          : in std_ulogic;
    error_i         : in std_ulogic;
    selected_service_i  : in service_t;
    selected_transfer_i : in transfer_mode_t;
    error_code_i        : in error_code_t;

    counter_command_i      : in std_ulogic_vector(31 downto 0);
    counter_engine_i       : in std_ulogic_vector(31 downto 0);
    counter_active_i       : in std_ulogic_vector(31 downto 0);
    counter_input_wait_i   : in std_ulogic_vector(31 downto 0);
    counter_output_wait_i  : in std_ulogic_vector(31 downto 0);
    counter_control_i      : in std_ulogic_vector(31 downto 0);
    counter_frontend_in_i  : in std_ulogic_vector(31 downto 0);
    counter_frontend_out_i : in std_ulogic_vector(31 downto 0);
    counter_input_bytes_i  : in std_ulogic_vector(31 downto 0);
    counter_output_bytes_i : in std_ulogic_vector(31 downto 0);
    counter_work_i         : in std_ulogic_vector(31 downto 0)
  );
end cfs_reg_file;

architecture rtl of cfs_reg_file is

  signal config_reg : std_ulogic_vector(31 downto 0);

begin

  service_o       <= config_reg(CONFIG_SERVICE_MSB_C downto CONFIG_SERVICE_LSB_C);
  transfer_mode_o <= config_reg(CONFIG_TRANSFER_BIT_C);

  bus_access : process(rstn_i, clk_i)
    variable word_addr_v : natural range 0 to 16383;
    variable status_v    : std_ulogic_vector(31 downto 0);
  begin
    if rstn_i = '0' then
      config_reg   <= (others => '0');
      start_o      <= '0';
      acknowledge_o <= '0';
      bus_rsp_o    <= rsp_terminate_c;
    elsif rising_edge(clk_i) then
      start_o        <= '0';
      acknowledge_o  <= '0';
      bus_rsp_o.ack   <= bus_req_i.stb;
      bus_rsp_o.err   <= '0';
      bus_rsp_o.data  <= (others => '0');

      if bus_req_i.stb = '1' then
        word_addr_v := to_integer(unsigned(bus_req_i.addr(15 downto 2)));

        if bus_req_i.rw = '1' then
          if bus_req_i.ben = "1111" then
            case word_addr_v is
              when REG_COMMAND_C =>
                start_o       <= bus_req_i.data(COMMAND_START_BIT_C);
                acknowledge_o <= bus_req_i.data(COMMAND_ACK_BIT_C);
              when REG_CONFIG_C =>
                if busy_i = '0' then
                  config_reg <= (others => '0');
                  config_reg(CONFIG_SERVICE_MSB_C downto CONFIG_SERVICE_LSB_C) <=
                    bus_req_i.data(CONFIG_SERVICE_MSB_C downto CONFIG_SERVICE_LSB_C);
                  config_reg(CONFIG_TRANSFER_BIT_C) <= bus_req_i.data(CONFIG_TRANSFER_BIT_C);
                end if;
              when others =>
                null;
            end case;
          end if;
        else
          case word_addr_v is
            when REG_ID_C =>
              bus_rsp_o.data <= BONSAI_ACCEL_ID_C;
            when REG_VERSION_C =>
              bus_rsp_o.data <= BONSAI_ACCEL_VERSION_C;
            when REG_STATUS_C =>
              status_v := (others => '0');
              status_v(STATUS_BUSY_BIT_C) := busy_i;
              status_v(STATUS_DONE_BIT_C) := done_i;
              status_v(STATUS_ERROR_BIT_C) := error_i;
              status_v(STATUS_SERVICE_MSB_C downto STATUS_SERVICE_LSB_C) := selected_service_i;
              status_v(STATUS_TRANSFER_BIT_C) := selected_transfer_i;
              status_v(STATUS_ERROR_CODE_MSB_C downto STATUS_ERROR_CODE_LSB_C) := error_code_i;
              bus_rsp_o.data <= status_v;
            when REG_CONFIG_C =>
              bus_rsp_o.data <= config_reg;
            when REG_COUNTER_COMMAND_C =>
              bus_rsp_o.data <= counter_command_i;
            when REG_COUNTER_ENGINE_C =>
              bus_rsp_o.data <= counter_engine_i;
            when REG_COUNTER_ACTIVE_C =>
              bus_rsp_o.data <= counter_active_i;
            when REG_COUNTER_INPUT_WAIT_C =>
              bus_rsp_o.data <= counter_input_wait_i;
            when REG_COUNTER_OUTPUT_WAIT_C =>
              bus_rsp_o.data <= counter_output_wait_i;
            when REG_COUNTER_CONTROL_C =>
              bus_rsp_o.data <= counter_control_i;
            when REG_COUNTER_FRONTEND_IN_C =>
              bus_rsp_o.data <= counter_frontend_in_i;
            when REG_COUNTER_FRONTEND_OUT_C =>
              bus_rsp_o.data <= counter_frontend_out_i;
            when REG_COUNTER_INPUT_BYTES_C =>
              bus_rsp_o.data <= counter_input_bytes_i;
            when REG_COUNTER_OUTPUT_BYTES_C =>
              bus_rsp_o.data <= counter_output_bytes_i;
            when REG_COUNTER_WORK_C =>
              bus_rsp_o.data <= counter_work_i;
            when others =>
              bus_rsp_o.data <= (others => '0');
          end case;
        end if;
      end if;
    end if;
  end process bus_access;

end rtl;


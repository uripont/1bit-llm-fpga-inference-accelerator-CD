-- Project-owned NEORV32 CFS implementation for the Bonsai accelerator.
-- The shell logic is added behind this stable bus boundary in later commits.

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

  signal config_reg : std_ulogic_vector(31 downto 0);

begin

  -- Interrupts and external conduits are reserved for later integration work.
  irq_o     <= '0';
  cfs_out_o <= (others => '0');

  bus_access : process(rstn_i, clk_i)
    variable word_addr_v : natural range 0 to 16383;
  begin
    if rstn_i = '0' then
      config_reg <= (others => '0');
      bus_rsp_o  <= rsp_terminate_c;
    elsif rising_edge(clk_i) then
      bus_rsp_o.ack  <= bus_req_i.stb;
      bus_rsp_o.err  <= '0';
      bus_rsp_o.data <= (others => '0');

      if bus_req_i.stb = '1' then
        word_addr_v := to_integer(unsigned(bus_req_i.addr(15 downto 2)));

        if bus_req_i.rw = '1' then
          if (word_addr_v = REG_CONFIG_C) and (bus_req_i.ben = "1111") then
            config_reg <= (others => '0');
            config_reg(CONFIG_SERVICE_MSB_C downto CONFIG_SERVICE_LSB_C) <=
              bus_req_i.data(CONFIG_SERVICE_MSB_C downto CONFIG_SERVICE_LSB_C);
            config_reg(CONFIG_TRANSFER_BIT_C) <= bus_req_i.data(CONFIG_TRANSFER_BIT_C);
          end if;
        else
          case word_addr_v is
            when REG_ID_C      => bus_rsp_o.data <= BONSAI_ACCEL_ID_C;
            when REG_VERSION_C => bus_rsp_o.data <= BONSAI_ACCEL_VERSION_C;
            when REG_CONFIG_C  => bus_rsp_o.data <= config_reg;
            when others        => bus_rsp_o.data <= (others => '0');
          end case;
        end if;
      end if;
    end if;
  end process bus_access;

end bonsai_accel_rtl;


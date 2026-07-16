-- Tang Nano 9K CFS wrapper for Proposal B synthesis.

library ieee;
use ieee.std_logic_1164.all;

library neorv32;
use neorv32.neorv32_package.all;

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

architecture rtl of neorv32_cfs is
begin
  core_inst : entity neorv32.bonsai_cfs_core
    generic map (
      ENABLE_Q1_ENGINE_G => false,
      ENABLE_ATTN_ENGINE_G => true,
      ENABLE_MEM_STREAM_G => false,
      COUNTER_WIDTH_G => 24
    )
    port map (
      clk_i => clk_i,
      rstn_i => rstn_i,
      bus_req_i => bus_req_i,
      bus_rsp_o => bus_rsp_o,
      irq_o => irq_o,
      cfs_in_i => cfs_in_i,
      cfs_out_o => cfs_out_o
    );
end rtl;

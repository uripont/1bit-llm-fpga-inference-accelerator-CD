-- Shared constants for the Bonsai NEORV32 accelerator hardware interface.

library ieee;
use ieee.std_logic_1164.all;

package bonsai_accel_pkg is

  -- CFS identity and interface version (major.minor.patch in bits 31:8).
  constant BONSAI_ACCEL_ID_C      : std_ulogic_vector(31 downto 0) := x"424E5341"; -- "BNSA"
  constant BONSAI_ACCEL_VERSION_C : std_ulogic_vector(31 downto 0) := x"00010000";

  -- CFS word-addressed register map.
  constant REG_ID_C                : natural := 0;  -- 0x00, read-only
  constant REG_VERSION_C           : natural := 1;  -- 0x04, read-only
  constant REG_COMMAND_C           : natural := 2;  -- 0x08, write pulses
  constant REG_STATUS_C            : natural := 3;  -- 0x0c, read-only
  constant REG_CONFIG_C            : natural := 4;  -- 0x10, read/write
  constant REG_DESC_SELECT_C       : natural := 5;  -- 0x14
  constant REG_DESC_LENGTH_C       : natural := 6;  -- 0x18
  constant REG_DESC_BASE_C         : natural := 7;  -- 0x1c
  constant REG_DESC_STRIDE_C       : natural := 8;  -- 0x20
  constant REG_REQUEST_C           : natural := 9;  -- 0x24
  constant REG_REQUEST_TILE_C      : natural := 10; -- 0x28
  constant REG_REQUEST_REMAINING_C : natural := 11; -- 0x2c
  constant REG_FIFO_IN_C           : natural := 12; -- 0x30
  constant REG_FIFO_OUT_C          : natural := 13; -- 0x34
  constant REG_FIFO_STATUS_C       : natural := 14; -- 0x38

  constant REG_COUNTER_COMMAND_C       : natural := 16; -- 0x40
  constant REG_COUNTER_ENGINE_C        : natural := 17; -- 0x44
  constant REG_COUNTER_ACTIVE_C        : natural := 18; -- 0x48
  constant REG_COUNTER_INPUT_WAIT_C    : natural := 19; -- 0x4c
  constant REG_COUNTER_OUTPUT_WAIT_C   : natural := 20; -- 0x50
  constant REG_COUNTER_CONTROL_C       : natural := 21; -- 0x54
  constant REG_COUNTER_FRONTEND_IN_C   : natural := 22; -- 0x58
  constant REG_COUNTER_FRONTEND_OUT_C  : natural := 23; -- 0x5c
  constant REG_COUNTER_INPUT_BYTES_C   : natural := 24; -- 0x60
  constant REG_COUNTER_OUTPUT_BYTES_C  : natural := 25; -- 0x64
  constant REG_COUNTER_WORK_C          : natural := 26; -- 0x68

  -- Command register pulse bits.
  constant COMMAND_START_BIT_C : natural := 0;
  constant COMMAND_ACK_BIT_C   : natural := 1;

  -- Configuration register fields.
  subtype service_t is std_ulogic_vector(1 downto 0);
  constant SERVICE_NONE_C      : service_t := "00";
  constant SERVICE_Q1_MATVEC_C : service_t := "01";
  constant SERVICE_ATTN_KV_C   : service_t := "10";
  constant CONFIG_SERVICE_LSB_C : natural := 0;
  constant CONFIG_SERVICE_MSB_C : natural := 1;

  subtype transfer_mode_t is std_ulogic;
  constant TRANSFER_CPU_PUSH_C  : transfer_mode_t := '0';
  constant TRANSFER_MEM_STREAM_C : transfer_mode_t := '1';
  constant CONFIG_TRANSFER_BIT_C : natural := 8;

  -- Semantic tile roles shared by the software descriptors and both engines.
  subtype tile_role_t is std_ulogic_vector(3 downto 0);
  constant ROLE_NONE_C       : tile_role_t := x"0";
  constant ROLE_Q8_INPUT_C   : tile_role_t := x"1";
  constant ROLE_Q1_WEIGHTS_C : tile_role_t := x"2";
  constant ROLE_QUERY_C      : tile_role_t := x"3";
  constant ROLE_CURRENT_K_C  : tile_role_t := x"4";
  constant ROLE_CURRENT_V_C  : tile_role_t := x"5";
  constant ROLE_K_CACHE_C    : tile_role_t := x"6";
  constant ROLE_V_CACHE_C    : tile_role_t := x"7";
  constant ROLE_OUTPUT_C     : tile_role_t := x"8";
  constant ROLE_SCORES_C     : tile_role_t := x"9";

  -- Terminal error codes. Later commits provide the command logic that emits them.
  subtype error_code_t is std_ulogic_vector(3 downto 0);
  constant ERROR_NONE_C             : error_code_t := x"0";
  constant ERROR_BAD_COMMAND_C      : error_code_t := x"1";
  constant ERROR_UNSUPPORTED_MODE_C : error_code_t := x"2";
  constant ERROR_PROTOCOL_C         : error_code_t := x"3";
  constant ERROR_ENGINE_C           : error_code_t := x"4";
  constant ERROR_FRONTEND_C         : error_code_t := x"5";

end package bonsai_accel_pkg;


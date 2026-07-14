-- Shared constants for the Bonsai NEORV32 accelerator hardware interface.

library ieee;
use ieee.std_logic_1164.all;

package bonsai_accel_pkg is

  -- CFS identity and interface version (major.minor.patch in bits 31:8).
  constant BONSAI_ACCEL_ID_C      : std_ulogic_vector(31 downto 0) := x"424E5341"; -- "BNSA"
  constant BONSAI_ACCEL_VERSION_C : std_ulogic_vector(31 downto 0) := x"00010200";

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
  constant REG_MATVEC_SHAPE_C      : natural := 15; -- 0x3c

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

  -- Status register fields.
  constant STATUS_BUSY_BIT_C          : natural := 0;
  constant STATUS_DONE_BIT_C          : natural := 1;
  constant STATUS_ERROR_BIT_C         : natural := 2;
  constant STATUS_SERVICE_LSB_C       : natural := 8;
  constant STATUS_SERVICE_MSB_C       : natural := 9;
  constant STATUS_TRANSFER_BIT_C      : natural := 10;
  constant STATUS_ERROR_CODE_LSB_C    : natural := 16;
  constant STATUS_ERROR_CODE_MSB_C    : natural := 19;

  -- CPU_PUSH request register. Ingress and egress may be active together.
  constant REQUEST_INPUT_VALID_BIT_C  : natural := 0;
  constant REQUEST_OUTPUT_VALID_BIT_C : natural := 1;
  constant REQUEST_INPUT_ROLE_LSB_C   : natural := 4;
  constant REQUEST_INPUT_ROLE_MSB_C   : natural := 7;
  constant REQUEST_OUTPUT_ROLE_LSB_C  : natural := 8;
  constant REQUEST_OUTPUT_ROLE_MSB_C  : natural := 11;

  -- CPU_PUSH FIFO status register.
  constant FIFO_INPUT_READY_BIT_C     : natural := 0;
  constant FIFO_OUTPUT_VALID_BIT_C    : natural := 1;
  constant FIFO_INPUT_LEVEL_LSB_C     : natural := 8;
  constant FIFO_INPUT_LEVEL_MSB_C     : natural := 15;
  constant FIFO_OUTPUT_LEVEL_LSB_C    : natural := 16;
  constant FIFO_OUTPUT_LEVEL_MSB_C    : natural := 23;

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
  constant CONFIG_Q1_SCALE_FIXED_BIT_C : natural := 9;

  -- Q1 scale format at the engine boundary. GGUF rows use FP16; the Tier 3
  -- synthetic board fixture supplies its already-converted signed Q8 scale.
  constant Q1_SCALE_FP16_C    : std_ulogic := '0';
  constant Q1_SCALE_FIXED_Q8_C : std_ulogic := '1';

  -- Matvec shape register: groups per row in the low half, rows in the high half.
  constant MATVEC_GROUPS_LSB_C : natural := 0;
  constant MATVEC_GROUPS_MSB_C : natural := 15;
  constant MATVEC_ROWS_LSB_C   : natural := 16;
  constant MATVEC_ROWS_MSB_C   : natural := 31;

  -- CPU_PUSH record sizes. Multi-byte fields and packed lanes are little-endian.
  -- Q8: signed Q16 scale followed by 32 signed int8 lanes, four lanes per word.
  -- Q1: raw GGUF FP16 scale in word 0[15:0], then 128 signs in four words.
  -- Output: one sign-extended signed int16 result per word.
  constant Q8_BLOCK_ELEMENTS_C  : natural := 32;
  constant Q1_GROUP_ELEMENTS_C  : natural := 128;
  constant Q8_BLOCKS_PER_Q1_C   : natural := 4;
  constant Q8_BLOCK_WORDS_C     : natural := 9;
  constant Q1_GROUP_WORDS_C     : natural := 5;
  constant MATVEC_OUTPUT_WORDS_C : natural := 1;

  constant TILE_DIRECTION_INPUT_C  : std_ulogic := '0';
  constant TILE_DIRECTION_OUTPUT_C : std_ulogic := '1';

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

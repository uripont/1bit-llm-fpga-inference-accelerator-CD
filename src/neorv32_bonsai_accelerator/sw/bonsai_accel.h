#ifndef BONSAI_ACCEL_H
#define BONSAI_ACCEL_H

#include <stdint.h>
#include <neorv32.h>

#define BONSAI_ACCEL_ID UINT32_C(0x424e5341)
#define BONSAI_ACCEL_VERSION UINT32_C(0x00010400)

enum bonsai_accel_register {
  BONSAI_REG_ID = 0,
  BONSAI_REG_VERSION = 1,
  BONSAI_REG_COMMAND = 2,
  BONSAI_REG_STATUS = 3,
  BONSAI_REG_CONFIG = 4,
  BONSAI_REG_DESC_SELECT = 5,
  BONSAI_REG_DESC_LENGTH = 6,
  BONSAI_REG_DESC_BASE = 7,
  BONSAI_REG_DESC_STRIDE = 8,
  BONSAI_REG_REQUEST = 9,
  BONSAI_REG_REQUEST_TILE = 10,
  BONSAI_REG_REQUEST_REMAINING = 11,
  BONSAI_REG_FIFO_IN = 12,
  BONSAI_REG_FIFO_OUT = 13,
  BONSAI_REG_FIFO_STATUS = 14,
  BONSAI_REG_MATVEC_SHAPE = 15,
  BONSAI_REG_COUNTER_COMMAND = 16,
  BONSAI_REG_COUNTER_ENGINE = 17,
  BONSAI_REG_COUNTER_ACTIVE = 18,
  BONSAI_REG_COUNTER_INPUT_WAIT = 19,
  BONSAI_REG_COUNTER_OUTPUT_WAIT = 20,
  BONSAI_REG_COUNTER_CONTROL = 21,
  BONSAI_REG_COUNTER_FRONTEND_IN = 22,
  BONSAI_REG_COUNTER_FRONTEND_OUT = 23,
  BONSAI_REG_COUNTER_INPUT_BYTES = 24,
  BONSAI_REG_COUNTER_OUTPUT_BYTES = 25,
  BONSAI_REG_COUNTER_WORK = 26,
  BONSAI_REG_ATTN_HEADS_DIM = 27,
  BONSAI_REG_ATTN_CONTEXT = 28,
};

enum bonsai_accel_service {
  BONSAI_SERVICE_NONE = 0,
  BONSAI_SERVICE_Q1_MATVEC = 1,
  BONSAI_SERVICE_ATTN_KV = 2,
};

enum bonsai_accel_transfer_mode {
  BONSAI_TRANSFER_CPU_PUSH = 0,
  BONSAI_TRANSFER_MEM_STREAM = 1,
};

enum bonsai_accel_tile_role {
  BONSAI_ROLE_NONE = 0,
  BONSAI_ROLE_Q8_INPUT = 1,
  BONSAI_ROLE_Q1_WEIGHTS = 2,
  BONSAI_ROLE_QUERY = 3,
  BONSAI_ROLE_CURRENT_K = 4,
  BONSAI_ROLE_CURRENT_V = 5,
  BONSAI_ROLE_K_CACHE = 6,
  BONSAI_ROLE_V_CACHE = 7,
  BONSAI_ROLE_OUTPUT = 8,
  BONSAI_ROLE_SCORES = 9,
};

enum bonsai_accel_error {
  BONSAI_ERROR_NONE = 0,
  BONSAI_ERROR_BAD_COMMAND = 1,
  BONSAI_ERROR_UNSUPPORTED_MODE = 2,
  BONSAI_ERROR_PROTOCOL = 3,
  BONSAI_ERROR_ENGINE = 4,
  BONSAI_ERROR_FRONTEND = 5,
};

#define BONSAI_COMMAND_START (UINT32_C(1) << 0)
#define BONSAI_COMMAND_ACK (UINT32_C(1) << 1)

#define BONSAI_STATUS_BUSY (UINT32_C(1) << 0)
#define BONSAI_STATUS_DONE (UINT32_C(1) << 1)
#define BONSAI_STATUS_ERROR (UINT32_C(1) << 2)
#define BONSAI_STATUS_SERVICE_SHIFT 8
#define BONSAI_STATUS_SERVICE_MASK UINT32_C(0x00000300)
#define BONSAI_STATUS_TRANSFER_SHIFT 10
#define BONSAI_STATUS_TRANSFER_MASK UINT32_C(0x00000400)
#define BONSAI_STATUS_ERROR_CODE_SHIFT 16
#define BONSAI_STATUS_ERROR_CODE_MASK UINT32_C(0x000f0000)

#define BONSAI_REQUEST_INPUT_VALID (UINT32_C(1) << 0)
#define BONSAI_REQUEST_OUTPUT_VALID (UINT32_C(1) << 1)
#define BONSAI_REQUEST_INPUT_ROLE_SHIFT 4
#define BONSAI_REQUEST_INPUT_ROLE_MASK UINT32_C(0x000000f0)
#define BONSAI_REQUEST_OUTPUT_ROLE_SHIFT 8
#define BONSAI_REQUEST_OUTPUT_ROLE_MASK UINT32_C(0x00000f00)

#define BONSAI_FIFO_INPUT_READY (UINT32_C(1) << 0)
#define BONSAI_FIFO_OUTPUT_VALID (UINT32_C(1) << 1)
#define BONSAI_FIFO_INPUT_LEVEL_SHIFT 8
#define BONSAI_FIFO_INPUT_LEVEL_MASK UINT32_C(0x0000ff00)
#define BONSAI_FIFO_OUTPUT_LEVEL_SHIFT 16
#define BONSAI_FIFO_OUTPUT_LEVEL_MASK UINT32_C(0x00ff0000)

#define BONSAI_CONFIG_SERVICE_MASK UINT32_C(0x00000003)
#define BONSAI_CONFIG_TRANSFER_SHIFT 8
#define BONSAI_CONFIG_TRANSFER_MASK UINT32_C(0x00000100)
#define BONSAI_CONFIG_Q1_SCALE_FIXED_SHIFT 9
#define BONSAI_CONFIG_Q1_SCALE_FIXED_MASK UINT32_C(0x00000200)

enum bonsai_accel_q1_scale_format {
  BONSAI_Q1_SCALE_FP16 = 0,
  BONSAI_Q1_SCALE_FIXED_Q8 = 1,
};

#define BONSAI_MATVEC_GROUPS_SHIFT 0
#define BONSAI_MATVEC_GROUPS_MASK UINT32_C(0x0000ffff)
#define BONSAI_MATVEC_ROWS_SHIFT 16
#define BONSAI_MATVEC_ROWS_MASK UINT32_C(0xffff0000)

#define BONSAI_ATTN_HEADS_SHIFT 0
#define BONSAI_ATTN_HEADS_MASK UINT32_C(0x000000ff)
#define BONSAI_ATTN_KV_HEADS_SHIFT 8
#define BONSAI_ATTN_KV_HEADS_MASK UINT32_C(0x0000ff00)
#define BONSAI_ATTN_HEAD_DIM_SHIFT 16
#define BONSAI_ATTN_HEAD_DIM_MASK UINT32_C(0xffff0000)
#define BONSAI_ATTN_CONTEXT_LENGTH_SHIFT 0
#define BONSAI_ATTN_CONTEXT_LENGTH_MASK UINT32_C(0x0000ffff)
#define BONSAI_ATTN_APPEND_POSITION_SHIFT 16
#define BONSAI_ATTN_APPEND_POSITION_MASK UINT32_C(0xffff0000)

#define BONSAI_Q8_BLOCK_ELEMENTS 32u
#define BONSAI_Q1_GROUP_ELEMENTS 128u
#define BONSAI_Q8_BLOCKS_PER_Q1 4u
#define BONSAI_Q8_BLOCK_WORDS 9u
#define BONSAI_Q1_GROUP_WORDS 5u
#define BONSAI_MATVEC_OUTPUT_WORDS 1u

/* Attention vector roles share packed signed-int16 words: element 2n occupies
 * bits 15:0 and element 2n+1 occupies bits 31:16. Larger vectors continue in
 * consecutive tiles; the final transaction carries its valid word count. */
#define BONSAI_ATTN_VECTOR_TILE_ELEMENTS 32u
#define BONSAI_ATTN_VECTOR_TILE_WORDS 16u
#define BONSAI_ATTN_MAX_HEAD_DIM 128u
#define BONSAI_ATTN_MAX_KV_HEADS 8u
#define BONSAI_ATTN_SCORE_CAPACITY 256u

/* Descriptor length is a tile count. Base and stride are byte-addressed and
 * must be 32-bit aligned. The memory window models the external backing store
 * during simulation and is populated before command timing begins. */
#define BONSAI_DESCRIPTOR_COUNT 16u
#define BONSAI_MEM_WINDOW_BASE_WORD 256u
#define BONSAI_MEM_WINDOW_WORDS 16128u

static inline uint32_t bonsai_accel_read(unsigned int reg) {
  return NEORV32_CFS->REG[reg];
}

static inline void bonsai_accel_write(unsigned int reg, uint32_t value) {
  NEORV32_CFS->REG[reg] = value;
}

static inline volatile uint32_t *bonsai_accel_memory_window(void) {
  return ((volatile uint32_t *)NEORV32_CFS) + BONSAI_MEM_WINDOW_BASE_WORD;
}

static inline void bonsai_accel_write_descriptor(
    enum bonsai_accel_tile_role role, uint32_t tile_count,
    uint32_t base_bytes, uint32_t stride_bytes) {
  bonsai_accel_write(BONSAI_REG_DESC_SELECT, (uint32_t)role);
  bonsai_accel_write(BONSAI_REG_DESC_LENGTH, tile_count);
  bonsai_accel_write(BONSAI_REG_DESC_BASE, base_bytes);
  bonsai_accel_write(BONSAI_REG_DESC_STRIDE, stride_bytes);
}

static inline uint32_t bonsai_accel_config(enum bonsai_accel_service service,
                                           enum bonsai_accel_transfer_mode transfer) {
  return ((uint32_t) service & BONSAI_CONFIG_SERVICE_MASK) |
         (((uint32_t) transfer << BONSAI_CONFIG_TRANSFER_SHIFT) &
          BONSAI_CONFIG_TRANSFER_MASK);
}

static inline uint32_t bonsai_accel_matvec_config(
    enum bonsai_accel_transfer_mode transfer,
    enum bonsai_accel_q1_scale_format scale_format) {
  return bonsai_accel_config(BONSAI_SERVICE_Q1_MATVEC, transfer) |
         (((uint32_t)scale_format << BONSAI_CONFIG_Q1_SCALE_FIXED_SHIFT) &
          BONSAI_CONFIG_Q1_SCALE_FIXED_MASK);
}

static inline uint32_t bonsai_accel_matvec_shape(uint16_t rows,
                                                 uint16_t groups_per_row) {
  return ((uint32_t) groups_per_row << BONSAI_MATVEC_GROUPS_SHIFT) |
         ((uint32_t) rows << BONSAI_MATVEC_ROWS_SHIFT);
}

static inline uint32_t bonsai_accel_attention_heads_dim(
    uint8_t heads, uint8_t kv_heads, uint16_t head_dim) {
  return ((uint32_t)heads << BONSAI_ATTN_HEADS_SHIFT) |
         ((uint32_t)kv_heads << BONSAI_ATTN_KV_HEADS_SHIFT) |
         ((uint32_t)head_dim << BONSAI_ATTN_HEAD_DIM_SHIFT);
}

static inline uint32_t bonsai_accel_attention_context(
    uint16_t context_length, uint16_t append_position) {
  return ((uint32_t)context_length << BONSAI_ATTN_CONTEXT_LENGTH_SHIFT) |
         ((uint32_t)append_position << BONSAI_ATTN_APPEND_POSITION_SHIFT);
}

static inline enum bonsai_accel_error bonsai_accel_status_error(uint32_t status) {
  return (enum bonsai_accel_error)
      ((status & BONSAI_STATUS_ERROR_CODE_MASK) >> BONSAI_STATUS_ERROR_CODE_SHIFT);
}

#endif

#ifndef Q1_MATVEC_FIXTURE_H
#define Q1_MATVEC_FIXTURE_H

#include <stdint.h>

#include "../bonsai_accel.h"

// One complete Q1_0 x Q8_0 work unit: one row, one 128-element Q1 group.
#define Q1_FIXTURE_ROWS 1u
#define Q1_FIXTURE_GROUPS 1u
#define Q1_FIXTURE_WEIGHT_SCALE_FP16 UINT16_C(0x3c00) // 1.0
#define Q1_FIXTURE_Q8_SCALE_Q16 INT32_C(256)
#define Q1_FIXTURE_SIGN_WORD UINT32_C(0xaaaaaaaa)

static inline int8_t q1_fixture_q8_lane(unsigned int block,
                                        unsigned int lane) {
  return (int8_t)((int32_t)(block * BONSAI_Q8_BLOCK_ELEMENTS + lane) - 64);
}

static inline uint32_t q1_fixture_q8_word(unsigned int block,
                                          unsigned int word) {
  if (word == 0) {
    return (uint32_t)Q1_FIXTURE_Q8_SCALE_Q16;
  }

  const unsigned int first_lane = (word - 1u) * 4u;
  uint32_t packed = 0;
  for (unsigned int byte = 0; byte < 4u; ++byte) {
    packed |= (uint32_t)(uint8_t)q1_fixture_q8_lane(block, first_lane + byte)
              << (byte * 8u);
  }
  return packed;
}

static inline uint32_t q1_fixture_q1_word(unsigned int word) {
  return word == 0 ? (uint32_t)Q1_FIXTURE_WEIGHT_SCALE_FP16
                   : Q1_FIXTURE_SIGN_WORD;
}

static inline int32_t q1_fixture_fp16_to_q8(uint16_t h) {
  const int32_t sign = (h & 0x8000u) ? -1 : 1;
  int32_t exponent = (int32_t)((h >> 10) & 0x1fu);
  int32_t mantissa = (int32_t)(h & 0x03ffu);
  int32_t value_q8;

  if (exponent == 0) {
    value_q8 = mantissa == 0 ? 0 : ((mantissa * 256) >> 24);
  } else if (exponent == 31) {
    value_q8 = 0;
  } else {
    mantissa |= 0x0400;
    exponent -= 15;
    value_q8 = mantissa * 256;
    value_q8 = exponent >= 10 ? value_q8 << (exponent - 10)
                              : value_q8 >> (10 - exponent);
  }
  return sign * value_q8;
}

static inline int16_t q1_fixture_reference_result(void) {
  int64_t accumulator = 0;
  const int32_t weight_scale_q8 =
      q1_fixture_fp16_to_q8(Q1_FIXTURE_WEIGHT_SCALE_FP16);

  for (unsigned int block = 0; block < BONSAI_Q8_BLOCKS_PER_Q1; ++block) {
    int32_t integer_sum = 0;
    for (unsigned int lane = 0; lane < BONSAI_Q8_BLOCK_ELEMENTS; ++lane) {
      const unsigned int element = block * BONSAI_Q8_BLOCK_ELEMENTS + lane;
      const int32_t value = q1_fixture_q8_lane(block, lane);
      integer_sum += ((Q1_FIXTURE_SIGN_WORD >> (element & 31u)) & 1u)
                         ? value
                         : -value;
    }
    accumulator += ((int64_t)weight_scale_q8 * Q1_FIXTURE_Q8_SCALE_Q16 *
                    integer_sum) >> 16;
  }

  if (accumulator > 32767) return 32767;
  if (accumulator < -32768) return -32768;
  return (int16_t)accumulator;
}

static inline uint32_t q1_fixture_rotate_xor(uint32_t checksum,
                                             uint32_t word) {
  return ((checksum << 1) | (checksum >> 31)) ^ word;
}

static inline uint32_t q1_fixture_transport_checksum(void) {
  uint32_t checksum = 0;
  for (unsigned int block = 0; block < BONSAI_Q8_BLOCKS_PER_Q1; ++block) {
    for (unsigned int word = 0; word < BONSAI_Q8_BLOCK_WORDS; ++word) {
      checksum = q1_fixture_rotate_xor(checksum,
                                       q1_fixture_q8_word(block, word));
    }
  }
  for (unsigned int word = 0; word < BONSAI_Q1_GROUP_WORDS; ++word) {
    checksum = q1_fixture_rotate_xor(checksum, q1_fixture_q1_word(word));
  }
  return checksum;
}

#endif

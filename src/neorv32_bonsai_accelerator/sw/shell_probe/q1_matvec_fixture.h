#ifndef Q1_MATVEC_FIXTURE_H
#define Q1_MATVEC_FIXTURE_H

#include <stdint.h>

#include "../bonsai_accel.h"

// One complete Q1_0 x Q8_0 work unit: one row, one 128-element Q1 group.
#define Q1_FIXTURE_ROWS 1u
#define Q1_FIXTURE_GROUPS 1u
#define Q1_FIXTURE_BONSAI_GROUPS 16u
#define Q1_FIXTURE_MULTI_ROWS 3u
#define Q1_FIXTURE_MULTI_GROUPS 2u
#define Q1_FIXTURE_WEIGHT_SCALE_FP16 UINT16_C(0x3c00) // 1.0
#define Q1_FIXTURE_HALF_WEIGHT_SCALE_FP16 UINT16_C(0x3800) // 0.5
#define Q1_FIXTURE_Q8_SCALE_Q16 INT32_C(256)
#define Q1_FIXTURE_DOUBLE_Q8_SCALE_Q16 INT32_C(512)
#define Q1_FIXTURE_SATURATING_Q8_SCALE_Q16 INT32_C(262144)
#define Q1_FIXTURE_SIGN_WORD UINT32_C(0xaaaaaaaa)
#define Q1_FIXTURE_INVERTED_SIGN_WORD UINT32_C(0x55555555)

static inline int8_t q1_fixture_q8_lane(unsigned int block,
                                        unsigned int lane) {
  return (int8_t)((int32_t)(block * BONSAI_Q8_BLOCK_ELEMENTS + lane) - 64);
}

static inline uint32_t q1_fixture_q8_word(unsigned int block,
                                          unsigned int word,
                                          int32_t scale_q16) {
  if (word == 0) {
    return (uint32_t)scale_q16;
  }

  const unsigned int first_lane = (word - 1u) * 4u;
  uint32_t packed = 0;
  for (unsigned int byte = 0; byte < 4u; ++byte) {
    packed |= (uint32_t)(uint8_t)q1_fixture_q8_lane(block, first_lane + byte)
              << (byte * 8u);
  }
  return packed;
}

static inline uint32_t q1_fixture_q1_word(unsigned int word,
                                          uint16_t weight_scale_fp16,
                                          uint32_t sign_word) {
  return word == 0 ? (uint32_t)weight_scale_fp16 : sign_word;
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

static inline int16_t q1_fixture_reference_result(uint16_t weight_scale_fp16,
                                                   int32_t q8_scale_q16,
                                                   uint32_t sign_word) {
  int64_t accumulator = 0;
  const int32_t weight_scale_q8 =
      q1_fixture_fp16_to_q8(weight_scale_fp16);

  for (unsigned int block = 0; block < BONSAI_Q8_BLOCKS_PER_Q1; ++block) {
    int32_t integer_sum = 0;
    for (unsigned int lane = 0; lane < BONSAI_Q8_BLOCK_ELEMENTS; ++lane) {
      const unsigned int element = block * BONSAI_Q8_BLOCK_ELEMENTS + lane;
      const int32_t value = q1_fixture_q8_lane(block, lane);
      integer_sum += ((sign_word >> (element & 31u)) & 1u)
                         ? value
                         : -value;
    }
    accumulator += ((int64_t)weight_scale_q8 * q8_scale_q16 *
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

static inline uint32_t q1_fixture_transport_checksum(uint16_t weight_scale_fp16,
                                                      int32_t q8_scale_q16,
                                                      uint32_t sign_word) {
  uint32_t checksum = 0;
  for (unsigned int block = 0; block < BONSAI_Q8_BLOCKS_PER_Q1; ++block) {
    for (unsigned int word = 0; word < BONSAI_Q8_BLOCK_WORDS; ++word) {
      checksum = q1_fixture_rotate_xor(checksum,
          q1_fixture_q8_word(block, word, q8_scale_q16));
    }
  }
  for (unsigned int word = 0; word < BONSAI_Q1_GROUP_WORDS; ++word) {
    checksum = q1_fixture_rotate_xor(
        checksum, q1_fixture_q1_word(word, weight_scale_fp16, sign_word));
  }
  return checksum;
}

static inline int8_t q1_fixture_bonsai_q8_lane(unsigned int group,
                                                unsigned int block,
                                                unsigned int lane) {
  const unsigned int element = block * BONSAI_Q8_BLOCK_ELEMENTS + lane;
  return (int8_t)((int32_t)((group * 29u + element * 17u + 5u) & 255u) - 128);
}

static inline int32_t q1_fixture_bonsai_q8_scale(unsigned int group,
                                                  unsigned int block) {
  return (int32_t)(192u + ((group * 13u + block * 17u) & 127u));
}

static inline uint16_t q1_fixture_bonsai_weight_scale(unsigned int row,
                                                       unsigned int group) {
  static const uint16_t scales[4] = {
      UINT16_C(0x3400), UINT16_C(0x3800),
      UINT16_C(0x3c00), UINT16_C(0x4000)}; // 0.25, 0.5, 1.0, 2.0
  return scales[(row * 3u + group) & 3u];
}

static inline uint32_t q1_fixture_bonsai_sign_word(unsigned int row,
                                                    unsigned int group,
                                                    unsigned int word) {
  return UINT32_C(0xa5a5a5a5) ^
         (UINT32_C(0x7f4a7c15) * (row + 1u)) ^
         (UINT32_C(0x9e3779b9) * (group + 1u)) ^
         (UINT32_C(0x3c6ef372) * (word + 1u));
}

static inline uint32_t q1_fixture_bonsai_q8_word(unsigned int tile,
                                                  unsigned int word) {
  const unsigned int group = tile / BONSAI_Q8_BLOCKS_PER_Q1;
  const unsigned int block = tile % BONSAI_Q8_BLOCKS_PER_Q1;
  if (word == 0) {
    return (uint32_t)q1_fixture_bonsai_q8_scale(group, block);
  }

  const unsigned int first_lane = (word - 1u) * 4u;
  uint32_t packed = 0;
  for (unsigned int byte = 0; byte < 4u; ++byte) {
    packed |= (uint32_t)(uint8_t)q1_fixture_bonsai_q8_lane(
                  group, block, first_lane + byte) << (byte * 8u);
  }
  return packed;
}

static inline uint32_t q1_fixture_bonsai_q1_word(unsigned int row,
                                                  unsigned int group,
                                                  unsigned int word) {
  return word == 0 ? (uint32_t)q1_fixture_bonsai_weight_scale(row, group)
                   : q1_fixture_bonsai_sign_word(row, group, word - 1u);
}

static inline int16_t q1_fixture_bonsai_reference_result(unsigned int row,
                                                          unsigned int groups) {
  int64_t accumulator = 0;
  for (unsigned int group = 0; group < groups; ++group) {
    const int32_t weight_scale_q8 =
        q1_fixture_fp16_to_q8(q1_fixture_bonsai_weight_scale(row, group));
    for (unsigned int block = 0; block < BONSAI_Q8_BLOCKS_PER_Q1; ++block) {
      int32_t integer_sum = 0;
      const uint32_t signs = q1_fixture_bonsai_sign_word(row, group, block);
      for (unsigned int lane = 0; lane < BONSAI_Q8_BLOCK_ELEMENTS; ++lane) {
        const int32_t value = q1_fixture_bonsai_q8_lane(group, block, lane);
        integer_sum += ((signs >> lane) & 1u) ? value : -value;
      }
      accumulator += ((int64_t)weight_scale_q8 *
                      q1_fixture_bonsai_q8_scale(group, block) *
                      integer_sum) >> 16;
    }
  }

  if (accumulator > 32767) return 32767;
  if (accumulator < -32768) return -32768;
  return (int16_t)accumulator;
}

#endif

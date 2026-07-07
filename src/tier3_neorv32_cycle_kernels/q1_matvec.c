#include "tier3_common.h"

#include <stdio.h>

#ifndef Q1_ROWS
#define Q1_ROWS BONSAI_HIDDEN
#endif

#ifndef Q1_COLS
#define Q1_COLS BONSAI_HIDDEN
#endif

static int16_t x[Q1_COLS];
static int16_t y[Q1_ROWS];

static void init_input(void) {
  for (uint32_t i = 0; i < Q1_COLS; i++) {
    x[i] = t3_input_value(i);
  }
}

static void q1_matvec_naive(void) {
  for (uint32_t row = 0; row < Q1_ROWS; row++) {
    y[row] = t3_clamp_i16(t3_q1_dot_generated(x, row, Q1_COLS, 17u) >> 4);
  }
}

int main(void) {
  init_input();

  const uint64_t start = t3_cycle_counter();
  q1_matvec_naive();
  const uint64_t end = t3_cycle_counter();

  const uint64_t dot_elements = (uint64_t)Q1_ROWS * (uint64_t)Q1_COLS;
  const uint64_t groups = dot_elements / BONSAI_Q1_GROUP;

  printf("kernel=q1_matvec\n");
  printf("counter_unit=%s\n", t3_counter_unit());
  printf("rows=%u\n", (unsigned)Q1_ROWS);
  printf("cols=%u\n", (unsigned)Q1_COLS);
  printf("q1_group=%u\n", (unsigned)BONSAI_Q1_GROUP);
  printf("dot_elements=%llu\n", (unsigned long long)dot_elements);
  printf("q1_groups=%llu\n", (unsigned long long)groups);
  printf("cycles=%llu\n", (unsigned long long)(end - start));
  printf("checksum=%d\n", (int)t3_checksum_i16(y, Q1_ROWS));
  return 0;
}

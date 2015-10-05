#ifndef C63_DSP_H_
#define C63_DSP_H_

#define ISQRT2 0.70710678118654f

#include <inttypes.h>

__device__ void dct_quant_block_8x8(int16_t *in_data, int16_t *out_data, int quant_index, int block_offset, int i, int j);

__device__ void dequant_idct_block_8x8(int16_t *in_data, int16_t *out_data, int quant_index, int block_offset, int i, int j);

void sad_block_8x8(uint8_t *block1, uint8_t *block2, int stride, int *result);

#endif  /* C63_DSP_H_ */

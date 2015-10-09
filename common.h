#ifndef C63_COMMON_H_
#define C63_COMMON_H_

#include <inttypes.h>

#include "c63.h"

// Declarations
struct frame* create_frame(struct c63_common *cm);

yuv_t* create_image(struct c63_common *cm);

yuv_t* create_image_gpu(struct c63_common *cm);

__global__
void dct_quantize(uint8_t *in_data, uint8_t *prediction, int w, int16_t *out_data, int quantization);

__global__
void dequantize_idct(int16_t *in_data, uint8_t *prediction, int w, uint8_t *out_data, int quantization);

void destroy_frame(struct frame *f);

void destroy_image(yuv_t* image);

void destroy_image_gpu(yuv_t* image);

void dump_image(yuv_t *image, int w, int h, FILE *fp);

void cuda_init(struct c63_common cm);
void cuda_cleanup();

#endif  /* C63_COMMON_H_ */

extern "C" {
#include <assert.h>
#include <errno.h>
#include <getopt.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "c63.h"
#include "c63_write.h"
#include "tables.h"
}

#include "common.h"
#include "me.h"
#include "dsp.h"


static char *output_file, *input_file;
FILE *outfile;

static int limit_numframes = 0;

static uint32_t width;
static uint32_t height;

/* getopt */
extern int optind;
extern char *optarg;

// Get CPU cycle count
uint64_t rdtsc(){
    unsigned int lo,hi;
    __asm__ __volatile__ ("rdtsc" : "=a" (lo), "=d" (hi));
    return ((uint64_t)hi << 32) | lo;
}

/* Read planar YUV frames with 4:2:0 chroma sub-sampling */
static yuv_t* read_yuv(FILE *file, struct c63_common *cm)
{
  size_t len = 0;
  yuv_t *image = (yuv_t*) malloc(sizeof(*image));

  /* Read Y. The size of Y is the same as the size of the image. The indices
     represents the color component (0 is Y, 1 is U, and 2 is V) */
  image->Y = (uint8_t*) calloc(1, cm->padw[Y_COMPONENT]*cm->padh[Y_COMPONENT]);
  len += fread(image->Y, 1, width*height, file);

  /* Read U. Given 4:2:0 chroma sub-sampling, the size is 1/4 of Y
     because (height/2)*(width/2) = (height*width)/4. */
  image->U = (uint8_t*) calloc(1, cm->padw[U_COMPONENT]*cm->padh[U_COMPONENT]);
  len += fread(image->U, 1, (width*height)/4, file);

  /* Read V. Given 4:2:0 chroma sub-sampling, the size is 1/4 of Y. */
  image->V = (uint8_t*) calloc(1, cm->padw[V_COMPONENT]*cm->padh[V_COMPONENT]);
  len += fread(image->V, 1, (width*height)/4, file);

  if (ferror(file))
  {
    perror("ferror");
    exit(EXIT_FAILURE);
  }

  if (feof(file))
  {
    free(image->Y);
    free(image->U);
    free(image->V);
    free(image);

    return NULL;
  }
  else if (len != width*height*1.5)
  {
    fprintf(stderr, "Reached end of file, but incorrect bytes read.\n");
    fprintf(stderr, "Wrong input? (height: %d width: %d)\n", height, width);

    free(image->Y);
    free(image->U);
    free(image->V);
    free(image);

    return NULL;
  }

  return image;
}

int16_t *gpu_Y_16;
uint8_t *gpu_Y_8;
uint8_t *gpu_Y_pred;

int16_t *gpu_U_16;
uint8_t *gpu_U_8;
uint8_t *gpu_U_pred;

int16_t *gpu_V_16;
uint8_t *gpu_V_8;
uint8_t *gpu_V_pred;


void cuda_c63init(int width, int height){
	cudaMalloc(&gpu_Y_16, width*height*sizeof(int16_t));
	cudaMalloc(&gpu_Y_8, width*height*sizeof(uint8_t));
	cudaMalloc(&gpu_Y_pred, width*height*sizeof(uint8_t));


	cudaMalloc(&gpu_U_16, width*height*sizeof(int16_t));
	cudaMalloc(&gpu_U_8, width*height*sizeof(uint8_t));
	cudaMalloc(&gpu_U_pred, width*height*sizeof(uint8_t));


	cudaMalloc(&gpu_V_16, width*height*sizeof(int16_t));
	cudaMalloc(&gpu_V_8, width*height*sizeof(uint8_t));
	cudaMalloc(&gpu_V_pred, width*height*sizeof(uint8_t));
}

void cuda_c63cleanup() {
	cudaFree(gpu_Y_16);
	cudaFree(gpu_Y_8);
	cudaFree(gpu_Y_pred);

	cudaFree(gpu_U_16);
	cudaFree(gpu_U_8);
	cudaFree(gpu_U_pred);

	cudaFree(gpu_V_16);
	cudaFree(gpu_V_8);
	cudaFree(gpu_V_pred);
}

static void c63_encode_image(struct c63_common *cm, yuv_t *image)
{
  /* Advance to next frame */
  destroy_frame(cm->refframe);
  cm->refframe = cm->curframe;
  cm->curframe = create_frame(cm, image);

  /* Check if keyframe */
  if (cm->framenum == 0 || cm->frames_since_keyframe == cm->keyframe_interval)
  {
    cm->curframe->keyframe = 1;
    cm->frames_since_keyframe = 0;

    fprintf(stderr, " (keyframe) ");
  }
  else { cm->curframe->keyframe = 0; }

  if (!cm->curframe->keyframe)
  {
    /* Motion Estimation */
    c63_motion_estimate(cm);

    /* Motion Compensation */
    c63_motion_compensate(cm);
  }

  /* DCT and Quantization */
  cudaMemcpy(gpu_Y_pred, cm->curframe->predicted->Y, cm->padw[Y_COMPONENT]*cm->padh[Y_COMPONENT]*sizeof(uint8_t), cudaMemcpyHostToDevice);
  cudaMemcpy(gpu_U_pred, cm->curframe->predicted->U, cm->padw[U_COMPONENT]*cm->padh[U_COMPONENT]*sizeof(uint8_t), cudaMemcpyHostToDevice);
  cudaMemcpy(gpu_V_pred, cm->curframe->predicted->V, cm->padw[V_COMPONENT]*cm->padh[V_COMPONENT]*sizeof(uint8_t), cudaMemcpyHostToDevice);

  cudaMemcpy(gpu_Y_8, image->Y, cm->padw[Y_COMPONENT]*cm->padh[Y_COMPONENT]*sizeof(uint8_t), cudaMemcpyHostToDevice);
  cudaMemcpy(gpu_U_8, image->U, cm->padw[U_COMPONENT]*cm->padh[U_COMPONENT]*sizeof(uint8_t), cudaMemcpyHostToDevice);
  cudaMemcpy(gpu_V_8, image->V, cm->padw[V_COMPONENT]*cm->padh[V_COMPONENT]*sizeof(uint8_t), cudaMemcpyHostToDevice);

  dct_quantize(gpu_Y_8, gpu_Y_pred, cm->padw[Y_COMPONENT],
      cm->padh[Y_COMPONENT], cm->curframe->residuals->Ydct,
      Y_COMPONENT);

  dct_quantize(gpu_U_8, gpu_U_pred, cm->padw[U_COMPONENT],
      cm->padh[U_COMPONENT], cm->curframe->residuals->Udct,
      U_COMPONENT);

  dct_quantize(gpu_V_8, gpu_V_pred, cm->padw[V_COMPONENT],
      cm->padh[V_COMPONENT], cm->curframe->residuals->Vdct,
      V_COMPONENT);

  cudaMemcpy(gpu_Y_16, cm->curframe->residuals->Ydct, cm->padw[Y_COMPONENT]*cm->padh[Y_COMPONENT]*sizeof(int16_t), cudaMemcpyHostToDevice);
  cudaMemcpy(gpu_U_16, cm->curframe->residuals->Udct, cm->padw[U_COMPONENT]*cm->padh[U_COMPONENT]*sizeof(int16_t), cudaMemcpyHostToDevice);
  cudaMemcpy(gpu_V_16, cm->curframe->residuals->Vdct, cm->padw[V_COMPONENT]*cm->padh[V_COMPONENT]*sizeof(int16_t), cudaMemcpyHostToDevice);


  /* Reconstruct frame for inter-prediction */
  dequantize_idct(gpu_Y_16, gpu_Y_pred,
      cm->ypw, cm->yph, cm->curframe->recons->Y, Y_COMPONENT);
  dequantize_idct(gpu_U_16, gpu_U_pred,
      cm->upw, cm->uph, cm->curframe->recons->U, U_COMPONENT);
  dequantize_idct(gpu_V_16, gpu_V_pred,
      cm->vpw, cm->vph, cm->curframe->recons->V, V_COMPONENT);

  /* Function dump_image(), found in common.c, can be used here to check if the
     prediction is correct */

  write_frame(cm);

  ++cm->framenum;
  ++cm->frames_since_keyframe;
}

struct c63_common* init_c63_enc(int width, int height)
{
  int i;

  /* calloc() sets allocated memory to zero */
  struct c63_common *cm = (c63_common*) calloc(1, sizeof(struct c63_common));

  cm->width = width;
  cm->height = height;

  cm->padw[Y_COMPONENT] = cm->ypw = (uint32_t)(ceil(width/16.0f)*16);
  cm->padh[Y_COMPONENT] = cm->yph = (uint32_t)(ceil(height/16.0f)*16);
  cm->padw[U_COMPONENT] = cm->upw = (uint32_t)(ceil(width*UX/(YX*8.0f))*8);
  cm->padh[U_COMPONENT] = cm->uph = (uint32_t)(ceil(height*UY/(YY*8.0f))*8);
  cm->padw[V_COMPONENT] = cm->vpw = (uint32_t)(ceil(width*VX/(YX*8.0f))*8);
  cm->padh[V_COMPONENT] = cm->vph = (uint32_t)(ceil(height*VY/(YY*8.0f))*8);

  cm->mb_cols = cm->ypw / 8;
  cm->mb_rows = cm->yph / 8;

  /* Quality parameters -- Home exam deliveries should have original values,
   i.e., quantization factor should be 25, search range should be 16, and the
   keyframe interval should be 100. */
  cm->qp = 25;                  // Constant quantization factor. Range: [1..50]
  cm->me_search_range = 16;     // Pixels in every direction
  cm->keyframe_interval = 100;  // Distance between keyframes

  /* Initialize quantization tables */
  for (i = 0; i < 64; ++i)
  {
    cm->quanttbl[Y_COMPONENT][i] = yquanttbl_def[i] / (cm->qp / 10.0);
    cm->quanttbl[U_COMPONENT][i] = uvquanttbl_def[i] / (cm->qp / 10.0);
    cm->quanttbl[V_COMPONENT][i] = uvquanttbl_def[i] / (cm->qp / 10.0);
  }

  cuda_init(width, height);
  cuda_c63init(width, height);

  return cm;
}

static void print_help()
{
  printf("Usage: ./c63enc [options] input_file\n");
  printf("Commandline options:\n");
  printf("  -h                             Height of images to compress\n");
  printf("  -w                             Width of images to compress\n");
  printf("  -o                             Output file (.c63)\n");
  printf("  [-f]                           Limit number of frames to encode\n");
  printf("\n");

  exit(EXIT_FAILURE);
}

int main(int argc, char **argv)
{
  int c;
  yuv_t *image;

  if (argc == 1) { print_help(); }

  while ((c = getopt(argc, argv, "h:w:o:f:i:")) != -1)
  {
    switch (c)
    {
      case 'h':
        height = atoi(optarg);
        break;
      case 'w':
        width = atoi(optarg);
        break;
      case 'o':
        output_file = optarg;
        break;
      case 'f':
        limit_numframes = atoi(optarg);
        break;
      default:
        print_help();
        break;
    }
  }

  if (optind >= argc)
  {
    fprintf(stderr, "Error getting program options, try --help.\n");
    exit(EXIT_FAILURE);
  }

  outfile = fopen(output_file, "wb");

  if (outfile == NULL)
  {
    perror("fopen");
    exit(EXIT_FAILURE);
  }

  struct c63_common *cm = init_c63_enc(width, height);
  cm->e_ctx.fp = outfile;

  input_file = argv[optind];

  if (limit_numframes) { printf("Limited to %d frames.\n", limit_numframes); }

  FILE *infile = fopen(input_file, "rb");

  if (infile == NULL)
  {
    perror("fopen");
    exit(EXIT_FAILURE);
  }

  /* Encode input frames */
  int numframes = 0;

# ifdef SHOW_CYCLES
  uint64_t kCycleCountTotal = 0;
# endif

  while (1)
  {
    image = read_yuv(infile, cm);

    if (!image) { break; }

    printf("Encoding frame %d, ", numframes);

# ifdef SHOW_CYCLES
    uint64_t cycleCountBefore = rdtsc();
    c63_encode_image(cm, image);
    uint64_t cycleCountAfter = rdtsc();

    uint64_t kCycleCount = (cycleCountAfter - cycleCountBefore)/1000;
    kCycleCountTotal += kCycleCount;
    printf("%" PRIu64 "k cycles, ", kCycleCount);
# else
    c63_encode_image(cm, image);
# endif

    free(image->Y);
    free(image->U);
    free(image->V);
    free(image);

    printf("Done!\n");

    ++numframes;

    if (limit_numframes && numframes >= limit_numframes) { break; }
  }

# ifdef SHOW_CYCLES
  printf("-----------\n");
  printf("Average CPU cycle count per frame: %" PRIu64 "k\n", kCycleCountTotal/numframes);
# endif

  fclose(outfile);
  fclose(infile);
  
  cuda_cleanup();
  cuda_c63cleanup();
  cudaDeviceReset();

  return EXIT_SUCCESS;
}

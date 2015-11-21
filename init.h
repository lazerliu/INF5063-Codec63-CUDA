#ifndef INIT_H_
#define INIT_H_

#include "c63.h"
#include "c63_cuda.h"

struct c63_common* init_c63_enc(int width, int height, const struct c63_cuda& c63_cuda);
void free_c63_enc(struct c63_common* cm);

#endif /* INIT_H_ */

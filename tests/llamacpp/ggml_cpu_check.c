/* A small check of ggml's public API on the CPU backend: C = mul_mat(A, B) + mul_mat(A, B), computed by
   ggml_graph_compute_with_ctx and compared with the hand-computed result. Exit status = failed checks.
   A: [K=3, N=2] = {1,2,3, 4,5,6}; B: [K=3, M=2] = {1,0,1, 0,1,1}; C[m][n] = sum_k A[n][k] * B[m][k] = {4,10, 5,11};
   the output is C + C = {8,20, 10,22}. */
#include "ggml.h"
#include "ggml-cpu.h"
#include <stdio.h>

int main(void) {
  struct ggml_init_params params = { .mem_size = 16 * 1024 * 1024, .mem_buffer = NULL, .no_alloc = false };
  struct ggml_context *ctx = ggml_init(params);
  if (!ctx) { fprintf(stderr, "ggml_init failed\n"); return 2; }

  struct ggml_tensor *A = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, 3, 2);
  struct ggml_tensor *B = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, 3, 2);
  static const float a[] = {1, 2, 3, 4, 5, 6}, b[] = {1, 0, 1, 0, 1, 1};
  for (int i = 0; i < 6; i++) { ((float *)A->data)[i] = a[i]; ((float *)B->data)[i] = b[i]; }

  struct ggml_tensor *c = ggml_mul_mat(ctx, A, B);
  struct ggml_tensor *out = ggml_add(ctx, c, c);
  struct ggml_cgraph *gf = ggml_new_graph(ctx);
  ggml_build_forward_expand(gf, out);
  enum ggml_status st = ggml_graph_compute_with_ctx(ctx, gf, 1);

  static const float want[] = {8, 20, 10, 22};
  int fails = 0;
  if (st != GGML_STATUS_SUCCESS) { fprintf(stderr, "graph compute status %d\n", (int)st); fails++; }
  for (int i = 0; i < 4; i++) {
    float got = ((float *)out->data)[i];
    if (got != want[i]) { fprintf(stderr, "out[%d] = %g, want %g\n", i, got, want[i]); fails++; }
  }
  printf("ggml cpu: %d checks failed\n", fails);
  ggml_free(ctx);
  return fails != 0;
}

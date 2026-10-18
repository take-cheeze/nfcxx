# test-backend-ops coverage for the ggml-sycl backend

Read-only inventory. No test was run. Upstream sources: `/home/takecheeze/dev/llm/llama.cpp` (read only).
`tests/test-backend-ops.cpp` defines 133 `struct test_*` (test_result, test_operation_info and test_summary_info are reporting types,
test_case is the base, so 129 are cases). Test rows below are grouped by the ggml op each case exercises, attributed to its first op.
The sycl column is `ggml/src/ggml-sycl/ggml-sycl.cpp` `do_ggml_backend_sycl_device_supports_op` (line 6673; the wrapper is at 7098). Its default is false.

Classes: covered-real = a real upstream `.cpp` is built and run on main; covered-copy = a verified verbatim copy of the kernel is run;
not-started = sycl `supports_op` is true and no test on main runs the op (a real test that does not run counts as not-started); no-sycl-kernel = `supports_op` is false.

Counts use the static `new test_*(` sites in `make_test_cases_eval()` (lines 9583 to 11936). Loops in that function expand each site into several cases, so case totals are larger; the expansion is not computed here. Perf-mode sites (`make_test_cases_perf`, 200 sites) are shown separately.

## Summary

| Class | Ops (rows) | Eval sites of their structs |
| --- | ---: | ---: |
| covered-real | 36 | 348 |
| covered-copy | 2 | 17 |
| not-started | 66 | 694 |
| no-sycl-kernel | 2 | 4 |

Caveats on the covered rows: `mul_mat`, `rope`, `cpy`, `soft_max` and `get_rows` are partial (see the notes column). `rms_norm` has a real test on main, but commit #414 says it is blocked at the front end, so it is counted as not-started.
The stale `docs/notes/ggml-sycl.md` says 0 of 133 cases and that `element_wise.cpp` is blocked; later commits on main (#406, #414, #433, #438, #439) supersede that, and the table follows main.

## Top 10 not-started ops by blocked cases

Blocked cases = eval sites of the structs attributed to the op. Fused structs count once, under their first op.

| Rank | ggml op | Blocked (eval sites) | Structs |
| ---: | --- | ---: | --- |
| 1 | FLASH_ATTN_EXT | 89 | test_flash_attn_ext, test_flash_attn_ext_large_logits |
| 2 | TOP_K | 49 | test_top_k, test_top_k_inf, test_topk_qsa, test_topk_moe |
| 3 | MUL_MAT_ID | 42 | test_mul_mat_id, test_mul_mat_id_fusion, test_mul_mat_id_shared, test_mul_mat_id_w4a8, test_mul_mat_id_w4a4 |
| 4 | GATED_DELTA_NET | 41 | test_gated_delta_net, test_gated_delta_net_cache_fusion |
| 5 | RMS_NORM | 33 | test_rms_norm, test_rms_norm_mul_add, test_rms_norm_mul_rope, test_add_rms_norm |
| 6 | IM2COL | 30 | test_im2col |
| 7 | SSM_SCAN | 25 | test_ssm_scan, test_ssm_scan_rollback, test_ssm_scan_cache_fusion |
| 8 | SOLVE_TRI | 24 | test_solve_tri |
| 9 | UNARY x MUL (fused) | 23 | test_unary_mul, test_add_unary_mul |
| 10 | PAD | 22 | test_pad, test_pad_ext |

## Inventory

| # | ggml op | sycl supports_op | class | repo test(s) on main | test-backend-ops struct(s) | eval sites | perf sites | notes |
| ---: | --- | --- | --- | --- | --- | ---: | ---: | --- |
| 1 | UNARY ABS | yes | covered-real | elementwise/abs | (shared, see note) | 0 | 0 |  |
| 2 | UNARY SGN | yes | covered-real | elementwise/sgn | (shared, see note) | 0 | 0 |  |
| 3 | UNARY NEG | yes | covered-real | unary_real (and unary/ copy) | (shared, see note) | 0 | 0 | real element_wise.cpp; unary_real per #406 runs F16/BF16 too |
| 4 | UNARY STEP | yes | covered-real | elementwise/step | (shared, see note) | 0 | 0 |  |
| 5 | UNARY TANH | yes | covered-real | elementwise/tanh | test_softcap | 1 | 0 | test_softcap (SCALE+TANH) is fused; the TANH op itself is covered |
| 6 | UNARY ELU | yes | covered-real | elementwise/elu | (shared, see note) | 0 | 0 |  |
| 7 | UNARY RELU | yes | covered-real | unary_real (and unary/ copy) | (shared, see note) | 0 | 0 | test_relu_sqr fuses RELU+SQR, see SQR |
| 8 | UNARY SIGMOID | yes | covered-real | elementwise/sigmoid | (shared, see note) | 0 | 0 | test_dsv4_hc_post also uses sigmoid |
| 9 | UNARY GELU | yes | covered-real | unary_real (and unary/ copy) | (shared, see note) | 0 | 0 | GELU as ggml_sycl_op_gelu |
| 10 | UNARY GELU_QUICK | yes | covered-real | elementwise/gelu_quick | (shared, see note) | 0 | 0 |  |
| 11 | UNARY SILU | yes | covered-real | unary_real (and unary/ copy) | (shared, see note) | 0 | 0 | SILU as ggml_sycl_op_silu |
| 12 | UNARY HARDSWISH | yes | covered-real | elementwise/hardswish | (shared, see note) | 0 | 0 |  |
| 13 | UNARY HARDSIGMOID | yes | covered-real | elementwise/hardsigmoid | (shared, see note) | 0 | 0 |  |
| 14 | UNARY EXP | yes | covered-real | elementwise/exp | (shared, see note) | 0 | 0 |  |
| 15 | UNARY EXPM1 | yes | covered-real | elementwise/expm1 | (shared, see note) | 0 | 0 | upstream #439 lowers expm1 to OpenCL.std (this repo) |
| 16 | UNARY SOFTPLUS | yes | covered-real | elementwise/softplus | (shared, see note) | 0 | 0 |  |
| 17 | UNARY GELU_ERF | yes | covered-real | elementwise/gelu_erf | (shared, see note) | 0 | 0 | upstream #439 lowers erf to OpenCL.std (this repo) |
| 18 | UNARY FLOOR | yes | covered-real | elementwise/floor | test_floor | 3 | 0 |  |
| 19 | UNARY CEIL | yes | covered-real | elementwise/ceil | test_ceil | 3 | 0 |  |
| 20 | UNARY ROUND | yes | covered-real | elementwise/round | test_round | 3 | 0 |  |
| 21 | UNARY TRUNC | yes | covered-real | elementwise/trunc | test_trunc | 3 | 0 |  |
| 22 | UNARY XIELU | yes | not-started | none | test_xielu | 6 | 0 | test_unary also loops over XIELU |
| 23 | CLAMP | yes | covered-real | elementwise/clamp | test_clamp | 4 | 0 |  |
| 24 | COS | yes | covered-real | elementwise/cos | test_cos | 3 | 0 |  |
| 25 | LOG | yes | covered-real | elementwise/log | test_log | 3 | 0 |  |
| 26 | SIN | yes | covered-real | elementwise/sin | test_sin, test_snake_fuse | 11 | 3 | test_snake_fuse (SIN+SQR+ADD+MUL) is fused; not covered |
| 27 | SQR | yes | covered-real | elementwise/sqr | test_sqr, test_relu_sqr | 5 | 0 | test_relu_sqr is RELU+SQR, fused |
| 28 | SQRT | yes | covered-real | elementwise/sqrt | test_sqrt | 3 | 0 |  |
| 29 | LEAKY_RELU | yes | covered-real | elementwise/leaky_relu | test_leaky_relu | 4 | 1 |  |
| 30 | ADD (fused: add_add, moe_reduce) | yes | not-started | none | test_add_add, test_moe_reduce | 12 | 0 | ADD fused with ADD / MUL in MoE reduce |
| 31 | ADD, SUB, MUL, DIV (bin_bcast) | yes | not-started | none | test_bin_bcast | 20 | 2 | one struct, op chosen per case |
| 32 | ADD_ID | yes | not-started | none | test_add_id | 1 | 2 |  |
| 33 | UNARY x MUL (fused) | yes (per op) | not-started | none | test_unary_mul, test_add_unary_mul | 23 | 0 | fusion status in sycl not checked |
| 34 | GLU (REGLU, GEGLU, SWIGLU, GEGLU_ERF, GEGLU_QUICK) | yes (contiguous src0) | not-started | none | test_glu, test_glu_split | 4 | 2 |  |
| 35 | GLU SWIGLU_OAI | yes (contiguous src0) | not-started | none | test_swiglu_oai | 1 | 0 |  |
| 36 | GLU SWIGLU_CLAMP | yes (contiguous src0) | not-started | none | test_swiglu_clamp | 1 | 0 |  |
| 37 | GET_ROWS | yes (typed) | covered-real | get_rows, get_rows_op (real getrows.cpp; F32/F16/I32 arms) | test_get_rows | 7 | 0 | quant source types not covered |
| 38 | GET_ROWS_BACK | yes (F32) | not-started | none | test_get_rows_back | 4 | 0 |  |
| 39 | SET | yes (F32) | not-started | none | test_set | 4 | 0 |  |
| 40 | SET_ROWS | yes (conditional) | not-started | none | test_set_rows | 12 | 0 |  |
| 41 | CPY | yes (conditional) | covered-real | cpy_f32_f16 (real cpy.cpp, F32 to F16) | test_cpy | 34 | 14 | only the F32 to F16 path |
| 42 | CONT | yes | not-started | none | test_cont | 2 | 2 |  |
| 43 | DUP | yes | not-started | none | test_dup | 10 | 0 |  |
| 44 | CONCAT | yes | covered-real | concat (concat_real, real concat.cpp) | test_concat | 11 | 0 |  |
| 45 | REPEAT | yes | not-started | none | test_repeat | 9 | 0 |  |
| 46 | REPEAT_BACK | yes (F32) | not-started | none | test_repeat_back | 5 | 0 |  |
| 47 | COUNT_EQUAL | yes | not-started | none | test_count_equal | 2 | 0 |  |
| 48 | ARGMAX | yes | not-started | none | test_argmax | 7 | 3 |  |
| 49 | ARGSORT | yes | not-started | none | test_argsort | 13 | 3 |  |
| 50 | TOP_K | yes (conditional) | not-started | none | test_top_k, test_top_k_inf, test_topk_qsa, test_topk_moe | 49 | 7 | test_topk_moe is a fused MoE gate (ARGSORT/TOP_K family) |
| 51 | SCALE | yes | covered-copy | scale (scale_upstream.cpp, verbatim copies of ggml_sycl_op_scale and kernels) | test_scale | 7 | 0 |  |
| 52 | SUM | yes | not-started | none | test_sum | 8 | 1 |  |
| 53 | SUM_ROWS | yes | covered-copy | sum_rows (sum_rows_upstream.cpp, verbatim copies) | test_sum_rows | 10 | 1 |  |
| 54 | MEAN | yes | not-started | none | test_mean | 10 | 2 |  |
| 55 | NORM | yes | not-started | none | test_norm, test_norm_mul_add, test_norm_scale | 8 | 0 | norm.cpp is real but only RMS_NORM is tested |
| 56 | RMS_NORM | yes | not-started | rms_norm (real norm.cpp, blocked at the front end per #414) | test_rms_norm, test_rms_norm_mul_add, test_rms_norm_mul_rope, test_add_rms_norm | 33 | 0 | real test on main but does not run; fused structs attributed here |
| 57 | RMS_NORM_BACK | yes (contiguous) | not-started | none | test_rms_norm_back | 1 | 0 |  |
| 58 | GROUP_NORM | yes | not-started | none | test_group_norm, test_group_norm_mul_add | 4 | 0 |  |
| 59 | L2_NORM | yes | not-started | none | test_l2_norm, test_l2_norm_batch | 7 | 3 |  |
| 60 | SOFT_MAX | yes | covered-real | soft_max (real softmax.cpp, F32 with and without mask) | test_soft_max | 23 | 9 | soft_max_add_sinks and ext_inplace not covered |
| 61 | SOFT_MAX_BACK | yes (max_bias == 0) | not-started | none | test_soft_max_back | 3 | 0 |  |
| 62 | DIAG_MASK_INF | yes | not-started | none | test_diag_mask_inf | 3 | 0 |  |
| 63 | ROPE | yes | covered-real | rope (real rope.cpp, norm mode) | test_rope, test_rope_set_rows | 43 | 11 | only NORM mode; NEOX, MROPE, VISION, IMROPE not covered |
| 64 | ROPE_BACK | yes | not-started | none | (shared, see note) | 0 | 0 | rope_*_back variants are inside test_rope |
| 65 | IM2COL | yes | not-started | none | test_im2col | 30 | 1 |  |
| 66 | IM2COL_3D | yes | not-started | none | test_im2col_3d | 5 | 0 |  |
| 67 | COL2IM_1D | yes (contiguous) | not-started | none | test_col2im_1d | 11 | 3 |  |
| 68 | CONV_2D | yes | not-started | none | test_conv_2d | 10 | 2 |  |
| 69 | CONV_2D_DW | yes | not-started | none | test_conv_2d_dw | 8 | 6 |  |
| 70 | CONV_3D | yes (F32) | not-started | none | test_conv_3d | 12 | 1 |  |
| 71 | CONV_TRANSPOSE_1D | yes (conditional) | not-started | none | test_conv_transpose_1d | 9 | 0 |  |
| 72 | CONV_TRANSPOSE_2D | yes | not-started | none | test_conv_transpose_2d | 4 | 3 |  |
| 73 | CONV_1D_DW | no | no-sycl-kernel | none | test_conv_1d_dw | 3 | 0 | not in supports_op switch, default false |
| 74 | POOL_1D | yes | not-started | none | test_pool1d | 3 | 0 |  |
| 75 | POOL_2D | yes | not-started | none | test_pool2d | 2 | 1 |  |
| 76 | PAD | yes (conditional) | not-started | none | test_pad, test_pad_ext | 22 | 0 |  |
| 77 | PAD_REFLECT_1D | yes (contiguous F32) | not-started | none | test_pad_reflect_1d | 2 | 5 |  |
| 78 | UPSCALE | yes | not-started | none | test_upscale, test_interpolate | 7 | 0 |  |
| 79 | ACC | yes | not-started | none | test_acc | 6 | 6 |  |
| 80 | ROLL | yes (F32) | not-started | none | test_roll | 2 | 0 |  |
| 81 | ARANGE | yes (F32) | not-started | none | test_arange | 2 | 0 |  |
| 82 | TIMESTEP_EMBEDDING | yes | not-started | none | test_timestep_embedding | 1 | 0 |  |
| 83 | FILL | yes | covered-real | fill_real (F32) and fill_real_f16 (F16), real fill.cpp; fill_kernel is a copy | test_fill | 7 | 0 |  |
| 84 | DIAG | yes | covered-real | diag_real (real diag.cpp); diag/ is a copy | test_diag | 3 | 0 |  |
| 85 | TRI | yes | not-started | none | test_tri | 4 | 2 |  |
| 86 | CUMSUM | yes | not-started | none | test_cumsum | 15 | 4 |  |
| 87 | SOLVE_TRI | yes (size limits) | not-started | none | test_solve_tri | 24 | 5 |  |
| 88 | CROSS_ENTROPY_LOSS | yes | not-started | none | test_cross_entropy_loss | 2 | 0 |  |
| 89 | CROSS_ENTROPY_LOSS_BACK | yes | not-started | none | test_cross_entropy_loss_back | 2 | 0 |  |
| 90 | OPT_STEP_ADAMW | yes | not-started | none | test_opt_step_adamw | 1 | 0 |  |
| 91 | OPT_STEP_SGD | yes | not-started | none | test_opt_step_sgd | 1 | 0 |  |
| 92 | OUT_PROD | yes (F32) | not-started | none | test_out_prod | 3 | 0 |  |
| 93 | MUL_MAT | yes (conditional) | covered-real | mul_mat_quant (real dmmv.cpp, Q8_0 mat-vec); mul_mat_f32 (oneMKL call copy, draft #426) | test_mul_mat, test_mul_mat_hadamard, test_mul_mat_w4a8, test_mul_mat_w4a4, test_mul_mat_pos, test_mul_mat_add, test_mul_mat_vec_fusion | 174 | 23 | partial: Q8_0 mat-vec real, F32 gemm copy; other types, shapes and fused variants not covered |
| 94 | MUL_MAT_ID | yes (conditional) | not-started | none | test_mul_mat_id, test_mul_mat_id_fusion, test_mul_mat_id_shared, test_mul_mat_id_w4a8, test_mul_mat_id_w4a4 | 42 | 6 |  |
| 95 | FLASH_ATTN_EXT | yes (conditional on device and shape) | not-started | none | test_flash_attn_ext, test_flash_attn_ext_large_logits | 89 | 44 |  |
| 96 | SSM_CONV | yes (F32) | not-started | none | test_ssm_conv, test_ssm_conv_bias_silu | 10 | 5 |  |
| 97 | SSM_SCAN | yes (conditional) | not-started | none | test_ssm_scan, test_ssm_scan_rollback, test_ssm_scan_cache_fusion | 25 | 4 |  |
| 98 | RWKV_WKV6 | yes | not-started | none | test_rwkv_wkv6 | 4 | 0 |  |
| 99 | RWKV_WKV7 | yes | not-started | none | test_rwkv_wkv7 | 5 | 0 |  |
| 100 | GATED_LINEAR_ATTN | yes | not-started | none | test_gla | 4 | 0 |  |
| 101 | GATED_DELTA_NET | yes | not-started | none | test_gated_delta_net, test_gated_delta_net_cache_fusion | 41 | 12 |  |
| 102 | DSV4_HC_PRE | yes (F32) | not-started | none | test_dsv4_hc_pre | 8 | 0 |  |
| 103 | DSV4_HC_COMB | yes (F32) | not-started | none | test_dsv4_hc_comb | 5 | 0 |  |
| 104 | DSV4_HC_POST | yes (F32) | not-started | none | test_dsv4_hc_post | 9 | 0 |  |
| 105 | LIGHTNING_INDEXER | yes (F32, conditional) | not-started | none | test_lightning_indexer | 2 | 1 |  |
| 106 | SILU_BACK | no | no-sycl-kernel | none | test_silu_back | 1 | 0 | not in supports_op switch, default false |

## Cases with no row above

- `test_example`: a template, never instantiated (0 sites).
- `test_generic_op`: runs an op chosen at run time; 0 static sites.
- `test_llm`, `test_llama`, `test_falcon`: end-to-end model graphs (3 + 2 eval sites). They need most of the rows above at once and are not counted as an op.
- `test_dsv4_hc`: base class of the three DSV4_HC rows.
- `test_unary`: loops over all 23 UNARY sub-ops (2 sites), so its cases are shared across the UNARY rows.
- ADD1 is in `supports_op` but no `test_*` struct calls it.

Method: sites were counted with a regex over the two `make_test_cases_*` functions. Op attribution used each struct's `ggml_*` calls, extracted from the upstream file, mapped by hand.

# CUDA test beds

Real CUDA programs from NVIDIA `cuda-samples` and Rodinia, built through the nfcxx driver (`.cu` inputs, with
`-I` for `cuda-samples/Common`, and `-lcudart` at link). `run.sh` builds each one, runs it on the GPU, and checks its
result where the program prints one. The list is `cases.txt`; the status below is what `run.sh` reports.

Status as of this branch (CUDA 13.1, RTX 2060, gcc backend). "First error" is the first error from the driver, as
`run.sh` matches it.

| Sample | Feature | Status | First error |
| --- | --- | --- | --- |
| simpleStreams | streams, async copies, events | builds, runs, exit 0; no result check in the sample (not verified) | — |
| simpleZeroCopy | mapped host memory | builds, runs, exit 0; computes `errorNorm` but prints nothing (not verified); prelinker prints a name-decoding warning | — |
| simpleAtomicIntrinsics | atomics (`atomicAdd` and friends), `#define` in the `.cu` | fails to compile | `identifier "atomicAdd" is undefined` (device unit) |
| simpleVoteIntrinsics | warp vote (`__any_sync`) | fails to compile | `identifier "__any_sync" is undefined` (in `simpleVote_kernel.cuh`) |
| simplePrintf | device `printf` | fails to compile | `identifier "printf" is undefined` (device unit) |
| matrixMul | shared memory, template kernel launch `MatrixMulCUDA<16><<<...>>>` | fails to compile | `static data is not lowered yet` (the shared tile `As`) |
| asyncAPI | events, streams, profiler API | builds and runs, exit 0; no result check printed (not verified) | none; it needed `cuda_profiler_api.h`, installed from apt (`cuda-profiler-api-13-1`) |
| reduction | templates, template kernel launches, cooperative groups | fails to compile | `incomplete type "double []" is not allowed` (`extern __shared__` with no size, which needs the launch size) |
| shfl_scan | warp shuffle (`__shfl_up_sync`), `NULL` from the host headers | fails to compile | `namespace "cooperative_groups" has no member "tiled_partition"`: the cooperative-groups stand-in has only thread blocks |
| scan | `uint` typedef from the host headers, cooperative groups | fails to compile | `refused: aggregate type "uint4": struct and union values by value are not lowered yet` |
| histogram | `uchar`/`uint` typedefs from the host headers, shared memory | fails to compile | `refused: aggregate type "uint4": struct and union values by value are not lowered yet` |
| scalarProd | cooperative groups (`namespace cg = cooperative_groups`) | fails to compile | `refused: global "accumResult" (static data is not lowered yet)` |
| threadFenceReduction | memory fences, cooperative groups | fails to compile | `device variable` (a `__device__` global; the emitter does not lower it yet) |
| simpleCooperativeGroups | cooperative groups (`thread_block`, `thread_group`) | fails to compile | `identifier "thread_group" is undefined`: methods on groups and tiled partitions are not provided |
| MC_EstimatePiP | template kernel launch (curand is not reached) | fails to compile | `incomplete type "unsigned int []" is not allowed` (`extern __shared__` with no size) |
| Rodinia pathfinder | `__shared__` arrays | fails to compile | `static data is not lowered yet` (the shared arrays) |
| Rodinia hotspot | `__shared__` 2-D arrays | fails to compile | `static data is not lowered yet` (the shared arrays) |
| Rodinia nw | `__syncthreads` (barrier) | fails to compile | `static data is not lowered yet` (the shared arrays) |
| Rodinia gaussian | multi-kernel host loop, null-pointer checks | fails to compile | `refused: statement nonnull` (emitter) |
| Rodinia bfs | struct `Node` from a header, multi-file kernels | fails to compile | `bool in arithmetic or memory` (emitter) |

## What the failures have in common

- **The device-only unit drops the host context.** The device code is extracted into its own translation unit
  (`cuda-rewrite.rb --device`), without the `#define`s, typedefs, and includes of the host source. Nine of the
  failures are unknown names from that context (`NUM_THREADS`, `NULL`, `uint`, `uchar`, `thread_group`, the
  cooperative-groups namespace, the struct `Node`, `printf`).
- **The device compile has no CUDA qualifiers or intrinsics.** `__shared__`, `__syncthreads`, `__any_sync` and device
  `printf` are unknown there. Shared memory and barriers are the next features to lower.
- **Template kernel launches are refused by the rewriter.** Three samples use `k<T><<<...>>>` (matrixMul, reduction,
  MC_EstimatePiP). Supporting them needs the template argument list parsed in `cuda-rewrite.rb`.
- **`nonnull` statements are refused by the emitter** (gaussian). The emitter would need the null check lowered.
- **Environment:** `cuda_profiler_api.h` is not in this CUDA package. It comes from the `cuda-profiler-api` package,
  which we have not installed.

## Not covered

- Mutants: no program here prints a pass line yet, so the mutant check (a wrong kernel must make the program fail)
  has nothing to check against. `vectorAdd` has it, in `tests/gpu/device` and in the driver PR.
- `simpleTexture` (includes `<windows.h>`, not Linux), `MC_EstimatePiP` beyond its template launch, and the rest of
  cuda-samples: not yet attempted.
- qbe backend: the libcu++ headers (`<cuda/cmath>`) break it (`__builtin_fabsf`), so these runs use the gcc backend.

## Running

    CUDA_SAMPLES=build/targets/cuda-samples RODINIA=build/targets/rodinia/cuda tests/cuda/samples/run.sh

A missing source tree or toolkit is printed as `SKIP`. A recorded failure that still fails with the recorded error is
`known-fail`. If one starts to build, `run.sh` prints `NOW BUILDS` and the case must be updated.

## Device-unit additions (this round)

- **Vector types** (`uchar2`..`float4`, the `make_*` constructors): the device unit defines a type only when device code
  names it. The definitions are generated (`vector_defs` in `scripts/cuda-rewrite.rb`). The first error they reach is the
  aggregate refusal: a struct value is passed or returned by value (`sret` in the IR), which the emitter does not lower.
- **Cooperative groups** (`cg::thread_block`, `cg::this_thread_block()`, `cg::sync(group)`): the device unit provides a
  stand-in namespace. The group is a plain `unsigned`, and `sync` is `__nfcxx_syncthreads`. Methods on a group and tiled
  partitions are not provided.
- **`__mul24`**: a builtin in the device unit, defined when device code names it (`BUILTIN_DEFS`).
- **Front-end check of the stand-in with the emitter on `claude/ptx-emit-shared` (#82)**: the cooperative-groups IR
  lowers, but `ptxas` rejects the forward calls ("requires call prototype"): the `.func` for `cg::sync` is emitted after
  the kernel that calls it. That is an emitter ordering issue, not a front-end one.

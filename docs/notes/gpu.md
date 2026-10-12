# GPU: first step (hand-written IR to PTX to cubin to launch)

Status: **first step verified** on an NVIDIA GeForce RTX 2060 (sm_75, driver 595, CUDA 13.2). The emitter lowers the one kernel; the rest of the IR is not covered.

`tests/gpu/` holds one kernel in three forms:

- `mul2.ir`: the kernel as Path B IR (`docs/notes/pathb-stage2.md` form), written by hand. `(gpu T "NAME")` reads a
  special register (`tid.x`, `ctaid.x`, `ntid.x`). That form is new: stage 2 has no GPU operations yet.
- `scripts/pathb-ptx-emit.rb`: lowers `mul2.ir` to sm_75 PTX (run through `scripts/mrb`). `run.sh` tests its output, not a hand translation.
- `launch.c`: loads the cubin with the CUDA runtime API (`cudaLibraryLoadData`, `cudaLaunchKernelExC`), launches 8 blocks of 128 threads over 1000 elements, and checks
  `b[i] == 2 * a[i]` and that 64 guard ints past `b` stay zero (a missing bounds check writes there).

`tests/gpu/run.sh` runs `ptxas -arch=sm_75` on the PTX and the launcher against the cubin. It skips (exit 0) when
`ptxas`, `cuda_runtime.h`, `libcudart` or `nvidia-smi` is missing. `CUDA_HOME` is the toolkit root (default
`/usr/local/cuda`). Toolkit: Ubuntu's CUDA 13.1 packages, `sudo apt-get install cuda-nvcc-13-1 cuda-cudart-dev-13-1`
(CUDA 12.8 or later is needed for `cudaLibraryLoadData`). The driver is the system one, 595 here.

Checked by mutation (on the earlier hand-written PTX; the launcher is unchanged since): a wrong multiplier (`*3`) gives 999 mismatches, and a dropped bounds check (`setp` against 2000)
gives 24 guard writes. Both fail `launch`.

## Device code from C++ (`tests/gpu/device/`)

The first kernel from C++ source: `vecadd.cpp`, the `vecAdd` kernel of NVIDIA cuda-samples
`0_Introduction/vectorAdd`, with the thread indices as `extern "C"` intrinsic calls. The Path B front end
(`scripts/pathb-dump --ir`) lowers it to IR (`vecadd.ir`, the golden); `scripts/pathb-ptx-emit.rb` lowers the IR to
PTX, with the intrinsics mapped to special registers (`DEVICE_INTRINSICS`); `ptxas` assembles it; `launch.c` runs it
on 50000 elements through the runtime. `tests/gpu/device/run.sh` runs this, a mutant (add -> sub, must fail), and a
call the emitter does not lower (exit 3). Calls of other functions are refused, and every IR function becomes a
`.visible .entry`, so a device helper would need `.func` support first.

This path does not yet connect to the `.cu` driver: the rewrite in `scripts/cuda-rewrite.rb` leaves
`threadIdx`/`blockIdx`/`blockDim` as host placeholders, and the kernel is not registered with the runtime.

## Launch path (llama.cpp features)

`tests/cuda/launch/run.sh` (run by `tests/cuda/run.sh`) covers the launch-path features of llama.cpp's CUDA backend.

- **`__launch_bounds__`** (18 files): removed with its argument list, in the host and device units (`strip_launch_bounds`
  in `scripts/cuda-rewrite.rb`). A compile hint, so nothing is lost. `bounds.cu` runs on the GPU.
- **Dynamic extern shared memory** (13 files): `extern __shared__ T name[];` is removed and each `name[...]` becomes
  `((T *)__nfcxx_dynshared_addr())[...]` (`dynamic_shared_rewrite`). The launch's third configuration item already
  reaches `cudaLaunchConfig_t::dynamicSmemBytes`. The device side is refused until the emitter lowers the call. The IR
  it needs: `(let %N (ptr void) (call (ptr void) &"__nfcxx_dynshared_addr"))`, which lowers to `cvta.shared.u64` of a
  module-level `.extern .shared .align 16 .b8 <name>[];` (name chosen by the emitter). A pointer subscript has no bounds
  check, which is right: the size is known only at launch.
- **`cudaFuncSetAttribute`, `cudaLaunchKernel` on kernel addresses** (llama.cpp calls them directly): macros in
  `lib/cuda/nfcxx_cuda.h` look the host address up in the registry (`cudaKernelSetAttributeForDevice`,
  `cudaLaunchKernelExC`). `async.cu` covers them with `cudaMallocAsync`, `cudaMemcpyAsync`, `cudaFreeAsync` and a
  kernel address in a variable. Not covered: `cudaLaunchKernelEx` (a template in the CUDA headers, which calls
  `cudaLaunchKernelExC` directly, so the host address is not looked up).
- **Template launch depending on an enclosing template parameter** (reduction, MC_EstimatePiP, and most ggml-cuda
  templated launches): refused with exit 3 (`dependent_on_template`). The device image would need that instance, and the
  rewriter does not know which instances a program uses. Needs the instantiation set from the front end.

## CUDA source (`.cu`)

`nfcxx` takes `.cu` inputs. The driver makes two things from each file:

- **Host copy.** `scripts/cuda-rewrite.rb` rewrites each launch `k<<<g, b[, shmem[, stream]]>>>(args)` into
  `__nfcxx_cuda_launch(k, g, b, shmem, stream, args)`. The helper (`lib/cuda/nfcxx_cuda.h`, included before every
  `.cu`) finds the kernel's device code in a registry and calls `cudaLaunchKernelExC`. The qualifiers are empty macros,
  and the device built-ins (`threadIdx`, ...) are zero placeholders for the host compile of a kernel body.
- **Device image.** `cuda-rewrite.rb --device` extracts the file's `__global__` and `__device__` functions into a
  device-only translation unit, with `threadIdx.x`, `blockIdx.x`, `blockDim.x`, `gridDim.x` (and y, z) rewritten to the
  intrinsic calls `__nfcxx_tid_x()` and the rest. `scripts/pathb-dump --ir` lowers it, `scripts/pathb-ptx-emit.rb`
  lowers the IR to PTX, and `ptxas -arch=sm_$NFCXX_SM` (default 75) assembles it. `scripts/cuda-embed.rb` then appends
  a registration tail to the host copy: the cubin as a byte array, the table of host function to entry name (the
  kernel's IR function, the name itself or `_Z<len><name>`), and a static object whose constructor calls
  `cudaLibraryLoadData` and `cudaLibraryGetKernel` before `main`.

Layout: one object per `.cu` file holds the host code and its device image (the cubin is a data array in it). The
host copy of a `-c` compile goes to a per-user cache, `${NFCXX_CU_CACHE:-$XDG_CACHE_HOME/nfcxx or ~/.cache/nfcxx}/cu/<key>/<name>.cpp`,
keyed by the absolute object path, and the `.ti` file records that absolute path. The EDG prelinker re-reads the
copy when it needs a template instance at link time, and a failed link deletes its input objects (so a missing copy
also costs the object). A link without `-c` uses a temp directory. Nothing is left under the source tree. A file with no
`__global__` gets no device image. The device compile needs the Path B harness (`scripts/setup-pathb.sh`) and ptxas;
`NFCXX_PTXAS` and `NFCXX_SM` override the tool and the architecture.

`tests/cuda/run.sh` checks the host rewrite against golden files, refuses unsupported launch forms (exit 3), and
builds, links and runs `mul2.cu`: the kernels run on the GPU and the program checks 1000 results.

NVIDIA `cuda-samples` `0_Introduction/vectorAdd`, unmodified, builds with `-I/usr/local/cuda/include/cccl` (for
`<cuda/cmath>`) on the default qbe backend and on `--backend=gcc`, links with `-lcudart`, and prints "CPU and GPU answers
match". On qbe, `scripts/qbe-prep.rb` maps `__builtin_fabsf` and `__builtin_fabs` (used by libcu++) to libm. Note that the
sample exits 0 even when its check fails: the check is its output line.

Device unit (`scripts/cuda-rewrite.rb --device`): the top-level pieces of the source (preprocessor lines, declarations,
definitions) are classified. The unit has every `__global__`/`__device__` function, and the host declarations those
reference, transitively: typedefs, using, struct/class/union/enum, `const`/`constexpr` variables and #define/#undef. Host
functions, host variables and `#include` lines are left out; quoted includes of files that exist are inlined first, so a
kernel in a `.cu` or `.cuh` of the same program is in the unit. A short prelude gives `uint`, `NULL`, `__shared__`
(a static object, refused by the emitter until static data is lowered) and `__syncthreads` (an intrinsic the emitter
does not lower yet).

Template kernel launches: `k<T...><<<...>>>(args)` is a call of `__nfcxx_k_<name>_<args>`, a C-linkage wrapper. The
device unit defines it as a call of the instance (which lowers as a helper); the host declares it at the launch and
defines a stub at the end of the file, so the embedded table finds it by name. The parameter list is the template's
with the explicit arguments substituted. Launches whose arguments depend on an enclosing template parameter fail to
compile (the stub refers to the parameter).

The CPU interpreter (`tests/gpu/ptx-interp`) runs `.func` and `call` (no recursion), so `helper_kernel` runs in
`tests/gpu/run_interp.sh` with the same check as the GPU run. A struct passed by value is refused with a message that
names the type.

Not done: the emitter beyond the kernels in `tests/gpu/kernels` (it refuses other nodes with exit 3), the front
end's CUDA input (EDG here has no CUDA mode, so `__global__` and `<<<>>>` do not parse), and an nvcc-compatible driver.

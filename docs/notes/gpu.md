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

## CUDA source (`.cu`)

`nfcxx` takes `.cu` inputs. Before the front end, `scripts/cuda-rewrite.rb` rewrites each launch
`k<<<g, b[, shmem[, stream]]>>>(args)` into `__nfcxx_cuda_launch(k, g, b, shmem, stream, args)`. The helper
(`lib/cuda/nfcxx_cuda.h`, included before every `.cu`) packs the arguments into the kernel's parameter types and calls
`cudaLaunchKernel`. The qualifiers (`__global__`, `__device__`, ...) are empty macros, and the device built-ins
(`threadIdx`, `blockIdx`, ...) are zero placeholders for the host copy of a kernel. No EDG change.

`tests/cuda/run.sh` checks the rewrite against golden files, refuses unsupported launch forms with exit 3, and builds
and runs `mul2.cu` through the driver. The launch reaches the runtime, but the kernel is not registered, so it returns
an error.

NVIDIA `cuda-samples` `0_Introduction/vectorAdd` builds and links through the driver with `--backend=gcc` (it needs
`-I/usr/local/cuda/include/cccl` for `<cuda/cmath>`). It runs, but its result check fails, because the kernel never
runs. The qbe backend (cproc) rejects `__builtin_fabsf`, which libcu++ uses.

Not done: device code (the kernel has to be built and registered with the runtime, so the launch can run), the qbe
path for libcu++, the emitter beyond this kernel (it refuses other nodes with exit 3), the front
end's CUDA input (EDG here has no CUDA mode, so `__global__` and `<<<>>>` do not parse), and an nvcc-compatible driver.

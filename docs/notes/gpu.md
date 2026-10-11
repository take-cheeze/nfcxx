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
host copy of a `-c` compile stays beside the object, in `<dir>/.nfcxx/<name>.cpp`, because the EDG prelinker
re-reads the source recorded in an object at link time; a link without `-c` uses a temp directory. A file with no
`__global__` gets no device image. The device compile needs the Path B harness (`scripts/setup-pathb.sh`) and ptxas;
`NFCXX_PTXAS` and `NFCXX_SM` override the tool and the architecture.

`tests/cuda/run.sh` checks the host rewrite against golden files, refuses unsupported launch forms (exit 3), and
builds, links and runs `mul2.cu`: the kernels run on the GPU and the program checks 1000 results.

NVIDIA `cuda-samples` `0_Introduction/vectorAdd`, unmodified, builds with `--backend=gcc` and
`-I/usr/local/cuda/include/cccl` (for `<cuda/cmath>`), links with `-lcudart`, and prints "CPU and GPU answers match".
Note that the sample exits 0 even when its check fails: the check is its output line. The qbe backend (cproc) rejects
`__builtin_fabsf`, which libcu++ uses.

Not done: device helper functions (the emitter makes every IR function a `.visible .entry`), the qbe path for libcu++,
the emitter beyond the kernels in `tests/gpu/kernels` (it refuses other nodes with exit 3), the front
end's CUDA input (EDG here has no CUDA mode, so `__global__` and `<<<>>>` do not parse), and an nvcc-compatible driver.

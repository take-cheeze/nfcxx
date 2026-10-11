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

Not done: the emitter beyond this kernel (it refuses other nodes with exit 3), the front
end's CUDA input (EDG here has no CUDA mode, so `__global__` and `<<<>>>` do not parse), and an nvcc-compatible driver.

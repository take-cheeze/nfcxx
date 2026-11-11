# The CUDA driver API through the CUDA runtime (`--cuda-driver=`)

A program that calls the CUDA driver API (`cuInit`, `cuModuleLoadData`, `cuLaunchKernel`, ...) normally links
libcuda.so.1, the driver's own library, which comes with the GPU driver: `-lcuda`, or, from CMake, the full path of
`CUDA::cuda_driver` (`$CUDA_HOME/lib64/stubs/libcuda.so` or the system's `libcuda.so`). CMake projects get it without
asking for it: libtorch's package links `CUDA::cuda_driver` into `caffe2::cuda`, so every `find_package(Torch)` program
has it on its link line, and llama.cpp's ggml-cuda links it for its virtual-memory pool. nfcxx's own CUDA code never
names it (`lib/cuda/nfcxx_cuda.h` loads kernels with the runtime's `cudaLibraryLoadData`), and none of libcudart,
cuBLAS, cuDNN, NVRTC or libtorch's libraries has libcuda.so.1 in `DT_NEEDED`: libcudart dlopens it when it is first used.

nfcxx and nfcc replace a libcuda on the link line with `libnfcxx_cudrv.a` and libcudart. The driver functions then come
from libcudart, which looks them up in the driver (`cudaGetDriverEntryPointByVersion`) and loads libcuda.so.1 itself,
at run time. So:

- the program links where no driver is installed;
- it starts without a driver: every driver call returns `CUDA_ERROR_NO_DEVICE` (and `cuGetErrorString` /
  `cuGetErrorName` say so) instead of the loader refusing the program ("libcuda.so.1: cannot open shared object file");
- a bundle (`--bundle-libs`, `bundle.md`) carries libcudart and does not name the driver in `DT_NEEDED`; the driver is
  never bundled (it has to match the machine's kernel driver).

| `--cuda-driver=` (or `NFCXX_CUDA_DRIVER=`) | A link that names libcuda |
| --- | --- |
| `auto` (the default) | through libcudart; when the shim cannot be made (no `cuda.h` and `cudaTypedefs.h`, libcudart before 12.5, not x86-64) libcuda is linked as named, with a note on stderr |
| `cudart` | through libcudart, and an error when the shim cannot be made |
| `libcuda` | libcuda as named (the behavior before) |

The toolkit is `$CUDA_HOME`, else the one the libcuda path lies in (`<root>/lib64/stubs/libcuda.so`), else
`/usr/local/cuda`: its `include` gives the headers of the shim, its `lib64` libcudart (added with `-L` and as a run path,
as nfcxx does for `-lcudart`). When the link already has the static runtime (`-lcudart_static`, CMake's default for
CUDA targets) the shim binds to it and no shared libcudart is added; the program then needs glibc only. Every mention
of libcuda goes; the first becomes the shim.

```
./nfcc app.c -lcuda -o app                                    # needs libcudart.so.12, not libcuda.so.1
cmake -DCMAKE_C_COMPILER=$PWD/nfcc ...                        # CUDA::cuda_driver the same way
./nfcxx --bundle-libs app.cpp -L$CUDA_HOME/lib64 -lcuda -o app   # needs glibc only
gcc app.c $(scripts/cuda-driver-shim $CUDA_HOME/include) -L$CUDA_HOME/lib64 -lcudart   # without the drivers
```

The PyPI wheel directory of `scripts/fetch-cuda-libs.sh` works as the toolkit. Test: `tests/cuda/driver/run.sh` (CI:
cuda.yml); on a GPU, `tests/cuda/gpu/run.sh` (by hand).

## How

`scripts/cuda-driver-shim INCLUDE_DIR` builds `build/cuda-driver/<hash>/libnfcxx_cudrv.a` from the CUDA headers and
`lib/cuda/driver/nfcxx_cudrv.c`, and prints its path. Each driver function is a trampoline that jumps through its slot;
a slot starts at a resolve stub that saves the argument registers, asks libcudart for the function, stores it in the
slot and jumps there. One trampoline serves every signature, and later calls cost one indirect jump. The functions are
hidden: they bind the program's own calls and do not interpose libcuda.so.1 for other libraries in the process.

The lookup needs a version per linked name, not per function: cuda.h binds `cuCtxCreate` to `cuCtxCreate_v2`, the 3.2
ABI, but the base name `cuCtxCreate` asked for at CUDA 12.9 is the 12.5 one (`cuCtxCreate_v4`, other arguments). The
generator therefore compiles a probe against cuda.h and cudaTypedefs.h (with and without
`CUDA_API_PER_THREAD_DEFAULT_STREAM`) that asks gcc, for every declared function and every `PFN_<base>_v<version>`
typedef of its base, whether the types are the same (`__builtin_types_compatible_p`). Each name gets its compatible
version; the `_ptds`/`_ptsz` names ask for the per-thread default stream. When several typedefs have the same type (the
same arguments, another behavior: `cuDeviceGetUuid` is 9.2, `cuDeviceGetUuid_v2` 11.4; `cuEventElapsedTime` 2.0,
`_v2` 12.8; `cuStreamWaitValue32_v2` 11.7 against the 8.0 one), the name's own suffix picks among them in ascending
order. A name without a typedef (24 functions new in 12.x at CUDA 12.9) asks for the header's `CUDA_VERSION`. With the
12.9 headers that is 483 functions; `matches.txt` beside the archive lists every compatible pair.

When a function cannot be had, its slot gets a function that returns a CUresult: `CUDA_ERROR_NO_DEVICE` when libcudart
reports an error (no driver), `CUDA_ERROR_NOT_FOUND` when the driver has no such symbol, `CUDA_ERROR_NOT_SUPPORTED` when
it is too old for the version. `cuGetErrorString` and `cuGetErrorName` fall back to texts of their own for those codes.

## Tests (`tests/cuda/driver/run.sh`)

- A stand-in libcudart (`fakecudart.c`) prints every request and returns functions that check their arguments.
  `drv.c` (and `drv_ptds.c`, compiled with the per-thread default stream) calls `cuInit`, `cuDeviceGetCount`,
  `cuCtxCreate` and `cuCtxCreate_v4`, both `cuDeviceGetUuid` and `cuEventElapsedTime` versions, `cuLaunchKernel` with
  eleven arguments (five on the stack), a function the "driver" is too old for, one it lacks (twice: one lookup), and
  `cuStreamQuery`/`cuMemcpy` per-thread; the output is `expected.txt`. Built by gcc with the archive, by nfcc with
  `--cuda-driver=cudart` and by nfcxx with the default, both backends each. These cases run with the 12.9 headers only
  (`CUDA_VERSION` 12090), the ones `drv.c` and `expected.txt` are written for: the versions asked for differ with other
  headers, 12.6 has no `cuEventElapsedTime_v2`, and 13.x's `cuCtxCreate` takes four arguments. Other headers skip them
  and run the rest.
- `--cuda-driver=libcuda` keeps libcuda (`DT_NEEDED` libcuda.so.1, from a stub like the toolkit's `lib64/stubs`).
- A CMake project (`cmake/`) that links `CUDA::cuda_driver`, configured with nfcc as its C compiler: by default the
  link needs libcudart.so.12 and not libcuda.so.1 and the calls reach the (stand-in) runtime; with
  `NFCXX_CUDA_DRIVER=libcuda` it needs libcuda.so.1 again. FindCUDAToolkit insists on an `nvcc` under
  `CUDAToolkit_ROOT` and only asks for its version, so the test's toolkit has a two-line one.
- The real libcudart (12.9 from PyPI in CI): `real.c` needs no libcuda.so.1; without a GPU driver `cuInit` returns
  `CUDA_ERROR_NO_DEVICE`, with one (`nvidia-smi` works) it succeeds and finds a device. The same with `--bundle-libs`,
  which then needs neither libcudart nor libcuda, and with `-lcudart_static` when the toolkit has it (glibc only; the
  PyPI toolkit of CI has no static runtime, so CI skips that case).
- `-c` ignores the option; an unknown `--cuda-driver=` value is refused.

Checked by hand: the same CMake project with libcuda kept cannot start without a driver ("libcuda.so.1: cannot open
shared object file"); through libcudart it prints `cuInit CUDA_ERROR_NO_DEVICE devices none` with the real libcudart.

On a GPU (RTX 5050, sm_120, driver 615.71 with CUDA 13.4 support; by hand): `tests/cuda/driver/run.sh` passes with the
12.9 PyPI toolkit (all 14 cases; `cuInit CUDA_SUCCESS` with the real libcudart, plain and bundled) and with the 12.6 and
13.4 toolkits (the real-libcudart cases, `libcudart_static` included: 462 and 526 shim functions).
`tests/cuda/gpu/run.sh` ("cuBLAS and cuDNN on a GPU" below) runs cuBLAS and cuDNN through the shim. A stand-in
libcuda.so.1 was tried and does not work: libcudart needs the driver's private export tables (`cuGetExportTable`)
before it hands out an entry point, so the success path needs a real driver.

## cuBLAS and cuDNN on a GPU (`tests/cuda/gpu/run.sh`, by hand)

`blas_dnn.c` makes driver calls (`cuInit`, `cuDeviceGetName`, `cuDeviceGetAttribute`, `cuCtxGetCurrent`,
`cuMemGetInfo`), a cuBLAS SGEMM (257x65x129) and a cuDNN convolution (`cudnnConvolutionForward`, the algorithm
`cudnnGetConvolutionForwardAlgorithm_v7` picks), each checked against a CPU reference, and is linked with
`-lcublas -lcudnn -lcudart -lcuda`. Built by gcc (the reference, which needs libcuda.so.1), by nfcc (gcc backend) and by
nfcxx (both backends):

- the program runs on the GPU and the nfcc and nfcxx builds do not need libcuda.so.1;
- with the driver hidden (bwrap binds `libcuda.so*` and `libnvidia*.so*` to `/dev/null`) the nfcc and nfcxx builds start
  and report `cuInit CUDA_ERROR_NO_DEVICE`; the gcc build cannot start;
- bundled (`--bundle-libs --bundle-stubs`, `bundle.md`), with cuDNN's dlopen'ed libraries and libcublasLt as files
  beside the stubs, it runs in a sandbox without the toolkit and with the system's cuDNN, cuBLAS, cudart and libstdc++
  hidden: glibc, libgcc_s and the driver only (60 MB with CUDA 13.4 and cuDNN 9.27, 105 MB with the 12.9 wheels).

Run with CUDA 13.4 and the system cuDNN, and with the 12.9 PyPI toolkit (`CUDA_HOME=` and `CUDNN_INCLUDE=`/
`CUDNN_LIB=` its `include` and `lib64`). Two things the bundle needs, both from cuDNN's `dlopen`s (`bundle.md`,
"Plugins and stubs"): libcublasLt is excluded from the bundle (`--bundle-exclude`), because cuDNN dlopens it by name
and looks its functions up in that handle, which a stub cannot answer; and cuDNN's libraries are copied under every
name (`libcudnn_graph.so.9.27.0` as well as `.so.9`), because cuDNN asks for the full version first and would
otherwise take a system cuDNN of the same version, built for another CUDA major, which asks for another libcublasLt.

nfcc with the QBE backend cannot compile `cuda_runtime.h`: `crt/host_defines.h` stops with "UNKNOWN COMPILER: please
provide a CUDA compatible definition for '__align__'" (it knows gcc, clang, MSVC and a few others, and cproc defines
none of their macros). Programs that use only `cuda.h` (`real.c`, `drv.c`) build there.

## Limits

- x86-64 Linux only (the trampolines are x86-64 assembly).
- The shim's table is the headers' it was built from: a program compiled against newer headers that calls a function
  they added fails to link (the name is not in the archive); rebuild the shim from those headers.
- A program that dlopens libcuda.so.1 itself, or uses `cuGetProcAddress` directly, is unaffected (both work, and need
  the driver at that point).
- Only links that go through nfcxx or nfcc are rewritten (a CMake build with them as the compilers, `nfcxx-cuda` as
  the CUDA compiler); a link by g++ keeps `-lcuda`, and the archive can be given to it by hand.
- libcudart must be 12.5 or later.

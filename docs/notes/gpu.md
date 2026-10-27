# GPU: first step (hand-written IR to PTX to cubin to launch)

Status: the first step is verified on an NVIDIA GeForce RTX 2060 (sm_75, driver 595, CUDA 13.2). The device flow now builds `.cu` files end to end (see "CUDA source"): the rewriter (`tools/cuda-rewrite`), the Path B front end, the C++ emitter (`tools/pathb-ptx-emit`, which splits a file's kernels into modules within ptxas limits), ptxas, and the embedded cubins. Coverage of the emitter's constructs is listed in the sections below; llama.cpp's ggml-cuda status is in `llamacpp.md`.

`tests/gpu/` holds one kernel in three forms:

- `mul2.ir`: the kernel as Path B IR (`docs/notes/pathb-stage2.md` form), written by hand. `(gpu T "NAME")` reads a
  special register (`tid.x`, `ctaid.x`, `ntid.x`). That form is new: stage 2 has no GPU operations yet.
- `tools/pathb-ptx-emit` (`build/pathb-ptx-emit --emit`): lowers `mul2.ir` to sm_75 PTX. `run.sh` tests its output, not a hand translation.
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
(`scripts/pathb-dump --ir`) lowers it to IR (`vecadd.ir`, the golden); `tools/pathb-ptx-emit` lowers the IR to
PTX, with the intrinsics mapped to special registers (`DEVICE_INTRINSICS`); `ptxas` assembles it; `launch.c` runs it
on 50000 elements through the runtime. `tests/gpu/device/run.sh` runs this, a mutant (add -> sub, must fail), and a
call the emitter does not lower (exit 3). Calls of other functions are refused, and every IR function becomes a
`.visible .entry`, so a device helper would need `.func` support first.

The `.cu` driver uses the same flow (see "CUDA source"): the rewriter leaves `threadIdx`/`blockIdx`/`blockDim` as host
placeholders, and each device module is registered with the runtime.

## Launch path (llama.cpp features)

`tests/cuda/launch/run.sh` (run by `tests/cuda/run.sh`) covers the launch-path features of llama.cpp's CUDA backend.

- **`__launch_bounds__`** (18 files): removed with its argument list, in the host and device units (`strip_launch_bounds`
  in `tools/cuda-rewrite`). A compile hint, so nothing is lost. `bounds.cu` runs on the GPU.
- **Dynamic extern shared memory** (13 files): `extern __shared__ T name[];` is removed and each `name[...]` becomes
  `((T *)__nfcxx_dynshared_addr())[...]` (`dynamic_shared_rewrite`). The launch's third configuration item already
  reaches `cudaLaunchConfig_t::dynamicSmemBytes`. The device side is lowered (`tests/cuda/launch/dynshared.cu` runs on the GPU). The IR
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
- **Instances declared `extern template`** (mmq.cuh's `extern DECL_MMQ_CASE(...)`, fattn-mma-f16.cuh's, and the
  fattn-vec and fattn-tile ones): another unit defines them, so the rewriter does not count them as this unit's
  instances, even where the unit calls them (`template_instances`), and their kernels are not in its device image.
  An explicit instantiation definition (`DECL_MMQ_CASE(GGML_TYPE_Q4_0);` in its instance file) still is.
  Before this change, each of the 22 mmq instance files built the kernels of all 24 types (1536 kernels, about 6.8
  million lines of PTX, about 10 minutes of ptxas each). Now each builds its own 64, in about 30 s. `fattn.cu` drops
  from 1623 kernels to 45, and `mmq.cu` to none. `tests/cuda/extern_inst` links three units and runs both instances.
- **Plain launches in the front end** (on by default for `.cu` inputs; `NFCXX_CUDA_EDG_LAUNCH=0` turns it off): the driver passes `--cuda` to EDG
  (3rd/edg), which parses `kernel<<<grid, block[, shmem[, stream]]>>>(args)` itself, and the rewriter leaves those
  launches (`--edg-launches`). The launch lowers to the same `__nfcxx_cuda_launch` call. Launches with template
  arguments are still rewritten here, and EDG refuses them if one reaches it.
- **A launch of a kernel with no device code** (a host function the kernel table does not have: an instance the
  rewriter left out) returns `cudaErrorInvalidDeviceFunction`, and `cudaGetLastError` / `cudaPeekAtLastError` report it
  (macros in `lib/cuda/nfcxx_cuda.h`; the runtime never saw the launch, so its own last error was success and the
  caller's check passed on garbage). The first failure of each address is printed with its offset in the program, for
  `addr2line -f -C -e`. `tests/cuda/launch/stub_addr.cu` checks it.
- **A dependent launch whose instance's address is taken too** (softmax.cu: `cudaFuncSetAttribute(soft_max_f32<true, 0,
  0, T>, ...)`, then the launch): the launch passes the host stub of the instance's wrapper, the attribute call the
  instance. The address table maps both to the one device entry (`stub_addr.cu`).
- **`half` is a struct** (`__nfcxx_half` in the device prelude, `tools/cuda-rewrite/tables.inc`), as in cuda_fp16.h:
  a cast, an initialization or a return between half and float converts the value. It was an `unsigned short`, so
  `(float)h` gave the integer value of the bits (48128 for -1), and every f16 path of ggml-cuda was wrong. The lanes of
  `half2` are halves. The default constructors of half and bf16 are `= default`, so both stay trivial (in unions, in
  arrays, in `__shared__` memory). `tests/cuda/launch/half_convert.cu`.
- **The toolkit's version macros in the device pass**: the driver reads `CUDART_VERSION` (cuda_runtime_api.h) and
  `CUDA_VERSION` (cuda.h) from the headers the host compile finds and passes them to the device rewrite and the device
  front end (a `-D` on the command line wins). The host had them and the device unit did not, so a `#if CUDART_VERSION`
  decided differently in the two copies (ggml-cuda's `GGML_CUDA_USE_CUB`: the host launched CUB-path kernels whose
  device bodies were the other branch). The CUDA 11.8+ device code ggml-cuda then compiles needs `movmatrix` asm (a
  PTX template the IR passes through, `be/nfcxx_ir.c`), and the prelude has `__nv_fp8_e4m3`, `__nv_cvt_e8m0_to_bf16raw`
  and `__nv_fp4x4_e2m1` (software conversions; they match cuda_fp8.hpp and cuda_fp4.hpp bit for bit on all 256 e4m3
  values and 2 million random floats).
- **Device-wide CUB** (`cub::DeviceReduce::Sum`, `DeviceScan::InclusiveSum` for float and bf16, and the float/int
  `SortPairs` and `SortPairsDescending` of `DeviceRadixSort`, `DeviceSegmentedRadixSort` and `DeviceSegmentedSort`):
  the host shim `lib/cuda/host/cub/cub.cuh` forwards to `lib/cuda/cub/device.cu`, which `scripts/cuda-cub` builds with
  the driver into `build/cuda-cub/<backend>/libnfcxx_cub.a`; a link that names `-lcudart` takes the archive. The sum and
  the scan are one block; the sorts are a stable bottom-up merge sort on CUB's radix order of the keys. The other
  device-wide algorithms are declared only (a call fails at link time). `tests/cuda/launch/cub_device.cu`.
- **Arrays of class objects** (`tile a[2];` when the tile's default constructor converts floats to half2): the front
  end lowers them to `__cxa_vec_ctor` and the constructor zeroes with `memset`. The emitter lowers both: one direct call
  of the constructor per element (count and size constants, no destructor) and byte stores (`vec_ctor.cu`).
- **Kernel instances from the host compile** (binbcast.cu): a launch or kernel address in a template that the unit
  calls only with deduced or dependent arguments (`launch_bin_bcast_pack<op, ...>(..., std::index_sequence<I...>)`)
  gives the rewriter no instance. It lists such kernel templates (`<kernels>.unresolved`); after the host compile the
  driver reads the output's symbols (`nm -C`, EDG's `_INTERNAL_` namespace removed), and when they have an instance of
  one of them it builds again with them (`NFCXX_CUDA_HOST_SYMBOLS`, `--host-symbols`): each instance gets its entry
  and a row in the kernel table. A unit whose templates other units instantiate (fattn.cu, mmq.cu) has none in its
  object and builds once. One `.cu` input only. A kernel's function parameter pack is one entry parameter per element
  (`host_instances.cu`).
- **Zero bytes of an initializer** are stored no wider than the object's alignment (`zero_tail.cu`), and the
  runtime's queries on a kernel's host address (`cudaOccupancyMaxActiveBlocksPerMultiprocessor`,
  `cudaFuncGetAttributes`) look the kernel up first (`func_query.cu`).
- **Float to integer** in device code is the GPU's conversion, as nvcc emits it (`pathb-ptx-emit --f2i=convert`, which
  the driver passes): `cvt.rzi` saturates, NaN gives 0 up to 32 bits, and a 1- or 2-byte target converts to 32 bits
  and keeps the low bytes (`intrinsics/cf2i_convert.cu`, its expected values from nvcc). The IR's range check, which
  traps, is the emitter's default. quantize_mmq_q8_1 rounds NaN into a `char4` for a block of zeros (127 / 0), and
  the trap was the mmq path's "unspecified launch failure".
- **ldmatrix** in inline asm (mma.cuh) names no state space, so its address is generic: the pointer operand is passed
  as it is, as nvcc does. Only a template with `.shared` gets the 32-bit shared address (`intrinsics/ldmatrix.cu`;
  converting it always was mmq's illegal memory access).
- **Half bits**: `__half_as_ushort`, `__ushort_as_half`, `__half_as_short` and `__short_as_half` read and write the
  half's bits. A cast between `__half` and an integer converts the value, as in `cuda_fp16.h`.
- **Module-scope arrays** are aligned by their size, up to 16 (`.align` of `.global`, `.const` and `.shared` data).
  llama.cpp reads its int8_t kvalues tables as uint32_t; nvcc declares them `.align 1` too and they happen to land
  aligned, while here a string before one gave mxfp4's mmq a misaligned address (`intrinsics/table_align.cu`).
- **`__byte_perm`** masks its selector with 0x7777, as nvcc does before `prmt`: bit 3 of a nibble would be `prmt`'s
  sign replication, and llama.cpp's q1_0, q2_0 and FP4 lookups pass selectors with it set (`intrinsics/int.cu`).
- **Partial aggregate initialization** of a local with constructors (`half2 s[8] = {{0.0f, 0.0f}}`): IL lowering
  makes only the constructor calls of the first element, and Path B zeroes the variable at its declaration first, as
  EDG's C back end does (`tests/pathb-qbe/cases/partial_init_ctor.cpp`).

## CUDA source (`.cu`)

`nfcxx` takes `.cu` inputs. The driver makes two things from each file:

- **Host copy.** `tools/cuda-rewrite` rewrites each launch `k<<<g, b[, shmem[, stream]]>>>(args)` into
  `__nfcxx_cuda_launch(k, g, b, shmem, stream, args)`. The helper (`lib/cuda/nfcxx_cuda.h`, included before every
  `.cu`) finds the kernel's device code in a registry and calls `cudaLaunchKernelExC`. The qualifiers are empty macros,
  and the device built-ins (`threadIdx`, ...) are zero placeholders for the host compile of a kernel body.
- **Device image.** `cuda-rewrite --device` extracts the file's `__global__` and `__device__` functions into a
  device-only translation unit, with `threadIdx.x`, `blockIdx.x`, `blockDim.x`, `gridDim.x` (and y, z) rewritten to the
  intrinsic calls `__nfcxx_tid_x()` and the rest. `scripts/pathb-dump --ir` lowers it, `tools/pathb-ptx-emit`
  lowers the IR to PTX, and `ptxas -arch=sm_$NFCXX_SM` (default 75) assembles it. `pathb-ptx-emit --embed` then appends
  a registration tail to the host copy: the cubin (an assembler `.incbin` of the file), the table of host function to entry name (the
  kernel's IR function, the name itself or `_Z<len><name>`), and a static object whose constructor calls
  `cudaLibraryLoadData` and `cudaLibraryGetKernel` before `main`.
- **Modules.** One PTX module cannot hold a large kernel set: ptxas caps the constant data of a module at 64 KB, and a
  module of every kernel of a large file takes too long to assemble. So the emitter runs in grouping mode
  (`pathb-ptx-emit --emit --groups-dir=DIR --max-const-bytes=N --max-ptx-lines=N --kernel=...`): the kernels are
  partitioned greedily, in order, into groups whose union closure (the functions the kernels reach, each function
  once per module that needs it) stays within both budgets. DIR gets `gNNNN.ptx` per group and `groups.txt` (the group's
  file, then its kernels' IR names). Each module references only its own data (string and constant declarations are
  emitted when a function uses them), and the helper functions are `.func`s, not `.visible`, so a helper in two
  modules is allowed. A kernel over the budget on its own is refused (exit 3). A `.global` that two modules would both
  need cannot be split, and is refused. The driver budgets are `NFCXX_CUDA_MAX_CONST_BYTES` (default 65536) and
  `NFCXX_CUDA_MAX_PTX_LINES` (default 60000). Each group is one cubin, and `pathb-ptx-emit --embed --groups=DIR` embeds
  them with a kernel table per module; the runtime registry maps each host address to its kernel in whichever module
  holds it. A file that fits one module has one group. `tests/cuda/groups/run.sh` forces a split and checks the results.

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

Device unit (`tools/cuda-rewrite --device`): the top-level pieces of the source (preprocessor lines, declarations,
definitions) are classified. The unit has the `__global__` kernels, and the `__device__` functions, classes and enums
that the kept pieces name, transitively: a function is kept when its name (any overload) appears in a kept piece, so an
address, a template argument, a function pointer or a member call keeps it. The host declarations those reference are
kept the same way: typedefs, using, struct/class/union/enum, `const`/`constexpr` variables and #define/#undef (a #define
inside a piece names the piece). Host functions, host variables and `#include` lines are left out; quoted includes of
files that exist are inlined first, so a kernel in a `.cu` or `.cuh` of the same program is in the unit. A device
function no kernel reaches is not in the unit (llama.cpp's mmq.cu: 2.5 MB to 2.2 MB, most of what is left is the kernel
wrappers). A short prelude gives `uint`, `NULL`, `__shared__`
(a static object, refused by the emitter until static data is lowered) and `__syncthreads` (lowered to `bar.sync 0`).

Template kernel launches: `k<T...><<<...>>>(args)` is a call of `__nfcxx_k_<name>_<args>`, a C-linkage wrapper. The
device unit defines it as a call of the instance (which lowers as a helper); the host declares it at the launch and
defines a stub at the end of the file, so the embedded table finds it by name. The parameter list is the template's
with the explicit arguments substituted. Launches whose arguments depend on an enclosing template parameter fail to
compile (the stub refers to the parameter).

The CPU interpreter (`tests/gpu/ptx-interp`) runs `.func` and `call` (no recursion), so `helper_kernel` runs in
`tests/gpu/run_interp.sh` with the same check as the GPU run. A struct passed by value follows nvcc's PTX convention
(`.param .align A .b8 NAME_param_k[S]`), so the interpreter's byte-array parameters carry it; `tests/gpu/device/run_struct_abi.sh`
checks it against an nvcc build on the GPU.

Not done: scalar returns still use `.func (.reg .bNN %rv)` where nvcc uses `.param func_retval0`, so calls across nvcc-compiled
PTX do not match at the ABI level (struct returns follow nvcc). The emitter still refuses the constructs named above (exit 3),
and the interpreter has no floating point. Plain `<<<>>>` launches are parsed by EDG (`--cuda`; see "Launch path").

## Kernel name obfuscation

`--obfuscate-kernels` on the nfcxx driver, or `NFCXX_OBFUSCATE_KERNELS=1` in the environment, renames every kernel of
each `.cu` input to `__nfcxx_kn_<hash>` (the hash is FNV-1a 64 of a per-file seed and the kernel's name). It applies to
existing sources unchanged: a CMake build such as llama.cpp's (`CMAKE_CUDA_COMPILER=nfcxx-cuda`) takes the environment
variable, with no change to its command line. `NFCXX_OBFUSCATE_SEED` sets the seed (for reproducible objects; by default
each `.cu` gets a random one, so two builds of the same source differ).

The rename is on the expanded source in `tools/cuda-rewrite --obfuscate=SEED`, before the host copy and the
device unit are made. So the new name is in the static kernel, its launch, the kernel table, the device IR and PTX
entries and the cubin. Template kernels take it through their wrappers (`__nfcxx_k__nfcxx_kn_<hash>_<types>`). String
and character literals are not changed (a string that names a kernel is program data); comments are, so the cached
copy keeps no old name. A kernel in a `.cuh` that several `.cu` files include gets its name per file: with the
default random seed each unit has its own names, which is fine because each unit's host copy and its device image
are self-contained. With `NFCXX_OBFUSCATE_SEED` set, the same kernel gets the same name in every unit.

What it does not do: it hides the names, not the code. The cubin still holds the kernel's SASS and parameter layout, and
`cuobjdump` or a profiler shows the code. Nsight and `cudaFuncGetName` show the new names. The hash is not
cryptographic: with the default random seed the names do not reveal the kernels to anyone without the seed, but a
known seed (`NFCXX_OBFUSCATE_SEED`) and a list of candidate names give the originals back.
`tests/cuda/obfuscate/run.sh` checks the rewrite (no old name in the host copy or the device unit, the launches and
the list use the new names, same seed gives the same output), and the IR, PTX and embedded table when the Path B front
end is built. The host compile and the run need the CUDA toolkit and a GPU, and were not run for this change.

## Math and dp4a intrinsics (ggml-cuda)

Lowered by the emitter (`FLOAT_BUILTINS`, `SCALAR_U32`) and wrapped in the device prelude (`BUILTIN_DEFS`):
`fmaxf`, `fminf` (`max.f32` / `min.f32`: a NaN operand is ignored when the other is a number, as CUDA),
`fabsf` (`abs.f32`), `sqrtf` (`sqrt.rn.f32`, correctly rounded), `__saturatef` (`cvt.sat.f32.f32`), `__dp4a`
(`dp4a.s32.s32`, sm_61 and later), `__ldg` (a plain load of the pointee), and the shuffle `__shfl_up_sync`.
Approximate, with their PTX instructions:

| Function | Lowering | Max observed error (test inputs) |
| --- | --- | --- |
| `rsqrtf` | `rsqrt.approx.f32` | 7.1e-8 |
| `__fdividef` | `div.approx.f32` | 9.7e-8 |
| `expf`, `__expf` | `mul.rn` by log2(e), then `ex2.approx.f32` | 1.4e-7 |
| `logf`, `__logf` | `lg2.approx.f32`, then `mul.rn` by ln(2) | 1.4e-7 |

The error is `|got - ref| / (1 + |ref|)` against a double-precision reference, over 4096 inputs in [-8, 8) with
the special values (a NaN operand, a zero divisor). The approximate instructions are not correctly rounded, so
the bounds hold for the tested range only; the PTX ISA is the reference for the general case.

The rounding functions are exact: `floorf` (`cvt.rmi.f32.f32`) and `trunc` (`cvt.rzi.f32.f32`) are one instruction each,
and `roundf` (halfway away from zero) is `trunc` plus one when the fraction is at least one half. `sinf`, `cosf`,
`tanhf` and `expm1f` are computed in double and rounded once: `sinf` and `cosf` reduce by the nearest multiple of
pi/2 (fdlibm's two-part constant) and take the quadrant's Taylor series; `expm1f` is a Taylor series for |x| < 1/32 and
otherwise exp(x) - 1 with exp(x) = 2^k exp(r); `tanhf(x) = e / (e + 2)` with e = expm1(2|x|), and 1 for |x| >= 10. On
2^20 arguments in [-20000, 20000] and 2^18 up to 1e6 (plus the edge values) the error is 0 ulp against the double
reference, so the bound checked is 1 ulp (CUDA's own `sinf` is within 2 ulp). The argument of `sinf` and `cosf` is
limited to |x| < 2^31 * pi / 2 (about 3.4e9): the nearest multiple is an `int`. `INFINITY` and `FLT_MAX` are the
`<math.h>` and `<float.h>` values. The double arithmetic costs throughput on the device (FP64 is slow on consumer
GPUs); a float-only form would need a Payne-Hanek reduction for large arguments.

`tests/cuda/intrinsics/math.cu` checks these on the GPU against the host: exact functions bit for bit, the
approximate ones within the tolerance above. It is not yet in `tests/cuda/intrinsics/run.sh`: its host copy needs
host placeholders for `__fdividef`, `__saturatef`, `__ldg` and `__dp4a` in `lib/cuda/nfcxx_cuda.h`. Until those land,
the device side was checked by lowering the kernel to PTX, assembling it, and running it with a harness that
loads the cubin (0 mismatches over 57,344 checks; the mutant max -> min gives 4094 mismatches).

## SPIR-V kernel emitter for OpenCL (Intel XPU)

The "Level Zero / OpenCL" item of `docs/notes/sycl-vulkan.md` (a Kernel-capability variant of the SPIR-V module): `scripts/pathb-spirv-kernel-emit.rb`
lowers the Path B IR to SPIR-V assembly text (the input of `spirv-as`), the counterpart of `pathb-ptx-emit.rb` for the Intel
XPU. Kernels are `OpEntryPoint Kernel` with `Physical64` and the OpenCL memory model; pointers are typed CrossWorkgroup
pointers; slots and `set` registers are Function variables; `if` and `loop` are structured (`OpSelectionMerge`, `OpLoopMerge`).
The work-item indices are Input builtins as `size_t` vectors: Intel's IGC segfaults on a `uint` vector for `LocalInvocationId`.
It is separate from the Vulkan emitter (`pathb-spirv-emit.rb`): different memory model and built-ins.

Refused (exit 3): trap, checked division and shifts, cf2i, bool in memory, 1- and 2-byte integers, and calls between functions.

`tests/gpu/spirv/run.sh` lowers `tests/gpu/device/vecadd.ir`, checks the golden, assembles and validates it (`spirv-as`,
`spirv-val`; nixpkgs: `nix-build '<nixpkgs>' -A spirv-tools`), and runs it on the Arc B60 through OpenCL (`launch.c`,
`clCreateProgramWithIL`): 0 mismatches over 50000 elements, 0 guard writes. A mutant (`OpFAdd` -> `OpFSub`) is caught, and
`trap` is refused. The loop kernel (`loop.ir`: `break`, a `set` accumulator) sums 0..9 to 45 on the GPU, and its bound-test mutant is caught.

The same SPIR-V runs through the SYCL runtime (`lib/sycl`, `rt_opencl.hpp` and `rt_level_zero.hpp`): `tests/sycl/run.sh` builds
the SYCL programs for `--backend=opencl` and `--backend=level-zero`. A dispatch whose stacks exceed the heap is split into
slabs on both (#342). The ggml-sycl rung tests (`tests/gpu/ggml/`, fill, diag, unary) use this path; their status is in
`docs/notes/ggml-sycl.md`. The runners need `spirv-as`/`spirv-val` (`SPIRV_TOOLS_BIN` or `PATH`) and the oneAPI runtime, which
`scripts/oneapi-env.sh` sets up (#358).

Not done: the checked operations and calls between functions, and running through SYCL's own kernel bundles (OpenCL is used).

## WebGPU (Dawn) vs OpenCL on the Arc B60

`tests/gpu/webgpu/` runs the same vector add through WebGPU and checks it. `vecadd.cpp` picks the Intel Vulkan adapter
(the B60 under ANV; the NVIDIA card enumerates first and is skipped), dispatches 50000 elements, and compares the readback
with `a + b`. `run.sh` also builds the mutant (`a - b`), which must fail. `bench.cpp` and `opencl_bench.c` time the three
measurements below. Each is the median of 5 runs after one warm-up run. The OpenCL kernels are the same shapes as the WGSL
ones: one 64-thread workgroup that touches one word, and the 50000-element add.

| measurement | Dawn (Vulkan, ANV) | OpenCL (NEO) |
|---|---|---|
| (a) vecadd 50000, end to end (encode/enqueue, execute, read back) | 0.321 ms | 0.072 ms |
| (b) 10000 one-workgroup dispatches, one command buffer / one clFinish, per dispatch | 1.30 us | 2.88 us |
| (c) 10000 dispatches, each submitted on its own (Dawn: N submits; OpenCL: clFlush after each enqueue), per dispatch | 30.8 us | 2.90 us |

Environment: Dawn at commit 2193f65 (the build in `/home/takecheeze/dev/third/dawn/build`), Mesa ANV 26.0.8 for Vulkan
(Arc Pro B60, BMG G21), Intel NEO 26.31 for OpenCL (the same B60). Both runs were on the same machine, one after the other.
Every run of the vector add checked out (0 mismatches over 50000 elements), and the mutant was caught.

What the numbers show: the cost of one small dispatch depends heavily on how it is submitted. Inside one batch Dawn costs
about 1.3 us per dispatch, below OpenCL's 2.9 us, but a submit per dispatch costs Dawn about 31 us, about ten times OpenCL's
flushed enqueue. For the one-shot 50000-element add, OpenCL's blocking enqueue and read is about four times faster than Dawn's
map-and-readback path.

What they do not show: these are per-dispatch launch overhead and throughput for a kernel that does almost nothing (one
workgroup, one thread writes one word), and for one vector add of fixed size. They are not a claim about real workloads,
which have more work per dispatch, other buffer traffic, and their own submit patterns. The Dawn (b) and (c) runs also
do not check the sink value the kernel writes, so the numbers say the dispatches were submitted and completed, not
that each one ran the body. The vector add is verified; the small kernel is not.

# SYCL on WebGPU

Status: **working for a SYCL 2020 subset** (the Vulkan backend, which lifts most of the limits below, is in `docs/notes/sycl-vulkan.md`), checked on Chromium's WebGPU (SwiftShader, so no GPU is needed). Kernels written
as C++ lambdas are compiled to WGSL by `scripts/pathb-wgsl-emit.rb` and run through WebGPU; the rest of the program runs as
native code built by nfcxx. `tests/sycl/run.sh` is the regression suite; `tests/sycl/compat/` measures how much real SYCL
code the library accepts.

```
scripts/sycl-build.sh prog.cpp -o prog        # WebGPU: device pass -> WGSL, host side with nfcxx (or $CXX, --cxx=)
scripts/sycl-build.sh --cpu prog.cpp -o prog  # host path only: kernels are C++ loops, any C++17 compiler
./prog                                        # starts tests/sycl/server.cjs (node + Chromium) when a kernel launches
```

## Why this shape

The repo already had one single-source GPU path: `.cu` files, `tools/cuda-rewrite` splitting host and device text, and
`tools/pathb-ptx-emit` lowering the device IR to PTX (`docs/notes/gpu.md`). SYCL is easier on the front end and harder
on the back end:

- SYCL is plain C++. No new syntax, so no rewriter: the kernel is the `operator()` of a closure object, which the Path B IR
  already has as a function. The *device pass* compiles the same source once more with `-D__NFCXX_SYCL_DEVICE__`
  (`scripts/pathb-dump --ir`); only function bodies differ between the passes, so the classes have the same layout in both.
- WGSL has no pointers, no 64-bit integers, no `double`, only structured control flow and a uniformity analysis for
  barriers. The emitter gives pointers back (below) and refuses what it cannot represent.
- WebGPU is asynchronous and lives in JavaScript (or Dawn/wgpu-native). The runtime is therefore a six-operation protocol;
  the shipped implementation talks to a Node process over a pipe (`lib/sycl/include/sycl/rt_pipe.hpp`,
  `tests/sycl/server.cjs`). A native `webgpu.h` implementation would replace those two files.

## Pipeline

```
prog.cpp --pathb-dump --ir -D__NFCXX_SYCL_DEVICE__--> IR --pathb-wgsl-emit.rb--> prog.wgsl + prog.man
prog.cpp --nfcxx (or g++) -DNFCXX_SYCL_WEBGPU-------> prog        (finds prog.wgsl through NFCXX_SYCL_IMAGE)
```

- **Kernel entries.** `handler::parallel_for` etc. call `__nfcxx_sycl_entry_range<D, F>()` in the device pass. The emitter
  turns every function whose name contains `__nfcxx_sycl_entry_` into a compute entry point and lowers only what it can
  reach, so the host half of the translation unit (iostream, std::vector, ...) is never looked at.
- **Kernel identity.** The entry reads its closure with `__nfcxx_sycl_closure()` and casts it to `const F *`; the manifest
  line is `k<N> TAB key TAB size`, the key being the closure type's mangled name without `_Z` (what `typeid(F).name()`
  returns with g++ and with this front end; clang mangles lambdas differently and is not supported as the host compiler).
  The host sends the key with every dispatch, and the server refuses a closure whose size differs from the device pass's
  (the two compilers laid the lambda out differently): this caught a real g++/EDG difference (g++ captured a `const int` the
  other folded). `scripts/sycl-build.sh` therefore builds the host side with nfcxx when it is built; g++ works when the layouts
  agree, which the server checks by size only.
- **Launch.** The host copies the closure object's bytes into a 4096-byte uniform buffer and sets the dispatch size; the
  kernel gets the global range from another uniform and the local size from pipeline constants (`WGX/WGY/WGZ`), so one WGSL
  module serves every work-group size. Dispatches are rounded up to whole groups, and split in several when a dimension needs
  more than `maxComputeWorkgroupsPerDimension` groups (the group offset is in the uniform); `parallel_for(range)` entries
  guard `gid < range`.

## Memory model

An IR pointer is a `u32` whose top two bits name the memory:

| bits | memory | WGSL |
| --- | --- | --- |
| `00` | the heap, one storage buffer (up to 768 MB); byte *i* is address `HEAP_BASE + i` (`0x10000000`) | `array<atomic<u32>>` |
| `01` | work-group memory: `local_accessor` storage (`WG_WORDS` words, a pipeline constant), then 256 words of scratch for the group algorithms | `var<workgroup> array<atomic<u32>>` |
| `10` | the invocation's stack: IR slots that need an address (aggregates, address-taken scalars) | `var<private> array<u32>` |
| `11` | the kernel's closure object (captured state), read-only, 4096 bytes | `var<uniform> array<vec4<u32>, 256>` |

The closure lives in a uniform buffer so that the shader's uniformity analysis knows what it holds is uniform: WGSL accepts a
barrier only where it can prove all invocations arrive, and a loop bound captured by value (`for (i = n / 2; i > 0; i >>= 1)
{ barrier(); ... }`) is then provable. The emitter keeps a flow-insensitive record of which registers, scalar slots and
parameters only ever hold pointers into the closure (`Fn#analyze`, and a fixpoint over the call graph) and loads through those
directly (`cl32`). Anything that goes through the stack (a copied `range`, an `nd_item`) is non-uniform to the analysis, so a
barrier under a loop bounded by such a value is rejected by WGSL with a message naming the value; `tests/sycl/barvar.cpp`
covers the supported case.

A scalar slot only loaded and stored by name becomes a WGSL local variable instead. Frames are laid out statically from the
call graph (no recursion), so a callee's frame sits after its callers'. 1- and 2-byte accesses are shifts and masks on the
containing word (a store is an and/or pair); 4-byte accesses must be 4-aligned; 8-byte integers and pointers are narrowed to
their low 32 bits (`size_t` arithmetic is exact below 2^32).

**USM falls out of this.** The runtime maps an arena of the heap's size at a virtual address whose low word is `HEAP_BASE`
(`MAP_FIXED_NOREPLACE`), so a host pointer *is* the device address in its low 32 bits. `malloc_device/shared/host` return
blocks of that arena that the server also allocated; kernels capture raw USM pointers and the closure bytes carry the right
numbers. Coherence is by copying: shared and host allocations go to the device before a dispatch if the host may have changed
them, and come back at every wait; device allocations move through `memcpy/memset/fill`.

Buffers keep their own host copy; an accessor holds the buffer's device address and `buffer_state` tracks which side is newer
(upload before a kernel that reads, mark the host stale after one that writes, read back at `host_accessor`, destruction or
`set_final_data`).

**Checks cannot trap on a GPU.** Division by zero, `INT_MIN / -1`, a shift count out of range, `bounds`, `nonnull`, `trap` and
float-to-int overflow set `atomicMax(heap[1], code)` and go on with WGSL's defined result; the runtime reads the flag at the
next wait and exits with status 71 and the reason (`tests/sycl/trap_div.cpp`).

## What a kernel may use

Scalars (`int`, `unsigned`, `float`, `bool`, `char`, `short`; 64-bit integers narrowed), structs and arrays by value, calls of
other functions (including lambdas, functors, templates, `std::` algorithms that inline to plain code), loops with
`break`/`continue`/`goto`-to-loop-end (also out of a `switch` inside a loop, through a flag), `switch` whose arms end in a jump,
local and global memory, barriers, atomics, work-group algorithms, the C library float functions (`std::sqrt(float)`,
`sqrtf`, `__builtin_sqrtf` and friends map to WGSL builtins), `sycl::` math, reductions, and static data: constant tables, string
literals and globals with a constant initializer live in a region the server allocates and fills at load time (`S`/`R` lines
of the manifest). A kernel that writes such a global shares it across invocations and launches; the host never sees it.

Refused at build time with the reason on stderr (exit 3): `double`, a call whose body is not in the device unit (`printf`,
`std::cout`, `sycl::stream`, `rand`, a library function), a zero-initialized global (a dynamic initializer would look the same
in the IR), function pointers and virtual calls, recursion, `switch` arms that fall through, other `goto`, a kernel with
parameters, a closure over 4096 bytes. Refused when the shader is created, by the server (exit 6): a work-group larger than
the device allows (256 invocations here; `get_info<max_work_group_size>` says so), local memory over the limit.

## API coverage

`lib/sycl/include/sycl/sycl.hpp`, one header; `<CL/sycl.hpp>` and `cl::sycl` for 1.2.1 spellings.

| area | state |
| --- | --- |
| `queue`, `handler`, `event` | `submit`, `parallel_for` (range, nd_range, size_t, reductions up to 3), `single_task`, `memcpy/memset/fill/copy`, `wait`, profiling (host clock), `depends_on` ignored (the queue is in order), all selector spellings, async handler accepted |
| `buffer` | host pointer, containers (also `const`, CTAD), `set_final_data`, `set_write_back`, reference semantics (copies share), 1-3 D. Not: sub-buffers, `reinterpret`, allocators |
| accessors | `accessor` (all modes, `no_init`, property lists, multi-D `a[i][j][k]`, `item` subscripts, `get_multi_ptr`), `host_accessor`, `local_accessor`, `get_access<>()` 1.2.1 forms. Not: images, `accessor` ranges/offsets, placeholders |
| ranges and items | `range`, `id`, `item`, `nd_range`, `nd_item`, `group` (`operator[]`, ids, ranges), `sub_group` of size 1 |
| group algorithms | `reduce_over_group`, `group_broadcast`, `inclusive_scan_over_group`, `exclusive_scan_over_group`, `any_of_group`, `all_of_group`, `none_of_group`, `joint_reduce`, `group_barrier`, on `group<D>` with 32-bit (device) or word-sized (host) values; sub-group versions are the identity |
| USM | `malloc_*`, `aligned_alloc_*`, `free`, `get_pointer_type`, `usm::alloc`. Not: `usm_allocator`, `prefetch/mem_advise` (accepted, no-ops) |
| reductions | `reduction(var|buffer, op)`, `plus/multiplies/minimum/maximum/bit_*`, `initialize_to_identity`, `reducer` (`combine`, `+=`, ...). On the device each work-item combines with an atomic: `int`/`unsigned` for all operators, `float` for `+`, `min`, `max` through a compare-and-swap loop. Not: `multiplies` on the device |
| atomics | `atomic_ref` on 32-bit integers (global and local memory) |
| math | float `sqrt exp log sin cos tan asin acos atan sinh cosh tanh exp2 log2 floor ceil trunc round fabs pow fmod atan2 copysign fmin fmax fma mix clamp rsqrt abs`; `double` overloads exist for the host path |
| vectors | `vec<T,N>` with arithmetic, `x() y() z() w()`, `convert`, `dot`, `cross`; `float2/3/4`, `int2/3/4`, ... Not: swizzles, `vec` math functions |
| device queries | `get_info<>()` for the common descriptors, `has(aspect)`, platform and context shells |
| not available | `joint_*` scans and the other `joint_` forms, `group_*` on 64-bit values, `specialization_id`, images/samplers, `host_task` interop, multiple devices, sub-buffers, `sycl::ext::*`, `kernel_bundle`, graphs, `stream` on the device |

Sub-groups are one work-item wide (`get_info<sub_group_sizes>` says `{1}`), which is legal and keeps the host and device paths
equal; every sub-group algorithm is the identity. The work-group algorithms write each work-item's value to a scratch slot,
meet at a barrier and read what they need (`O(n)` per work-item); the scratch is 256 words of work-group memory kept by every
pipeline, and the table of a fiber scheduler on the host.

## Differences from other SYCL implementations worth knowing

- On the host path the work-items of an nd_range group are fibers (`ucontext`, 96 KB stacks, `NFCXX_SYCL_FIBER_STACK`), so
  `barrier()` and the group algorithms work, one group at a time; a group of one work-item runs directly.
- `double` kernels work on the host path and are refused on the device.
- Reference captures in kernels are not supported by SYCL either, but here they are silently wrong on the device (the
  closure bytes would be host stack addresses); capture by value.
- `float` operations may be contracted into fused multiply-adds by the WebGPU implementation (WGSL allows it).

## Compatibility with real SYCL code

`tests/sycl/compat/sweep.sh DIR` compiles (syntax only) every `.cpp` under DIR that includes a SYCL header, and
`run-samples.sh` builds and runs a list of them on both paths. Two public corpora, files unmodified:

Corpus 1: a shallow clone of `oneapi-src/oneapi-samples` (765 `.cpp` files include a SYCL header), files unmodified.

| step | result |
| --- | --- |
| parse (`sweep.sh`, `g++ -fsyntax-only`) | 356 files parse. Of the 409 that do not, 364 need headers of other libraries: `dpct/dpct.hpp` (the DPC++ migration tool, 277), `dpc_common.hpp`, oneMKL, oneDPL, Level Zero, OpenCL, embree. That leaves 401 files that need only SYCL, of which 356 parse (89%). The other 45 hit API this library lacks: sub-buffers, `specialization_id`, `sycl::ext::*`, `std::span` (C++20), `omp_interop`, `device::get_backend`, buffers from brace lists |
| build and run (`run-samples.sh`, 252 distinct programs by content, 45 s each) | host path: 195 run to completion with exit 0 (77%); WebGPU path: 137 |
| the 137 that finish on both | 134 print the same lines once timing lines are dropped. The other three: two print the device's maximum work-group size (1024 on the CPU, 256 on WebGPU) and one (`sum_subgroup_reduce.cpp`) reads shared USM on the host with no `wait()` after the kernel (the host path runs the kernel at once, so it "works" there) and also assumes `reqd_sub_group_size(32)`, an attribute this library ignores: its sub-groups are one work-item wide, so neither path gives the answer of a real device |

What the other 115 WebGPU runs were (several programs per row):

| count | reason |
| --- | --- |
| 59 | did not finish in 45 s: SwiftShader is a software GPU and the programs size their problems for a real one (26 programs time out on the CPU path too) |
| 14 | need command-line arguments or several GPUs (`flat_sycl_vec_add` wants two), on the host path too |
| 11 | a kernel prints with `std::cout` or a library object: refused (exit 3) |
| 9 | not programs (a snippet without `main`, a function library): the link fails on the host path too |
| 7 | a kernel uses `double`: refused |
| 6 | a work-group of 512 or more work-items, over the 256 the adapter allows (the server says so; `get_info<max_work_group_size>` reports 256) |
| 4 | the program reports failure: three AddressSanitizer demos that contain a deliberate bug (use after free, out-of-bounds local write), and one unsynchronized read |
| 2 | crash on allocations of 4 GB and more (the heap is 768 MB) |
| 2 | a reduction over `pair<int,int>` (8 bytes: no 64-bit atomics) fails to compile with a static assertion that says so |
| 1 | a kernel calls `rand`: refused, the message names the function |

Corpus 2: `codeplaysoftware/syclacademy`, the SYCL training course (36 files include a SYCL header; 16 need Google Benchmark or
oneMath). The other 20 programs (exercise templates and solutions) all run on the host path, and 19 on WebGPU with the same
output; the 20th prints from a kernel with `std::cout` and is refused.

Running the sweep taught the library most of its API and found the limits above. The runs found, in order: closure layouts that
differ between g++ and the front end (`CL/sycl.hpp` programs captured constants differently; now checked by size at every
dispatch, and nfcxx is the default host compiler); `item` converting to both `id` and `size_t` in subscripts (an overload on
`item`); EDG not finding a conversion function *template* for `id == 5` (the conversion is now a mixin base); 1-D dispatches of
more than 65535 groups (split into several, with a group offset uniform); heaps too small for the samples (256 MB to 768 MB);
barriers rejected by WGSL's uniformity analysis (the closure moved to a uniform buffer, above); `std::sqrt(float)` and the other
libstdc++ math wrappers calling `__builtin_sqrtf`, which the qbe back end could not compile (`scripts/qbe-prep.rb` maps the libm
builtins now, with its Python oracle); volatile accesses; user-defined reduction operators; atomic-mode accessors;
`group::operator[]`, `sub_group::load`, event profiling.

To repeat it:

```
git clone --depth 1 https://github.com/oneapi-src/oneapi-samples
tests/sycl/compat/sweep.sh oneapi-samples OUT            # OUT/results.tsv: parse status and first error per file
grep -P '\tok\t' OUT/results.tsv | cut -f1 > LIST        # (deduplicate by content if you like)
SAMPLE_TIMEOUT=45 tests/sycl/compat/run-samples.sh oneapi-samples LIST OUT2   # OUT2/samples.tsv: both paths per program
```

The programs are untrusted source: read them before running. The numbers above are from one full run; later additions
(ranged accessors, `get_host_access(tag)`) were checked with `tests/sycl/run.sh` and the syclacademy programs only.

## Tests

`tests/sycl/run.sh` builds each program for the host path with g++ and with nfcxx, and for WebGPU with nfcxx, and compares
the printed line: `vecadd`, `saxpy2d` (2-D range, captures, float math, a helper function), `reduce` (nd_range, local memory,
barriers, atomics), `bytes` (8/16-bit types, `switch`, `continue`/`break`), `chain` (kernels in sequence on resident
buffers, functor and named kernels, `single_task`, atomic histogram, ranged accessors), `matmul` (tiled, 2-D local memory),
`usm` (shared/device memory, `memcpy/memset/fill`, three kinds of reduction), `tables` (constant tables, structs, a string),
`libm` (`std::` math on floats), `groups` (work-group algorithms), `barvar` (a barrier in a loop bounded by a captured
variable), `atomics` (integer, unsigned and float `atomic_ref`, compare-and-swap, atomic-mode accessors, `vec`), `redcustom`
(user-defined and `multiplies` reductions, volatile). Two more check the failure modes: `trap_div` must exit 71 naming the
division, `refuse_double` must be refused with exit 3. A mutation of the generated WGSL (`+` to `-` in `vecadd`) fails the
program, which is what shows the results come from the shader. 38 checks, about 4 minutes (SwiftShader is slow at start-up).

The WebGPU part skips when the Path B harness, the nfcxx build, node, Playwright or a WebGPU adapter is missing
(`node tests/sycl/server.cjs --probe`).

## Next steps

- Real sub-groups on WebGPU's `subgroups` feature (the adapter here lists it) instead of size 1.
- A native runtime on `webgpu.h` (Dawn or wgpu-native) behind the same six operations, so no Node process is needed.
- `double` as a pair of `f32` is not planned; `f16` and subgroup operations map to WebGPU extensions and could back real
  sub-groups.
- The host side with the nfcxx *Path B* wasm back end (`docs/notes/pathb-wasm.md`) would run the whole program in a browser;
  that needs aggregate parameters in the wasm emitter and JSPI for the blocking reads.

# CoreCLR's GC on the QBE back end

The workstation GC of CoreCLR (`src/coreclr/gc` in dotnet/runtime, pinned in `tests/realworld/run_coreclr_gc.sh`)
is a large C++ code base: 34 translation units, about 60k lines of `.cpp` (the largest, `plan_phase.cpp`, is 8.4k lines),
written against the runtime's PAL headers, with volatile accesses, GCC `__sync` and `__atomic` builtins, and AVX2 code
for the vxsort sort.

## Status

- **Compile: 34 of 34 translation units, both backends.** `tests/realworld/run_coreclr_gc.sh` writes the two config
  headers CMake would generate (`gc/unix/config.gc.h`, `minipal/minipalconfig.h`) from their templates for glibc on
  x86-64, then compiles every file of the segments-GC source list with `./nfcxx -c`. The script is wired into
  `.github/workflows/realworld.yml`.
- **Link and run: not yet.** The objects have 40 unresolved C++ symbols and the usual libc ones (see below).

Before this work the QBE back end compiled 13 of the 34 (the rest hit cproc's "volatile store is not yet supported"
or a missing builtin, one error per file).

## What the QBE path needed (`scripts/qbe-prep.rb`)

- **Volatile stores.** cproc has no volatile stores. The qualifier is now dropped in EDG's output too, as the hand-written
  C path already did (the file comment of `qbe-prep.rb` has the rule). Volatile block-scope locals keep their address
  taken, so QBE leaves them in memory. The stores that remain are plain and in program order on x86-64, which is what gcc
  emits for a volatile store there; `Volatile<T>::Store` in `env/volatile.h` relies on exactly that together with the
  fence below. On other targets the rule is wrong: a plain store has no release ordering on arm64, and the fence stub is
  the x86 `mfence`. The QBE path is therefore x86-64 only for this code.
- **`__sync_{add,sub,and,or,xor}_and_fetch_{4,8}` and `__sync_val_compare_and_swap_{4,8}`** become helpers over cproc's
  `__atomic_fetch_OP` and `__atomic_compare_exchange_n` (seq_cst), with GCC's results (new value, old value).
- **`__builtin_prefetch`, `__builtin_ia32_pause`** (hints) become empty helpers; **`__builtin_ffs`** a small helper.
- `__atomic_signal_fence` already maps to the `mfence` stub (`FENCE_STUB`), a full barrier, which is stronger than the
  GC needs.

Regression tests: `tests/cases/qbe_coreclr_gc_forms.cpp` (volatile objects, casts and locals; the `__sync` results;
ffs, prefetch) and `tests/cases/qbe_coreclr_gc_pause.cpp` (x86 only). Both pass on both backends. The Python oracle
(`tests/mruby/oracle/qbe-prep.py`) carries the same rewrites, and `tests/mruby/qbe-prep.sh` still reports 175 of 175
inputs identical.

## What a link and run still needs

Measured by linking the 34 objects with the sample harness (`gc/sample/GCSample.cpp`, `gcenv.ee.cpp`) and listing the
unresolved symbols:

1. **vxsort.** `gcinternal.h` defines `USE_VXSORT` on AMD64, so the GC calls `do_vxsort_avx2` and
   `do_vxsort_avx512`. Those files use SIMD vector types, which cproc does not have (`do_vxsort_avx2.cpp` fails on
   QBE). A link check can use a scalar `std::sort` in their place; a real build needs vector support or a
   non-vxsort configuration.
2. **Platform layer.** `gc/unix/gcenv.unix.cpp` and `events.cpp` need `-D_GNU_SOURCE` (for `clockid_t` in glibc's
   `pthread.h`). `cgroup.cpp`, `numasupport.cpp` and `vxsort/isa_detection.cpp` compile on QBE as they are.
3. **Execution-engine side.** The sample's `gcenv.ee.cpp` is written against the Windows-style PAL headers. On Linux it
   conflicts with `gc/env/gcenv.base.h` (`HRESULT_FROM_WIN32`, `BitScanForward`) and misses `strcasecmp`. A Linux
   harness needs its own `GCToEEInterface` (thread suspension, allocation contexts, root scanning).
4. **Generated files.** `GCContractDescriptorWKS` comes from CMake's data-descriptor generator, and the minipal
   C sources (`mutex.c`, `time.c`, `memorybarrierprocesswide.c`) would be compiled with `nfcc`.

The unresolved C++ symbols after the 34 objects are the `GCToOSInterface` and `GCEvent` members (in items 2), the
`IsSupportedInstructionSet` pair (`isa_detection.cpp`), the two vxsort entry points, `GCContractDescriptorWKS`, and
some `operator new`/`delete` and `__cxa_*` helpers. The C side needs minipal's mutex, time and memory-barrier functions,
`g_pageSizeUnixInl`, and libc. The sized `__atomic_*` calls come from libatomic at link time.

## Known gaps

- The gcc backend on macOS (Apple clang, which compiles EDG's C there) rejects the `__sync_*` calls in
  `tests/cases/qbe_coreclr_gc_forms.cpp`: EDG passes a `volatile void *` to them. Linux gcc accepts it. The test is marked
  `MACOS-XFAIL-gcc`. The QBE path is unaffected, because `qbe-prep.rb` rewrites those calls.

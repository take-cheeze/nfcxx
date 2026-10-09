# Hexagon feasibility: EDG C through a Hexagon-capable toolchain

Status: **partly done.** The generated C compiles for Hexagon, and a Linux user-mode Hexagon
binary built from it runs under `qemu-hexagon` (HVX included). The Hexagon SDK, the QuRT and
hexagon libC runtimes and a Hexagon linker are unavailable here; the EH runtime is a small one of our own (section 3a).
EDG has no Hexagon target, so the code is generated for `linux_riscv32` (ILP32, little-endian)
and checked against clang's Hexagon ABI.

## 1. Tool inventory

Everything below was run in this container (Ubuntu 24.04, GCC 13.3.0).

| Probe | Command | Result |
|---|---|---|
| Compiler | `clang --version` | Ubuntu clang 18.1.3 (x86_64 host) |
| Hexagon backend | `clang -print-targets \| grep -i hexagon` | `hexagon - Hexagon` |
| Hexagon compile | `clang --target=hexagon-unknown-linux-musl -ffreestanding -c x.c` | works (ELF32, `Qualcomm Hexagon`, flags 0x60) |
| LLVM Hexagon | `llc --version` | `hexagon - Hexagon` registered; `llvm-mc -triple=hexagon` available |
| Hexagon tools on PATH | `compgen -c \| grep -i hexagon` / `ls /usr/bin \| grep -i hexagon` | none (no `hexagon-*-clang`, `hexagon-sim`, `hexagon-elf-*`) |
| Hexagon linker | `ld.lld -m elf32hexagon ...`, `ld.lld -m hexagon ...` | `unknown emulation`. GNU `ld.bfd -V` lists only x86_64-style emulations. **No Hexagon linker.** |
| SDK | `env \| grep -i sdk`, `ls /opt` | no Hexagon SDK, no `QNX/QuRT`, no `HEXAGON_ROOT` |
| apt | `apt-cache search hexagon` | only unrelated packages (libh3, games). No `clang-hexagon`, `binutils-hexagon-linux-gnu`, `hexagon-sdk`, `qemu-system-hexagon` candidates. |
| qemu (system) | `apt-get download qemu-system-misc` + `dpkg-deb -c` | 8.2.2 package has no hexagon entries |
| qemu (user) | `apt-get download qemu-user` + `dpkg-deb -c` | **`/usr/bin/qemu-hexagon`** (8.2.2, Linux user mode). Extracted with `dpkg-deb -x` into scratch; not installed. |
| 32-bit x86 | `clang --target=i686-linux-gnu -ffreestanding -c` | works; `gcc-multilib`/`libc6-dev-i386` not installed |
| Network | `curl https://softwarecenter.qualcomm.com/` | `CONNECT tunnel failed, response 403` (proxy refused). Not bypassed. |

Conclusion: the only Hexagon execution path available here is `clang --target=hexagon` for
compilation, plus `qemu-hexagon` for Linux user-mode execution. Linking needs a small flattener
(`tests/hexagon/flatlink.rb`), because no Hexagon linker exists.

Get the emulator (no system-wide install):

```
mkdir -p build/hexagon/debs && cd build/hexagon/debs
apt-get download qemu-user                       # Ubuntu noble qemu 8.2.2
dpkg-deb -x qemu-user_*.deb ../qemu              # build/hexagon/qemu/usr/bin/qemu-hexagon
export QEMU_HEXAGON=$PWD/../qemu/usr/bin/qemu-hexagon
$QEMU_HEXAGON --version
```

## 2. EDG target configuration

### How EDG picks a target

- The built `cpfe` has a fixed table of target configurations compiled in (`TARGET_CONFIGURATION_1..7`,
  from `3rd/edg/cmake/macro-conf/support/platform/linux-x86_64/base.cmakedef`):
  `linux_x86_64` (legacy default), `linux_i686`, `win64`, `win32`, `linux_aarch64`, `linux_armv7`,
  `linux_riscv64`, `linux_riscv32`. `cpfe --target bogus` is rejected with
  `no "bogus" --target configuration exists`. **No Hexagon entry.**
- Each target's sizes, alignments, `TARG_*` values and jmp_buf layout come from
  `cmake/macro-conf/support/target/<name>/base.cmakedef`, compiled into `cpfe`.
- `--target <name>` also selects the predefined-macro table `lib_<name>/predefined_macros.txt`
  relative to the current directory. Those tables are keyed by compiler tag (`gcc`, `gpp`,
  `clang`, `!clang`, `all`). The base dirs are `3rd/edg/bases/docker/dev-env/{gcc,clang,gcc-i686}`;
  `setup-edg.sh` copies `gcc` to `build/edg-base`.
- `eccp.sh` does the same with `--target` (it sets `LIBDIR=lib_<target>` and reads
  `EDG_C_TO_OBJ_DEFAULT_OPTIONS_<target>` from `edg_eccp_config`, e.g. `-m32 -march=i686` for
  `linux_i686`). Those flags only affect the C compiler step, not the generated C.

### The recipe (no change to `3rd/edg`)

`scripts/gen-c-target.sh` does exactly what the nfcxx driver does, with `--target` added:

```
cd build/edg-base && build/edg/bin/cpfe -D_POSIX_SOURCE -D__CHAR_BIT__=8 --c++23 --g++ \
    --target linux_riscv32 --sys_include=<include_c++> --gen_c_file_name=out.c file.cpp
```

### Why `linux_riscv32` is the stand-in, and what differs

`linux_riscv32` is the only compiled-in 32-bit little-endian configuration (linux_i686 is 32-bit
but x86 with an i386 ABI). Measured against clang's Hexagon ABI with
`tests/hexagon/layout.sh` (26 facts: `sizeof`/`_Alignof`/`__builtin_offsetof` of structs with
char, long long, double, pointer, short, float, function pointer, plus `size_t`, `wchar_t`,
`void*`, `long`):

| Fact | EDG `linux_riscv32` | clang Hexagon | Agree |
|---|---|---|---|
| `char` signedness | `__CHAR_UNSIGNED__` | `__CHAR_UNSIGNED__ 1` | yes |
| pointer / `long` / `size_t` / `wchar_t` | 4 / 4 / 4 / 4 | 4 / 4 / 4 / 4 | yes |
| `long long`, `double` alignment | 8 / 8 | 8 / 8 | yes |
| `struct {char; long long}` size, `offsetof` | 16, 8 | 16, 8 | yes |
| `long double` size / alignment | **16 / 16** | **8 / 8** | **no** |
| `struct {long double; char}` size | **32** | **16** | **no** |
| jmp_buf (EH runtime) | 36 × `long long` (288 B) | unknown: needs hexagon libC `jmp_buf` | unverified |

Only the `long double` rows disagree. The `tests/hexagon/layout.sh` probe leaves `long double`
out. The probe does discriminate: with `EDG_TARGET=linux_i686` it fails against the Hexagon clang
(EDG's i686 gives `struct {char; long long}` 12 bytes, Hexagon 16).

Other generated-C differences from the default x86_64 config (diffed for `tests/cases`): `size_t` is
`unsigned` (not `unsigned long`), the vtable pointer is `const int *` (not `const long *`), and the
EH jmp_buf is `long long[36]`. EDG also emits explicit padding (`char __dummy[N]`) computed from
its own layout, so the C compiler must agree with EDG's layout, which the probe checks.

### What a real `linux_hexagon` target needs (not built)

To make `long double` and `TARG_JMP_BUF_*` exact, EDG needs a real target. Copy `linux_riscv32`'s
`base.cmakedef` to `support/target/linux_hexagon/` in a scratch copy of `3rd/edg`, change
`TARG_SIZEOF_LONG_DOUBLE`/`TARG_ALIGNOF_LONG_DOUBLE` to 8 and the `LDBL` constants to IEEE double,
set `TARG_JMP_BUF_NUM_ELEMENTS` from the Hexagon libc, add `TARGET_CONFIGURATION_8=linux_hexagon`
in `linux-x86_64/base.cmakedef`, add `lib_linux_hexagon/predefined_macros.txt` (from `clang -dM`
for hexagon; `__hexagon__`, `__HEXAGON_ARCH__`, `__CHAR_UNSIGNED__`, sizes), and rebuild `cpfe`
(~3 min). This is the next step if `long double` or real jmp_buf layout matters. Nothing here
modifies `3rd/edg`.

Notes from the generated C:

- The only inline asm is a top-level `__asm__(".align 2");` (20 occurrences). clang accepts it.
- Generated C relies on C's UB, so the Hexagon compile needs `-fwrapv -fno-strict-aliasing`, the
  same flags as `--backend=gcc`. Without `-fwrapv`, `tests/cases/signed_overflow_wraps.cpp` returns 0 on
  Hexagon at `-O2` (verified: plain `-O2` exit 0, with `-fwrapv` exit 1).
- Runtime references: `memcpy`, `memset`, `strlen`, `_ZdlPvj` (sized delete), `_setjmp`,
  `__throw_setup`, `__throw`, `__exception_caught`, `__destroy_exception_object`,
  `__curr_eh_stack_entry`, `__eh_curr_region`, `__caught_object_address`, `__catch_clause_number`,
  `_ZTVN10__cxxabiv117__class_type_infoE` and `_ZTVN10__cxxabiv120__si_class_type_infoE`
  (the typeinfo vtables), plus `_Z…` template instances that only `edg_prelink` creates.

## 3. Experiments

### Generated C and clang for Hexagon

`tests/cases/*.cpp` plus two new HVX-style int16 kernels (`tests/cases/hvx_add_i16.cpp`,
`hvx_mul_i16.cpp`: local-array loops, no tables, so data-free). All generate with
`scripts/gen-c-target.sh -t linux_riscv32` and compile with
`clang --target=hexagon-unknown-linux-musl -ffreestanding -fno-pic -O2 -fwrapv -fno-strict-aliasing`
(all 10 compile; `exceptions` gives one warning, a non-void function without a return, same as x86).
Expected-exit values were computed in Python and checked against the host build
(`./nfcxx` with the QBE and gcc backends: both give 67 and 184).

### Running on qemu-hexagon

Hexagon Linux user-mode binaries need a linker, which this container lacks, so
`tests/hexagon/flatlink.rb` does the minimum: one `.text` section, `R_HEX_B22_PCREL` (call/jump)
relocations resolved within `.text`, and an ELF32 EXEC header around it. It refuses (with
`SKIP-data` / `SKIP-undef`) anything it cannot handle. A small `tests/hexagon/stub.c` supplies `memcpy`,
`memset` and `_start` (`trap0(#0)` syscalls, `exit_group(main())`).

Results (`tests/hexagon/run.sh`, `QEMU_HEXAGON` set):

| Case | Result | Note |
|---|---|---|
| `constexpr_static` | ok (exit 120) | |
| `signed_overflow_wraps` | ok (exit 1) | needs `-fwrapv` |
| `hvx_add_i16` | ok (exit 67) | |
| `hvx_mul_i16` | ok (exit 184) | |
| `hvx_vaddh` (hand-written, `-mhvx -mhvx-length=128b`) | ok (exit 192) | real HVX `vadd` in the object |
| `float_neg_switch` | ok (exit 42) | `.rodata` (FP constants, switch table) via `R_HEX_32_6_X`/`R_HEX_6_X` |
| `struct_libc` | ok (exit 9) | `.rodata.str1.1`; `strlen` is defined in `stub.c` |
| `raii_templates_class` | ok (exit 7) | `.data`/`.bss`; EH bookkeeping globals in `stub.c`, `-G0` |
| `virtual_dispatch` | ok (exit 23) | vtables in `.data` (`R_HEX_32`); typeinfo vtables are stubs in `stub.c` |
| `exceptions` | ok (exit 15) | `tests/hexagon/eh_rt.c` supplies EDG's EH ABI (section 3a) |
| `templates_lambdas` | ok (exit 12) | `scripts/gen-c-target.sh` passes `-tused` (instantiate used templates), as the host driver does; no `edg_prelink` needed |

All 11 Hexagon checks in this table run (the generated cases and HVX).
Compile-only mode (no qemu) compiles all 11.

Layout: `tests/hexagon/layout.sh` passes (26 facts); with `EDG_TARGET=linux_i686` it fails
(verified), so it isn't vacuous.

HVX: clang's builtins work without the SDK. `__builtin_HEXAGON_V6_vaddh_128B` with
`-mhvx -mhvx-length=128b` gives `v0.h = vadd(v0.h,v1.h)` in assembly, and runs under `qemu-hexagon`
(qemu user mode runs HVX). Note `llvm-objdump` needs `--mattr=+hvx,+hvx-length128b` to show vector
instructions; without it the disassembly looks scalar.

### Host regression

`tests/run.sh` passes all 10 cases including the two new ones.

### 3a. Exception handling on Hexagon

How EDG's generated C does exceptions (as read from `3rd/edg/lib_src/throw.c`, `eh.h` and the generated C of
`tests/cases/exceptions.cpp`; this is the IA-64-ABI flavour, typeinfo = `{vptr, name}`):

- Each function that has something to unwind pushes a `kind=1` (function) entry on a linked EH stack
  (`__curr_eh_stack_entry`, entries live in the caller's frame). It points at a static region table
  (`{dtor, handle, next_region, flags}`), the table of object addresses, and an array table; the current region
  (`__eh_curr_region`, an index into the table) says which locals are alive. The previous region is saved in the
  entry and restored on exit.
- A `try` pushes a `kind=5` entry holding a `jmp_buf` (`long long[36]`, from `TARG_JMP_BUF_*`), the static catch
  table (`{typeinfo, flags, ptr_flags}`, last entry flagged `0x20`) and the region number at entry. The code is
  `if (_setjmp(buf) == 0) { body } else if (__catch_clause_number == 1) { e = __caught_object_address; ... }`.
- `throw X` becomes `p = __throw_setup(&typeinfo, sizeof, flags)` (or `_dtor`/`_ptr` variants), construct `X` into `p`,
  then `__throw()`. `__throw` marks the in-flight exception (a throw-stack entry whose marker is pushed on the EH
  stack), walks the EH stack for a matching try (pass 1: exact type, `...`, pointers, void*, derived-to-base via
  `__si_class_type_info`), then unwinds (pass 2): for every function entry in between it runs the region chain
  (destructors, array destructors, delete for failed `new`, local-static guard reset), restores `__eh_curr_region`, and
  finally cleans the try's own region down to its saved number, sets `__catch_clause_number` and
  `__caught_object_address`, and `longjmp`s to the try's buffer. The catch body ends with `__exception_caught()` (after the
  parameter copy) and `__destroy_exception_object()`, which runs the exception object's destructor and frees it; `throw;` is
  `__rethrow()`. Everything else (types, tables) is in the generated C, so the runtime has no compiler-specific unwinder
  and needs no DWARF/`.eh_frame`.

What is supplied here (`tests/hexagon/eh_rt.c`, appended to the generated C of any case that references
`__throw_setup`/`__rethrow`, compiled with `-DNFCXX_EH_RT` so `stub.c` leaves the EH globals to it):
`__throw_setup{,_dtor,_ptr}`, `__throw`, `__rethrow`, `__internal_rethrow`, `__exception_started/caught`,
`__free_thrown_object`, `__destroy_exception_object`, `__call_terminate/unexpected` (exit status 134), a 16 KiB static arena
used as a stack for exception objects, the `_setjmp`/longjmp pair in Hexagon asm (saves r16-r27, fp, lr, sp in the 288-byte
buffer), `typeinfo` objects for the fundamental types (`_ZTIi` etc.) and `__cxa_vec_dtor` (in `stub.c`). The generated C declares the
EH functions/globals with its own struct types, so `eh_rt.c` reaches them through `__asm__("name")` labels.
It is a trimmed port of `throw.c` (the real runtime needs `<stdlib.h>`, `<new>`, `<exception>`, `cxxabi.h`, malloc,
and EDG's own C++ front end to build). Verified beyond the case with a scratch program: unwinding through frames with
class and array locals, rethrow, `catch(...)`, catch by value/const ref, pointers, `void*`, base-class references, throw from a
handler, copy-constructor counts; results agree with the host build.

Not supported (terminates with 134 or does not link): multiple/virtual-base catch matching (`__vmi_class_type_info`),
multi-level pointer qualification conversions, throw specifications / `noexcept` violations, array `new`/`delete` unwinding
(`__cleanup_vec_new_or_delete`), `std::exception`-style library types, and thrown `double`/`float` (soft-float helpers such as
`__hexagon_adddf3` are not provided; unrelated to EH).

`flatlink.rb` gained the relocation forms this code needed: `R_HEX_6_X` on `combine(#s8,##u6)` and duplex `Rd=#u6`,
`R_HEX_16_X` on `add(Rs,##u32)`, `R_HEX_10_X` on `cmp.eq(Rs,##u32)` and `R_HEX_8_X` on `combine(##u32,#s8)`.

## 4. What blocks real Hexagon

| Blocker | Status here | What is needed |
|---|---|---|
| Hexagon SDK (`hexagon-clang`, `hexagon-sim`, `hexagon-ld`, headers) | unavailable; softwarecenter.qualcomm.com refused by the proxy (403) | the SDK, installed locally |
| Hexagon linker | no `ld.lld`/`ld.bfd` Hexagon emulation | `hexagon-ld` from the SDK/binutils, or lld with Hexagon support |
| Hexagon libc (`stdlib.h`, `string.h`, `setjmp.h`, `stdio.h`, `pthread.h`) | none; `runtime.h` fails with `'stdlib.h' file not found` under clang | hexagon libc (QuRT or musl-hexagon) headers + `libc.a` |
| QuRT (bare-metal runtime) | none | SDK QuRT for the `hexagon-sim`/DSP target. QuRT has its own startup and no Linux syscalls, so the qemu stub does not apply |
| EH runtime (`lib_src`) | `tests/hexagon/eh_rt.c`, a trimmed port of `lib_src/throw.c`, with its own `_setjmp`/longjmp (section 3a) | for a real target: compile `lib_src/*.c` with the libc above; fix `TARG_JMP_BUF_NUM_ELEMENTS` (36 `long long` in riscv32) to the real `jmp_buf` size |
| Template instantiation | `scripts/gen-c-target.sh` emits only the first pass | run `edg_prelink` for the target (as eccp does) |
| `long double` | 16 bytes in EDG vs 8 in Hexagon | a real `linux_hexagon` target (section 2) |
| `hexagon-sim` / real DSP | not run | SDK |

## 5. HVX intrinsics plan for Path B

Path B (DESIGN.md) lowers EDG's IL to our own IR, then emits C+HVX (or QBE/SPIR-V/WGSL). The
Hexagon plan:

1. **Intrinsics without SDK headers.** Use clang's builtins directly:
   `__builtin_HEXAGON_V6_<op>_128B` (or `_64B` with `-mhvx-length=64b`), with
   `HVX_Vector` as `int __attribute__((vector_size(128)))` (verified:
   `v0.h = vadd(v0.h,v1.h)`). `-mhvx` and `-mhvx-length=128b` are required; the predefined macros
   are `__HVX__`, `__HVX_ARCH__`, `__HVX_LENGTH__`. The SDK's `hvx_hexagon_protos.h` is not needed.
2. **Vector shapes.** One vector is 128 bytes (64 `int16`, 32 `int32`). Path B must emit loops
   with a scalar tail (or masked stores via `vmaskedstore`) instead of assuming multiples of 64
   elements. The int16 kernels in `tests/cases/hvx_*.cpp` are the test shape.
3. **Alignment and memory ops.** Aligned vector loads and stores need the IR to guarantee alignment;
   otherwise use the unaligned forms. clang 18 does not recognize `__builtin_HEXAGON_V6_vmemu_128B` or
   `__builtin_HEXAGON_V6_vmem_128B` (checked), so `tests/hexagon/hvx_vaddh.c` loads with plain vector
   dereferences, which clang lowers to HVX loads. `__builtin_HEXAGON_V6_vaddh_128B` is recognized.
4. **UB and overflow.** HVX integer ops wrap. Path B's IR should state the wrap explicitly and
   emit `-fwrapv`-equivalent semantics, not depend on the C compiler's flags. The `(short)` cast in
   the int16 kernels is an explicit wrap.
5. **Testing.** `qemu-hexagon` runs HVX (verified). Path B tests can follow `tests/hexagon/run.sh`
   with the same flatlink path, as long as the kernel has no data relocations.
6. **Open:** HVX `vmpy`-style multiply widening (`V6_vmpyh`) needs a check against qemu for
   the exact lane semantics before relying on it; not done here.

## 6. Findings outside the Hexagon work

- **Header include bug in `setup-edg.sh`.** Its `cp -r` copies `bases/.../gcc/include`, a *relative*
  symlink (`../../../../include_c++/`), so `build/edg-base/include` dangles. Any `--sys_include` based
  on `build/edg-base/include` finds nothing, so `#include <exception>` fails
  (`cannot open source file "exception"`, rc 4) for both `./nfcxx --emit-c` and `./nfcxx file.cpp`
  (both checked). Passing the real
  directory (`3rd/edg/include_c++`) works. This is not changed here (outside this task); a one-line fix
  is `ln -sfn "$src/include_c++" "$base/include"` after the copy. `scripts/gen-c-target.sh` works around it.
- EDG ships only about 15 C++ headers in `include_c++/` (`exception`, `new`, `typeinfo`, `cxxabi.h`, ...; no `<cstdio>`, `<cstddef>`, `<stdlib.h>`).
  Programs that need them need a freestanding shim or the real libc headers.

## 7. Reproduction

```
scripts/setup-edg.sh                                     # build/edg (cpfe, edg_prelink, libC.a)
scripts/gen-c-target.sh -t linux_riscv32 tests/cases/hvx_add_i16.cpp   # generated C to stdout
tests/run.sh                                             # host regression (QBE backend)
tests/hexagon/layout.sh                                  # EDG layout vs clang Hexagon ABI
tests/hexagon/run.sh                                     # Hexagon compile of every case (+ qemu if QEMU_HEXAGON is set)
QEMU_HEXAGON=$PWD/build/hexagon/qemu/usr/bin/qemu-hexagon tests/hexagon/run.sh
```

Manual single-case run:

```
mkdir -p build/hexagon
scripts/gen-c-target.sh -t linux_riscv32 -o build/hexagon/k.c tests/cases/hvx_add_i16.cpp
cat tests/hexagon/stub.c >> build/hexagon/k.c
clang --target=hexagon-unknown-linux-musl -ffreestanding -fno-pic -O2 -fwrapv -fno-strict-aliasing \
      -w -c build/hexagon/k.c -o build/hexagon/k.o
scripts/mrb tests/hexagon/flatlink.rb build/hexagon/k.o build/hexagon/k.elf _start
chmod +x build/hexagon/k.elf && $QEMU_HEXAGON build/hexagon/k.elf; echo "exit $?"   # expect 67
```

## Open toolchain route (what CI runs)

Everything needed is open source and installs from Ubuntu's archive; the Qualcomm SDK is not needed:

- `clang-19` (upstream LLVM 19, has `--target=hexagon`; the Qualcomm 19.x toolchain dropped `hexagonv65`).
- `qemu-user-static` (provides `qemu-hexagon-static`, Linux user mode).
- No Hexagon linker: `lld-19` has no Hexagon emulation (`ld.lld -m elf32_hexagon` is rejected), so
  `tests/hexagon/flatlink.rb` still produces the flat image.

Run it the way CI does:

    CLANG=clang-19 QEMU_HEXAGON=qemu-hexagon-static tests/hexagon/run.sh

Result: 13 passed (`constexpr_static`, `exceptions`, `float_neg_switch`, `qbe_builtins_libc`, `qbe_global_ctor`,
`raii_templates_class`, `signed_overflow_wraps`, `struct_libc`, `templates_lambdas`, `virtual_dispatch`, and the HVX
kernels `hvx_add_i16`, `hvx_mul_i16`, `hvx_vaddh`), 3 skipped (`qbe_atomics`, `qbe_gnu_forms`, `qbe_int3_break`:
they include hosted C++ headers that the `linux_riscv32` EDG configuration lacks).

`flatlink.rb` lays every `SHF_ALLOC` section out in one `PT_LOAD` (`.text` first, `.bss` last, memsz > filesz)
and applies the absolute relocations clang emits for `-fno-pic -G0`: `R_HEX_32` (data words) and the
constant-extender forms (`R_HEX_32_6_X` on `immext`, `R_HEX_6_X`/`R_HEX_16_X`/`R_HEX_8_X` on the consumer
instruction). The field positions were checked against `llvm-mc` encodings of `##value`. Compiling with `-G0`
means no small-data GP is needed, so GP-relative relocations are not supported (they SKIP).
`.hexagon.attributes` is metadata and is ignored (non-`SHF_ALLOC` sections are not loaded).

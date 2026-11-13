# Building the Linux kernel with nfcc

`scripts/linux-qemu.sh` builds a minimal x86_64 Linux 6.8 (tinyconfig plus a serial console, the initramfs loader,
proc/sysfs/devtmpfs) with a static busybox initramfs, and boots it under `qemu-system-x86_64`:

```
scripts/linux-qemu.sh               # KCC=gcc: the host gcc builds the kernel
KCC=nfcc scripts/linux-qemu.sh      # nfcc builds every C file (CC=nfcc), the boot banner names nfcc
```

The kernel source is the 6.8 tarball from the Ubuntu archive (kernel.org is not reachable from every sandbox), unpacked
once to `DIR/src/linux-6.8`; each compiler gets its own output tree (`DIR/out-gcc`, `DIR/out-nfcc`).

## The plan: gcc backend first, then QBE file by file

The qbe backend cannot build the kernel today. Beyond C the front end does not yet accept (statement expressions,
global register variables such as `register unsigned long current_stack_pointer asm("rsp")`), the kernel must be
compiled `-mno-sse -mno-red-zone -mcmodel=kernel ...`, and QBE has no switch for those. So the kernel is first built by
nfcc's **gcc backend**, which gets every option through, and files then move to the qbe backend one at a time, each
move checked by booting.

## `NFCXX_GCC_PASSTHROUGH=1`

By default nfcc refuses the same options on both backends -- anything that changes meaning or code generation in a way
QBE cannot honour (`-funsigned-char`, `-ffreestanding`, `-mno-sse`, unknown `-f`/`-m` options, ...) -- so a program
that builds on one backend builds on the other. With `NFCXX_GCC_PASSTHROUGH=1` and the gcc backend, those options go
to gcc instead:

- every `-m` option (`-mcmodel=kernel`, `-mno-red-zone`, `-mno-sse`, `-m16` for the real-mode boot code, ...), the
  semantic `-f` options, unknown `-f` options and `--param`;
- every `-f` option, the harmless ones too, so the distribution gcc's own defaults (`-fstack-protector-strong`, `-fPIE`,
  `-fcf-protection`) do not stand where the kernel turned them off;
- in command-line order: gcc takes the last of `-fno-PIE ... -fPIC` and of `-mcmodel=kernel ... -mcmodel=small`, which
  the vDSO build relies on (its objects must be PIC).

Two fixes apply to every build: an assembly input given with `-x assembler`/`-x assembler-with-cpp` keeps its language
(the kernel's `as-version.sh` probes `-x assembler-with-cpp /dev/null`), and `-MD`/`-MMD` on an assembly input writes
the dependency file (kbuild's `fixdep` reads one for every `.S`).

`tests/c/cc-mode.sh` covers the mode (section 7b) and the two fixes.

## Moving files to QBE: `NFCXX_QBE_TRY`

```
KCC=nfcc QBE_TRY='*' scripts/linux-qemu.sh     # try every C file on qbe; DIR/qbe-try.log has the outcome per file
```

With `NFCXX_QBE_TRY="PATTERN ..."` on the gcc backend, nfcc hands each compile to `scripts/qbe-try`:

1. The compile runs as asked on the gcc backend. Its object is the fallback and the reference, and its dependency file
   is the one kbuild reads.
2. A `-c SRC.c -o OBJ` compile whose source matches a pattern runs again on the qbe backend with `NFCXX_QBE_KERNEL=1`.
3. The qbe object replaces the gcc one only if it matches it: the same global and weak definitions (name, binding,
   type, kind of section), no undefined symbol the gcc object does not also need, and the same special allocated
   sections (`.init.text`, `.initcall6.init`, `__param`, ...) -- an undefined symbol the gcc-built kernel defines
   (NFCXX_QBE_KSYMS, from `DIR/out-nfcc/vmlinux.o` when there is one) is not missing --, and no reference from lasting code (not `.init.*`,
   `.exit.*`, `.meminit.*`, `.ref.*`, `.head.text`) to init code or to an undefined symbol that gcc's object makes only
   from init code (the kernel's modpost refuses lasting code that calls `__init` code; gcc's inlined `always_inline`
   helpers make none, cproc's out-of-line copies can). An object with `.head.text` (the kernel's `__head` code,
   which runs identity-mapped, before the kernel's page tables) is compiled with QBE's `-A` (`NFCXX_QBE_ABS=1`):
   an address is an absolute 32-bit immediate and a load or store of a global is rip-relative, gcc's kernel model,
   which `fixup_pointer()` expects. Otherwise the gcc object stays. Either way one line goes
   to `NFCXX_QBE_LOG`: `qbe SRC`, or `gcc SRC: reason` (the first error, or what differed).

The kernel then has to boot. The log is the migration's to-do list: sorted by reason, it says which missing feature
keeps the most files on gcc. When the kernel does not boot, `scripts/linux-qemu-bisect.sh` finds the qbe objects that
break it without compiling anything: each has a gcc twin in `DIR/out-nfcc`, and it puts sets of them back, links and
boots again, and halves the set until the culprits are left (an `asm` input tied to a narrower output was loaded at
the output's width, truncating the user pointer of `put_user`, and `/init` failed with EFAULT).

### `NFCXX_QBE_KERNEL=1`: the kernel's options on the qbe backend

The qbe backend still refuses every option it cannot honour. In this mode it accepts the ones it can:

- honoured by cproc: `-funsigned-char` (cproc `-u`), `-fshort-wchar` (`-W`: wide literals are `unsigned short`),
  `-ftrivial-auto-var-init=zero` (`-z`: automatic objects without an initializer are zeroed);
- honoured by QBE (a commit of the fork, 3rd/qbe): `-fno-asynchronous-unwind-tables` (`qbe -U`: no `.cfi` directives,
  so no `.eh_frame`, which the kernel's link would otherwise take as an orphan section);
- true of QBE's code by construction: `-mno-red-zone` (QBE reserves its frame with `subq` and never addresses below
  `%rsp`), `-fno-stack-protector`, `-fno-jump-tables`, `-fno-delete-null-pointer-checks`, `-fno-strict-overflow`,
  `-fno-strict-aliasing`, `-fno-common`, `-fno-PIE` (QBE writes PIC code, which a non-PIE link takes; the linker relaxes
  its `@GOTPCREL` loads, and the kernel's linker script checks no GOT is left), and the alignment and tuning options;
- checked: `-mno-sse`, `-mno-80387` and the other no-floating-point options. QBE has no such switch, so `qbe-cc` refuses
  a translation unit whose QBE code names an SSE or x87 register or an x87 instruction. Inline asm is the program's own,
  as with gcc. With `-mno-sse` qbe-cc runs `qbe -n` (a commit of the fork, 3rd/qbe): QBE moves an integer between two stack
  slots through `%rax` (saved and restored around the move, the function keeping an `%rbp` frame) instead of
  `%xmm15`, and a variadic function's prologue saves no `%xmm` registers (no caller passes floating-point arguments;
  a `va_arg` of a floating type would be floating-point code, which the check refuses).

The translation unit is preprocessed exactly as gcc preprocesses it (gcc's predefined macros and all of the kernel's
options, linemarkers kept so errors name the header), so cproc sees the same code as the reference object, and cproc
runs with `-p`: unreferenced internal
functions and data are dropped, as gcc does. The kernel's headers define hundreds of static inline functions per file,
and keeping the unused ones would leave references to symbols this configuration does not have. A construct cproc can
only refuse inside a dropped function (an asm operand only inlining could satisfy, bitops.h's `"i"(1 << (nr & 7))`)
is not an error, and that function's asm thunks are dropped with it (docs/notes/inline-asm.md).

### Status (tinyconfig, Linux 6.8)

615 C files are tried; all 615 are in the kernel from the qbe backend, and it boots and runs the init script's
checks (processes, pipes, files, signals): no C file of the kernel is gcc's. The migration went 3, 8, 19, 42, 47, 87,
252, 403, 541, 571, 589, 593, 600, 613, 615 over the
runs that took the blockers below away, largest first; the ones that mattered beyond compiling were:

- `asm goto`, constant-argument clones of `always_inline` functions (`_static_cpu_has`'s `"i"(1 << (bit & 7))`),
  and `gnu_inline` (an `extern inline` defines no symbol), which together moved about 400 files;
- GNU `cleanup` at scope exit (`guard()`): cproc ran it only on a throw, and files using guards stayed on gcc
  only by the accident of their unwind tables;
- `#pragma pack` (ACPI's tables, 31 files) and `mode(byte)` on an enum, which cproc ignored: layouts that differed
  from gcc's without an error -- now honoured, and the attributes that change meaning in ways cproc does not
  implement (`vector_size`, `naked`, `interrupt`, other modes, ...) are refused;
- what gcc folds away and the configuration does not define: calls of `{ return C; }` and `{}` functions, `x & 0`,
  `x && 0`, and code only reachable through a constant condition (docs/notes/cproc-nfcxx.md);
- a `used` static living with its function (an unused helper's `__ADDRESSABLE()` of a static-call key), and helpers
  of init and `__ref` code placed in `.ref.text`, where gcc's inlined copies are;
- qbe-try's own checks: undefined symbols (objdump gives them no binding flag, so none was seen), lasting code
  that calls init code (modpost), and the symbol indexes of a gcc-built kernel;
- the real-mode boot code (`arch/x86/boot`, `-m16 -march=i386 -mregparm=3`): QBE's i386 targets (the fork's
  doc/i386.txt), cproc's i386 layout, `-V` volatile accesses and inline asm as thunks, 20 files,
  of which 13 need the asm thunks;
- two kernels that linked and did not run, found by `scripts/linux-qemu-bisect.sh`: `put_user`'s pointer
  truncated by an `asm` input tied to a narrower output (`/init` failed with EFAULT), and `head64.c`'s
  `.head.text`, which runs before the kernel's mapping: QBE's GOT loads became absolute addresses there;
- the last two: `head64.c` with QBE's `-A` (gcc's kernel-model addressing) and cproc's address clones (its
  `native_load_gdt(&startup_gdt_descr)` loads the GDT rip-relative, as gcc's inlined copy does, not through an
  absolute pointer the identity mapping does not cover), and `fpu/signal.c` with cproc's constant propagation
  through locals and clones for the constant arguments it finds (`ia32_fxstate`, cleared with
  `&= IS_ENABLED(CONFIG_IA32_EMULATION)` and false at `__fpu_restore_sig()`'s one call), which take the calls of
  `convert_from_fxsr` and `convert_to_fxsr`, not in this configuration, away (docs/notes/cproc-nfcxx.md).

The real-mode files are built with `-mpreferred-stack-boundary=2`, which keeps 4-byte stack alignment; QBE's i386 target
does not realign the stack, so a local with a larger alignment is only aligned when the caller keeps 16 bytes. The boot
code has none. `arch/x86/realmode/rm` is not built in this configuration and is untested.

## Path B (`NFCXX_BACKEND=pathb`): how many C files it builds

nfcc has a Path B route (EDG's C front end -> typed IR -> QBE, no cproc; docs/notes/nfcc-pathb.md). It is the default on x86-64 Linux
when the harness is built (a unit it cannot take is made by gcc), and it takes the kernel's option set. `KCC=nfcc NFCXX_BACKEND=pathb` no longer stops at the first file (it did: `-nostdinc`,
`-isystem DIR`, `-funsigned-char`, `-fshort-wchar`, `-ffreestanding` and the `-m*` options were refused, 0 of 615).
Each option of the kernel's command line is in one of three classes:

| class | options | what nfcc does |
|---|---|---|
| honoured by Path B | `-nostdinc`, `-isystem DIR`, `-idirafter DIR` (the include path of the front end: `-nostdinc` drops the host's directories, `-isystem $(gcc -print-file-name=include)` gives `<stdarg.h>`); `-funsigned-char` (EDG's `--unsigned_chars`; the IR's `char` is renamed `unsigned_char`); `-fshort-wchar` (the headers' `wchar_t` is `unsigned short`; EDG types `L"x"` as `int`, so a unit with a wide literal is gcc's); `-ffreestanding` (`__STDC_HOSTED__` is 0); `-fno-asynchronous-unwind-tables` (QBE `-U`) | passed to `scripts/pathb-cc` |
| checked | `-mno-sse`, `-mno-sse2`, `-mno-80387`, `-msoft-float` | QBE runs with `-n`; the unit's assembly is refused (status 5) if it names an SSE or x87 register or instruction, as `qbe-cc` does. Refused units go to gcc with `NFCXX_PATHB_FALLBACK=gcc` |
| no effect on QBE's code | `-mno-red-zone`, `-mcmodel=kernel`, `-mpreferred-stack-boundary=`, `-mtune=`, `-mno-mmx`, `-mno-3dnow`, `-mno-avx`, `-mskip-rax-setup`, `-fno-PIE`, `-fno-stack-protector`, `-fno-jump-tables`, `-fno-delete-null-pointer-checks`, `-fno-strict-overflow`, `-fno-strict-aliasing`, `-fwrapv`, `-fno-common`, `-fno-allow-store-data-races`, `-fno-optimize-sibling-calls`, `-fno-function-sections`, `-fconserve-stack`, `-fcf-protection=none`, `-fstrict-flex-arrays=`, `-falign-*` (the reasons of `NFCXX_QBE_KERNEL=1` above) | dropped on Path B |
| changes meaning, no Path B equivalent | `-m32`, `-mregparm=3` without `-m16`, `-ftrivial-auto-var-init=zero`, `-fshort-enums`, `-iquote`, `-imacros`, `-Wa,*` options other than the ones passed on (below), `-mindirect-branch=thunk*`, `-mfunction-return=thunk*`, `-mharden-sls=`(not `none`), `-mstack-protector-guard*` with a stack protector in effect, any `-f`/`-m` option nfcc does not know | **the compile is gcc's**, with every `-f`/`-m` option given in command-line order; never dropped |

`NFCXX_PATHB_LOG=FILE` records `pathb SRC` or `gcc SRC: reason` per compile, the migration's to-do list as `NFCXX_QBE_LOG` is
for qbe-try. `scripts/nfcc-pathb-measure.sh` counts the gcc compiles apart from the built ones. `tests/nfcc/run.sh` covers
each option (include path, the signedness and `CHAR_MIN`, `wchar_t`, `__STDC_HOSTED__`, `.cfi`, the `-mno-sse` check, each
gcc fallback, against gcc's own result).

Two things this does not do. A kernel with `CONFIG_INIT_STACK_ALL_ZERO` passes `-ftrivial-auto-var-init=zero` to every
file, and every file is then gcc's (Path B does not zero automatic variables; cproc did). And the kernel was not built in the
session that made this change (the sandbox does not run `make` on a downloaded tree, and the task said not to): the
option handling is measured on single files and on the kernel's option list, not on the 615 files. The next measurement is
`KCC=nfcc NFCXX_BACKEND=pathb NFCXX_PATHB_FALLBACK=gcc NFCXX_PATHB_LOG=DIR/pathb.log scripts/linux-qemu.sh`, or
the replay below with the real options in `NFCC_MEASURE_FLAGS`.

### Measured: the compile commands of a gcc build, replayed on Path B

Method: build the tinyconfig tree with gcc (`make O=out ARCH=x86_64 CC=logcc bzImage`, where `logcc` appends its
directory and arguments to a log and runs gcc), then replay each `-c` line of the log with `NFCXX_BACKEND=pathb nfcc -c`:
the `-I`/`-D`/`-U`/`-include` options kept, `-isystem DIR` as `-I DIR`, and `-nostdinc`, `-m*`, `-f*`, `-W*`, `-O*`, `-g*`
dropped (so the numbers say what Path B builds, not that the objects would boot; this replay predates the option handling
above, which honours or checks most of the dropped options). 615 translation units (616 counting the
one that has no `.c` of its own).

| state | builds | refused |
|---|---|---|
| before | 538 | 77 |
| after the commits of this branch | 570 | 45 |

The causes the branch fixed, one regression case each in `tests/pathb-kernel/` (compared with gcc by its `run.sh`):

- `rq_pin_lock`: a statement expression whose value is an empty struct reached the back end as an aggregate constant
  (`stmt_expr_empty_struct.c`);
- `simple_offset_add`, `resource_string`, `tty_default_fops`, `task_bp_pinned`, `*_pmu_init`, `ZSTD_create*`: a designated
  compound literal keeps its `ck_designator` entries in the constant (`designated_compound_static.c`);
- `__wake_q_add`, `mark_oom_victim`, `nested_table_alloc`, ...: a `null` asm operand was typed with the bare word `ptr`
  (`asm_pointer_operand_null.c`);
- `show_smap_vma_flags`, `inat_get_group_attribute`: a repeated string over the rows of a 2-D static array
  (`static_range_string_rows.c`);
- `univ8250_console_init`: two static objects that point at each other (`static_address_cycle.c`);
- `unexpected phi instruction` (chip.c, mmap.c, io_apic.c, static_call.c): the pointer-cell load of an external function's
  address emitted ahead of a phi (`phi_extern_function_address.c`);
- `0xffff888000000000 out of range of signed 32bit displacement` (namei.c, realmode/init.c): QBE folds `add CONST, x` into
  a displacement without a 32-bit check (`index_wide_constant_base.c`).

- `drivers/video/console/vgacon.c`: QBE propagates a pointer constant through copies and phis into the displacement of the
  access that uses it, unchecked (`phi_wide_pointer_constant.c`). A pointer constant that does not fit in 32 bits is loaded
  from a one-word data cell (the cleaner fix is a 32-bit check in the QBE fork's `amd64/isel.c`, outside this repo).

### Measured: the kernel's own option set, `NFCXX_PATHB_FALLBACK=gcc`

A second measurement, with the options of the kernel's own `.cmd` files kept (`-mno-sse`, `-funsigned-char`, `-fshort-wchar`, ...;
only `-ftrivial-auto-var-init=zero` is dropped, which sends every file to gcc), the 614 translation units of a tinyconfig tree
compiled by `nfcc -c` with `NFCXX_BACKEND=pathb NFCXX_PATHB_FALLBACK=gcc NFCXX_PATHB_LOG=FILE`. A file the log names as gcc's was
not built by Path B:

| state | built by Path B | gcc's |
|---|---|---|
| before | 226 | 388 |
| after | 581 | 33 |

What the 388 were (355 of them refusals, the rest the 33 below), and what fixed each (regression cases in `tests/c/inline_asm_goto_always_inline*.c`,
`tests/c/inline_asm_local_address_input.c` and `tests/nfcc/run.sh`):

- 321: the volatile access helpers (`__pathb_vld_*`, `__pathb_vst_*`) were all emitted into every unit that has a volatile
  access, the `float` and `double` ones too (`movss`, `movsd`), and `-mno-sse` refuses a unit with SSE code. Only the operations
  a unit uses get a helper now (`volatile_helpers` in `scripts/pathb-ssa-qbe.rb`).
- 32: `_static_cpu_has` (`asm goto` with `"i"` operands of an `__always_inline` function's parameter). Two causes, both hidden
  behind a fallback: `pathb-cc` emits the unoptimized IR when the optimized one is refused, and that IR cannot hold the function
  (its operands are not constants without the inliner), so the unit failed with the second message and the first was never
  shown (it is now: `the optimized IR is refused (REASON), using the unoptimized IR`). (1) The inliner's budgets (`--max-callee`,
  `--max-growth`) left the call in a large unit, and (2) the address operand `&((const char *)boot_cpu_data.x86_capability)[bit >> 3]`
  is an `offset` (a literal byte count) and then an `index` by a folded value, which `asm_symbol_of` read as a constant
  only for the index. A function with an `immv` or `symv` operand is now inlined whatever its size and the module's growth.
- 1: the address of a local as an input of a general asm block (`"D"(&val)`, `int3_selftest`): the operand is a slot name
  with no declared type.
- 1: a function's address converted to an integer after inlining (`wrmsrl_cstar((unsigned long)entry_SYSCALL32_ignore)`):
  `conv_lines` had no type for a `&"fn"` operand.

The 33 that remain are gcc's by design: 20 compile with `-m16 -mregparm=3` (the real-mode boot code, Path B's own since the section below), 8 with
`-Wa,-mrelax-relocations=no` (`arch/x86/boot/compressed`), 5 have a wide character or string literal under `-fshort-wchar` (EDG
types them `int`). Not covered here: a Path B object of a file that uses `ASM_CALL_CONSTRAINT` (`"+r"(current_stack_pointer)`,
`register unsigned long current_stack_pointer asm("rsp")`) has an undefined reference to `current_stack_pointer`, which gcc's
object does not: the register variable is a global of the IR, so the kernel link of such an object fails (page_alloc.o is one).
The measurement counts compiles, not links.

What is still refused is inline asm (`asm-template`, `asm-operands`, an `"i"` operand that is not a constant). The real-mode
boot code (`arch/x86/boot`, `-m16`) is Path B's now: next section.

### Measured: the real-mode boot code (`-m16 -march=i386 -mregparm=3 -mpreferred-stack-boundary=2`) on Path B

`scripts/pathb-cc --i386 --regparm=3 --m16` (docs/notes/nfcc-pathb.md, "The 32-bit x86 target") builds it; nfcc gives a compile with
`-m16` to it instead of to gcc. Method: Linux 6.8, tinyconfig, the compile command of the kernel's `REALMODE_CFLAGS` (arch/x86/Makefile) and
`-D_SETUP`, the include path of `LINUXINCLUDE`, replayed with `scripts/nfcc-pathb-measure.sh` (`NFCC_MEASURE_FLAGS`) on the C files of
`arch/x86/boot` (21: `apm.c` is compiled although tinyconfig does not build it; `mkcpustr.c` is a host program) and of
`arch/x86/realmode/rm` (6, built only with `CONFIG_ACPI_SLEEP`: not in this configuration):

| | builds | refused |
|---|---|---|
| `arch/x86/boot` | 21 of 21 (12, 17 and 19 on the way, with the fixes below) | none |
| `arch/x86/realmode/rm` | 6 of 6 | none |

The generated headers the files include were made by hand, not by `make` (the sandbox does not build a downloaded tree): the
asm-generic wrappers of `arch/x86/include/generated/asm`, `utsrelease.h`, `utsversion.h`, `compile.h`, and a `cpustr.h` with the shape of
`mkcpustr`'s but a short table (`cpu.c`'s code does not depend on its content). gcc builds every file with the same command lines. The causes
Path B had to fix, in the order they came: the asm helpers for the 32-bit registers (13 of the files have inline asm); a tied
asm operand that is a pointer and an integer (`absolute_pointer()` in `boot.h`); `%esp` in a template (`main.c`); a `bool` output (`CC_OUT(nz)` in
`string.c`, `CC_SET(nz)` setting the flag with `setnz`); a global's address narrowed to 16 bits (`memory.c`, `video-vesa.c`).

What was checked beyond building: each object's global symbols equal gcc's (plus the helpers `__pathb_*`; Path B calls `memcpy` and `memset`
where gcc inlined them, and `copy.S` has them); and the kernel's own `string.c`, `printf.c` and `cpuflags.c` were run in real mode under
`qemu-system-i386` (`tests/pathb-i386/realmode.sh` with `REALMODE_SRCS`): `sprintf` with `%d %u %x %s %c %08x %5d %-5d %lu %llu %llx %lld`,
`simple_strtoull`, `kstrtoull`, `atou`, `strcmp`, `strncmp`, `memcmp`, `strlen`, `strnlen`, `strchr`, `strstr`, `has_eflag`,
`get_cpuflags` and `cpuid_count` write the same bytes to the debug console as the same files built by gcc `-m16`. The setup image was **not** built
or booted as a whole (that needs `make bzImage`, which the sandbox does not run on a downloaded tree): `header.S`, `bioscall.S`, `copy.S`
and `pmjump.S` are assembly, `tools/build` was not run.

The size is the open problem: 26.5 KB of text for the 21 boot files with Path B (after `ld -r` merges the identical COMDAT helpers) against 13.7 KB
with gcc `-Os`, and the setup code of an image may be 32 KB (`SETUP_SECT_MAX` is 64 sectors in `tools/build.c`). The
tinyconfig has about 2 KB of assembly besides, so it is near the limit, and a configuration with more (`CONFIG_X86_APM_BOOT`, `CONFIG_EDD`) may be over it.
QBE keeps a frame pointer in every function and has no size mode; the helpers of the asm templates are calls.

What was measured instead, as the task allows: the C files of `tests/c` (69 files; they cover the GNU C the kernel
uses: statement expressions, `asm`, `asm goto`, `cleanup`, packed/aligned layouts, `case` ranges, `_Float16`) with
`scripts/nfcc-pathb-measure.sh tests/c/*.c`. `tests/realworld` holds no C sources of its own (its Lua and
mruby sources are downloaded by the run scripts), so nothing there was measured.

**52 of 69 build; 17 are refused** (exactly the 17 `XFAIL-pathb` files of `tests/c/run.sh`):

| count | status | reason (the SSA route's message) |
|---|---|---|
| 5 | 3 | `unsupported stmt asm-template` (inline asm templates the route cannot emit: `leaq %c1(%2)`, ...) |
| 4 | 3 | type `std::floatN_t` (`_Float16`) |
| 2 | 3 | operator unsupported (`_Float16` arithmetic) |
| 2 | 3 | asm template: a `%` that is not an operand |
| 1 | 3 | global (an initializer the route cannot emit) |
| 1 | 3 | `unsupported stmt switch-case-range` (`case 1 ... 5:`) |
| 1 | 3 | `unsupported stmt cleanup-attribute` (`__attribute__((cleanup))`; the kernel's `guard()`) |
| 1 | 1 | front end: `_Float16` constant (`float16_golden.inc`: a value that does not fit, then an ArgumentError in the IR reader) |

For the kernel, the groups that matter are inline asm (templates, `asm goto`, flags outputs: 7 of the 17 files), `cleanup`
(`guard()`: used all over the kernel), and `case` ranges; `_Float16` the kernel does not use. These, plus the option
handling above, are what decides the next Path B follow-ups for a kernel build.

### Measured: why gcc took each compile of the Linux 6.8 tinyconfig kernel on Path B

`KCC=nfcc NFCXX_BACKEND=pathb NFCXX_PATHB_FALLBACK=gcc NFCXX_PATHB_LOG=FILE` logged, per compile, why gcc took it. Besides
`-ftrivial-auto-var-init` (handled apart) the reasons, with the number of compiles each one sent to gcc, and what Path B
does with the option now (decided on the QBE output being assembled by the host `cc`):

| option | compiles | decision | why |
|---|---|---|---|
| `-Wa,--fatal-warnings` | 32 | **Path B**: given to the assembler step | it is an assembler option, and Path B assembles QBE's output with the host `cc` (`scripts/pathb-cc --as-opt`, which `nfcc` fills from `-Wa,*`); it now also makes a warning of the assembler on QBE's text fatal |
| `-Wa,-mrelax-relocations=no` | 9 | **Path B**: given to the assembler step | same; `tests/nfcc/run.sh` shows the effect on an `-fPIC` object (`R_X86_64_GOTPCREL` instead of `R_X86_64_REX_GOTPCRELX`) |
| `-m32 -mregparm=3` | 21 | gcc (kept) | the 32-bit boot code: QBE has no i386 target |
| `-m16` / `-m32` | 8 | gcc (kept) | the real-mode boot code, same |
| `-mindirect-branch-cs-prefix` | 20 | gcc (kept) | retpoline thunks: QBE has no indirect-branch thunks, a kernel built with them needs gcc for correctness |
| `-mindirect-branch-register` | 8 | gcc (kept) | same |
| `-mrecord-mcount` | 4 | gcc (kept) | the `__mcount_loc` section ftrace patches; QBE writes no `mcount` call or section |
| `-mstack-protector-guard-reg=fs -mstack-protector-guard-symbol=__stack_chk_guard` | 4 | **Path B only when no stack protector is in effect**; gcc when one is | the options say where the canary lives, so they change nothing without `-fstack-protector*` (the last of it and `-fno-stack-protector` decides, wherever the guard options stand); with a protector QBE has no canary to place |
| `-fzero-call-used-regs=used-gpr` | 4 | gcc (kept) | register zeroing on return is a hardening the object's behaviour includes; QBE has none |
| `-fpatchable-function-entry=N` | 4 | gcc (kept) | the nop padding ftrace and live patching rewrite; QBE cannot emit it |
| `-frandomize-layout-seed-file=` | 4 | gcc (kept) | struct layout randomization (a gcc plugin option); the layout is part of the ABI |
| `-ftrivial-auto-var-init=pattern` | 4 | gcc (kept) | handled apart |

Only the `-Wa,*` options that the assembler takes with the same meaning for QBE's x86-64 text are passed on
(`--fatal-warnings`, `--noexecstack`, `-W`, `--no-warn`, `-mrelax-relocations=yes|no`, `-mx86-used-note=yes|no`); any other
(`--32`, `--defsym`, `-march=`, ...) keeps that compile gcc's, and the log says "assembler option Path B does not pass on".
A comma list (`-Wa,a,b`) must be wholly known. With `-S` there is no assembler step and the options have no effect, as with gcc.

While checking these, one gap was closed: `-mindirect-branch=`, `-mfunction-return=`, `-mharden-sls=` and
`-mbranch-protection=` were dropped as "no effect on QBE's code", which is wrong for the retpoline values (a kernel built with
`-mindirect-branch=thunk-extern` got plain indirect calls). Now only `-mindirect-branch=keep`, `-mfunction-return=keep`,
`-mharden-sls=none` and `-mbranch-protection=none` (which ask for the plain code) are dropped; the others are gcc's, and on the
qbe backend an error. Not changed: a plain `-fstack-protector*` is still ignored by Path B (it was before); a kernel with
`CONFIG_STACKPROTECTOR` is gcc's only through the guard options, so that is the next thing to make gcc's if it matters.
`tests/nfcc/run.sh` has a case for each row.

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

nfcc has a Path B route (EDG's C front end -> typed IR -> QBE, no cproc; docs/notes/nfcc-pathb.md). It is opt-in, and it
takes the kernel's option set. `KCC=nfcc NFCXX_BACKEND=pathb` no longer stops at the first file (it did: `-nostdinc`,
`-isystem DIR`, `-funsigned-char`, `-fshort-wchar`, `-ffreestanding` and the `-m*` options were refused, 0 of 615).
Each option of the kernel's command line is in one of three classes:

| class | options | what nfcc does |
|---|---|---|
| honoured by Path B | `-nostdinc`, `-isystem DIR`, `-idirafter DIR` (the include path of the front end: `-nostdinc` drops the host's directories, `-isystem $(gcc -print-file-name=include)` gives `<stdarg.h>`); `-funsigned-char` (EDG's `--unsigned_chars`; the IR's `char` is renamed `unsigned_char`); `-fshort-wchar` (the headers' `wchar_t` is `unsigned short`; EDG types `L"x"` as `int`, so a unit with a wide literal is gcc's); `-ffreestanding` (`__STDC_HOSTED__` is 0); `-fno-asynchronous-unwind-tables` (QBE `-U`) | passed to `scripts/pathb-cc` |
| checked | `-mno-sse`, `-mno-sse2`, `-mno-80387`, `-msoft-float` | QBE runs with `-n`; the unit's assembly is refused (status 5) if it names an SSE or x87 register or instruction, as `qbe-cc` does. Refused units go to gcc with `NFCXX_PATHB_FALLBACK=gcc` |
| no effect on QBE's code | `-mno-red-zone`, `-mcmodel=kernel`, `-mpreferred-stack-boundary=`, `-mtune=`, `-mno-mmx`, `-mno-3dnow`, `-mno-avx`, `-mskip-rax-setup`, `-fno-PIE`, `-fno-stack-protector`, `-fno-jump-tables`, `-fno-delete-null-pointer-checks`, `-fno-strict-overflow`, `-fno-strict-aliasing`, `-fwrapv`, `-fno-common`, `-fno-allow-store-data-races`, `-fno-optimize-sibling-calls`, `-fno-function-sections`, `-fconserve-stack`, `-fcf-protection=none`, `-fstrict-flex-arrays=`, `-falign-*` (the reasons of `NFCXX_QBE_KERNEL=1` above) | dropped on Path B |
| changes meaning, no Path B equivalent | `-m16`/`-m32` (the real-mode boot code), `-ftrivial-auto-var-init=zero`, `-fshort-enums`, `-iquote`, `-imacros`, `-Wa,*`, any `-f`/`-m` option nfcc does not know | **the compile is gcc's**, with every `-f`/`-m` option given in command-line order; never dropped |

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

What is still refused is inline asm (`asm-template`, `asm-operands`, an `"i"` operand that is not a constant) and the real-mode
boot code (`arch/x86/boot`, `-m16`).

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

### Linking Path B objects into a kernel

Compiling is not linking: the first link of a tinyconfig kernel whose C files are Path B's showed what the objects lacked (`make vmlinux`
with `CC=nfcc NFCXX_BACKEND=pathb NFCXX_PATHB_FALLBACK=gcc`, then `bzImage`, booted under qemu). Each cause has a case in
`tests/nfcc/run.sh` (and `tests/c/global_register_sp.c`, `tests/c/weak_override_gcc.c`):

- `register unsigned long current_stack_pointer asm("rsp")` (`ASM_CALL_CONSTRAINT`) is the register: a read is the IR form `(sp)` (a weak
  `__pathb_sp` helper, `leaq 8(%rsp), %rax`), a `"+r"` asm operand on it is a temporary, no symbol is defined or referenced.
- A failed check (division by zero, a shift out of range, ...) in a unit with no hosted libc (`-ffreestanding`, `-nostdinc`, `-mno-sse`) is
  `ud2` (`pathb-cc --trap-checks`, qbe `hlt`), not a call of `abort`, which the kernel does not have; hosted units keep the abort.
- `__attribute__((section))` on a function (the kernel's `__init`, `__head`, `noinstr`) places it; such a function is inlined only into a
  caller of the same section. `__attribute__((used))` keeps a static function (asm-offsets.c's `common()`), `(weak attr)` definitions are weak,
  roots of pruning and never inlined (`__weak sched_clock`), a static local with `used` (`__ADDRESSABLE`) is emitted where declared (objtool
  looks the static call key up in the object's symbol table), the target of an `alias` attribute is a root (`SYSCALL_DEFINE0`).
- C inline semantics: an inline function with an `extern` (or non-`inline`) declaration is one strong external definition (`inline int
  task_curr()`, `unlzma`), no longer a weak copy that pruning dropped.
- The inliner reaches what gcc's constant propagation does, so that the calls in compiled-out branches are gone: `always_inline` callees
  and static functions with one call site are inlined whatever their size, bool parameters no longer stop an inline, an empty `noinline`
  stub is inlined, and `pathb-ssa-build` prunes again after the e-graph folded the constant branches (a static function only a dead branch
  reached was emitted, with its undefined references).
- `__builtin_isdigit` is inline (gcc folds it; the libc function does not exist in a kernel).
- `-fno-PIE` addresses an external function by its symbol, not through a data cell (a cell in `.data` pointing into `.init.text` is a modpost
  section mismatch); `-fPIE` with `-mno-sse` (the boot decompressor, which allows no run-time relocations) is gcc's compile.
- `.head.text` (head64.c's `__startup_64`, which runs identity-mapped before the page tables) is assembled with `qbe -A`: the addresses of
  globals are the link-time absolute ones, as gcc's kernel model writes them. An asm memory operand on a global is the object itself,
  `sym(%rip)` (`lgdt startup_gdt_descr`), and the helper of an asm that names a symbol is placed in its caller's section.

State of the build: `vmlinux` links with no undefined or duplicate symbol, and `bzImage` is built (617 compiles went to Path B; the rest are the kbuild probes and the real-mode boot code, which
gcc compiled). The `.data.rel.ro` sections QBE writes for constant data with relocations are orphans to the kernel's linker script (a
`ld: warning`, `CONFIG_LD_ORPHAN_WARN_LEVEL="warn"`), and objtool warns about QBE's `leave; jmp` sibling calls and unannotated noreturn calls.
The kernel boots through `setup_arch`, the console, the scheduler and the initramfs unpacking to `Run /init`, where the first `execve` stops
in `__mutex_add_waiter` with a bad list head (not yet explained: the layouts of `task_struct`, `signal_struct` and `mutex` are those of gcc's).

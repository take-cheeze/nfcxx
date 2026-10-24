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
   helpers make none, cproc's out-of-line copies can). Otherwise the gcc object stays. Either way one line goes
   to `NFCXX_QBE_LOG`: `qbe SRC`, or `gcc SRC: reason` (the first error, or what differed).

The kernel then has to boot. The log is the migration's to-do list: sorted by reason, it says which missing feature
keeps the most files on gcc.

### `NFCXX_QBE_KERNEL=1`: the kernel's options on the qbe backend

The qbe backend still refuses every option it cannot honour. In this mode it accepts the ones it can:

- honoured by cproc: `-funsigned-char` (cproc `-u`), `-fshort-wchar` (`-W`: wide literals are `unsigned short`),
  `-ftrivial-auto-var-init=zero` (`-z`: automatic objects without an initializer are zeroed);
- honoured by QBE (scripts/qbe-nfcxx.patch): `-fno-asynchronous-unwind-tables` (`qbe -U`: no `.cfi` directives,
  so no `.eh_frame`, which the kernel's link would otherwise take as an orphan section);
- true of QBE's code by construction: `-mno-red-zone` (QBE reserves its frame with `subq` and never addresses below
  `%rsp`), `-fno-stack-protector`, `-fno-jump-tables`, `-fno-delete-null-pointer-checks`, `-fno-strict-overflow`,
  `-fno-strict-aliasing`, `-fno-common`, `-fno-PIE` (QBE writes PIC code, which a non-PIE link takes; the linker relaxes
  its `@GOTPCREL` loads, and the kernel's linker script checks no GOT is left), and the alignment and tuning options;
- checked: `-mno-sse`, `-mno-80387` and the other no-floating-point options. QBE has no such switch, so `qbe-cc` refuses
  a translation unit whose QBE code names an SSE or x87 register or an x87 instruction. Inline asm is the program's own,
  as with gcc. With `-mno-sse` qbe-cc runs `qbe -n` (scripts/qbe-nfcxx.patch): QBE moves an integer between two stack
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

615 C files are tried; 3 move, among them `arch/x86/lib/misc.c`, which is linked into `vmlinux`, and the kernel boots.
What keeps the rest on gcc, by the number of files whose first error it is:

| files | reason |
| ----: | ------ |
| 426 | the global register variable `register unsigned long current_stack_pointer asm("rsp")` (`asm/asm.h`) |
|  85 | `aligned` (65) and `packed` (20) attributes in positions cproc does not take yet |
|  51 | the `asm` keyword (GNU C; cproc knows `__asm__`) |
|  20 | `-m16`: the real-mode boot code, which stays on gcc |
|   9 | `__builtin_choose_expr` |
|   8 | `-fno-function-sections`, `-foptimize-sibling-calls` (2) not yet accepted |
|   3 | data symbols: QBE gives them no `@object` type, so the definitions differ |

Each fix exposes the next first error, and statement expressions (`({ ... })`, used by `min`, `max`, `container_of`)
and volatile accesses (`READ_ONCE`) are expected behind these.

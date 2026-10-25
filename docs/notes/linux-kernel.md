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
   which runs identity-mapped and depends on how gcc addresses symbols) always stays. Otherwise the gcc object stays. Either way one line goes
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

615 C files are tried; 593 of them are in the kernel from the qbe backend, and it boots and runs the init script's
checks (processes, pipes, files, signals). The migration went 3, 8, 19, 42, 47, 87, 252, 403, 541, 571, 589, 593 over the
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
- two kernels that linked and did not run, found by `scripts/linux-qemu-bisect.sh`: `put_user`'s pointer
  truncated by an `asm` input tied to a narrower output (`/init` failed with EFAULT), and `head64.c`'s
  `.head.text`, which runs before the kernel's mapping and now always stays on gcc.

What keeps the other 22 on gcc, by the number of files whose first error or difference it is:

| files | reason |
| ----: | ------ |
|  20 | `-m16`: the real-mode boot code, which stays on gcc |
|   1 | `fpu/signal.c`: the qbe object calls `convert_to_fxsr`, which this configuration does not have, behind a constant gcc carries into the static `__fpu_restore_sig()` by inlining it (`ia32_fxstate`); QBE folds within a function only |
|   1 | `.head.text` |

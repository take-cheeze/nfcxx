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

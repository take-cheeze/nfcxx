# Panthera as a performance model for an Ampere (AArch64) target

Status: proposal. Nothing here is built, run or measured. No test script covers any claim in this note.

## What Panthera is

[AmpereComputing/panthera](https://github.com/AmpereComputing/panthera) is Ampere's open-sourced CPU
performance model: a cycle-accurate, trace-driven simulator of the AmpereOne cores and SoCs (configurations such
as `siryn.cfg`, Furiosa core). It reads a time-ordered instruction stream captured from a running AArch64
workload and reports IPC and other metrics, rollups and event streams. The repository is a public reference
release (single commit "Initial open-source commit", C++23/SystemC, CMake and a top-level Makefile, Nix for the
toolchain). Ampere states that it provides no commercial support or roadmap for it.

What the repository says about inputs (read, not run):

- Instruction streams (`*.is.xz`) come from a QEMU plugin with a patched Linux kernel
  (`doc/tracing/tracing-simple.md`, `doc/tracing/tracing-simpoints.md`), or from a native AArch64 host with
  perf-semihosting (`doc/micros/benchmarks.md`).
- `panthera sim` runs one trace against one configuration; `panthera rollup` and `cheetah` run many.

What it is not: Panthera does not generate or rewrite code. It measures the code it is given.

## What nfcxx has for an AArch64 target

Read from the tree; these are the only relevant facts found:

- The driver's default on x86-64 Linux is Path B; elsewhere it is the qbe backend. The `--target=` option
  describes EDG layouts for `linux_aarch64`, `linux_armv7`, `linux_riscv64` and `win64`, for generated C only
  (`docs/notes/freestanding.md`). That is a layout target, not a tuned code-generation target.
- `.github/workflows/ci.yml` has an arm64 job, and `emulators.yml` runs generated code for `linux_aarch64` under
  qemu-user. Whether an arm64 host builds and runs the whole test matrix was not checked for this note.
- No code-generation tuning for AmpereOne (scheduling model, instruction selection, alignment) was found.

## Proposed use

Panthera would close a measurement loop for codegen work, not optimize code by itself:

1. Build nfcxx on an AArch64 host (or confirm the arm64 CI job covers the path).
2. Compile a small kernel with nfcxx and with gcc or clang at the same flags.
3. Capture an instruction stream of each binary, with Panthera's QEMU plugin or on-host tracing.
4. Run `panthera sim` on each stream with an AmpereOne configuration and compare cycles and IPC.
5. Use the difference to find codegen problems in nfcxx, fix them, and repeat.

Caveats:

- The setup is heavy: Nix, SystemC, a QEMU build with the Panthera plugin, a kernel patch, and large traces.
- The result is a relative signal for one kernel on one modelled core. It says nothing about code size or
  absolute speed on silicon, unless the model is calibrated against it (the authors state it is, but this note
  has not checked the calibration data).
- Each step needs a decision: which kernels, which configuration, and what counts as an improvement.

## Open questions

- Which workload to start with, and whether it should be one of the public Perf Check 500 traces or a new one.
- Whether the AArch64 backend work belongs in nfcxx's qbe path or in a separate emitter.
- Whether a Panthera build on the CI runners is worth its cost, or whether it stays a by-hand check.

## Next step

Build Panthera's `sim` tool and one configuration on an AArch64 host, then run one existing trace to confirm
the toolchain works. Only after that, pick a kernel and do steps 1 to 4 above.

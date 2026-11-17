# Restructuring the driver flow into `scripts/nfcxx.rb`

Status: plan for the work that B4 to B8 need. Follows docs/notes/driver-body-port.md.

## Why a restructure

The port plan moves one stage at a time, but in the bash driver several stages share state that is set in one place
and used in another, and the cleanup of temporary directories and the trace are EXIT traps. A stage cannot leave bash
while its callers still run in bash. So the Ruby driver must run the flow itself, with the steps that are not yet
ported delegated to the frozen bash oracle (tests/driver-body/nfcxx-bash), in the order the oracle runs them.

## The shape

- `scripts/nfcxx.rb` holds the flow as Ruby methods in the oracle's order: records, early exits, setup, CUDA and
  `.cpp2`, cache, the eccp call, the second pass, and the exit.
- Each method is either ported (Ruby code, with a differential test) or delegated (it calls the frozen oracle for the
  part it has not ported, then reads the state back from the driver-state record that the oracle writes).
- Temporary directories are created and removed by Ruby (`Dir.mktmpdir` and `ensure`). The EXIT trap of a delegated
  part is the oracle's own; the Ruby side removes only directories it made.
- Exports go into the environment of the child processes Ruby spawns (`spawn(env, ...)`), not into a shell.

## Order

1. **The flow skeleton.** `scripts/nfcxx.rb` runs the whole oracle as one delegated step (done in B2). Next: split the
   oracle's flow at the stage boundaries listed in docs/notes/driver-body-port.md, and make each boundary a Ruby method
   that delegates. Test: tests/driver-body/run.sh, plus the full suites on each boundary.
2. **B6, temporary directories and traps.** Ruby creates `cudatmp`, `eccp_dir`, `ctmp`, `tmp` and `ptmp` when a method
   needs them, and removes them in `ensure`. The oracle's EXIT traps stay for the delegated parts. Test: the cleanup
   cases in tests/nfcxx-driver (a failing step leaves no directories behind).
3. **B7, the trace unit and the exports.** `trace_unit` and `NFCXX_TRACE_UNIT` move into the Ruby flow; trace spans
   are written by scripts/trace.rb directly. Test: tests/nfcxx-trace.
4. **B4, CUDA, `.cpp2` and module stages.** The Ruby flow calls scripts/nfcxx-cuda-device.rb, scripts/nfcxx-cpp2.rb and
   scripts/nfcxx-modules.rb itself instead of through bash. Test: tests/nfcxx-cuda-device, tests/nfcxx-modules.
5. **B5, cache and eccp call sites.** The Ruby flow calls scripts/nfcxx-cache.rb and scripts/nfcxx-eccp-plan.rb. Test:
   tests/nfcxx-cache, tests/nfcxx-eccp-plan.
6. **B8, the switch.** `./nfcxx` becomes a shim that runs `scripts/nfcxx.rb`, the Ruby driver is the default, and the
   bash body stays only as the oracle under tests/.

The trace unit and the remaining host probes (B3) are steps 1 and 3 in this order.

## Stop rules

A step that cannot be ported in Ruby without changing the order of a side effect stays delegated, and the note says why.
A failing suite is fixed or the step is reverted; it is not skipped.

# Path B and gcc backend measurement: three kernels

Measured the performance gaps the code reading suggested (docs/notes/relax-ideas.md, "What not to copy" and the backend
comparison). Reproduce: `tests/bench/backend/run.sh` (needs ./nfcxx built: scripts/setup-edg.sh, setup-qbe.sh,
setup-pathb.sh). The kernels are `tests/bench/backend/k_float.cpp`, `k_int.cpp` and `k_branchy.cpp`.

Three builds of each kernel: the Path B default (Path B IR, SSA, e-graph, QBE), `nfcxx --backend=gcc` (gcc -O2 -fwrapv),
and clang++ -O2 -fwrapv as a reference. Each run prints a checksum; all nine builds print the same checksums.

Environment: shared x86-64 Linux host, GCC 13.3 (Ubuntu), clang 18.1.3. Minimum of five runs, seconds.

| Kernel | Path B | gcc backend | clang -O2 |
| --- | ---: | ---: | ---: |
| `k_float`: dot product and saxpy over 16K floats, 20000 rounds | 0.327 | 0.287 | 0.031 |
| `k_int`: byte table lookup and histogram, 64 KiB, 3000 rounds | 0.394 | 0.397 | 0.401 |
| `k_branchy`: branchy update of 16K 12-byte records, 20000 rounds | 0.629 | 0.395 | 0.334 |

Instruction counts in the hot functions (`fnstats.sh`; stack operands counted as `(%rsp)` or `(%rbp)` references):

- `dot` and `saxpy` (float): Path B 16 instructions and 2 vector ops in each; gcc 20 and 4 in `dot`, 16 and 2 in `saxpy`;
  clang 45 and 10, and 63 and 17. Neither nfcxx backend vectorized either loop. clang did.
- `crcish` (int): Path B 48, gcc 22, clang 41. The loop is memory-bound, so the times are equal.
- `step` (branchy): Path B 58 instructions with 4 conditional jumps, 2 cmov and 2 setcc; gcc 40 with 2 jumps and 3 cmov.

Findings:

1. **Vectorization is the largest gap on the float kernel:** about 10x against clang. Neither nfcxx backend vectorizes
   it (no vector pass in Path B or in the pinned QBE, `3rd/qbe` at c40759f).
2. **Compare results are materialized as booleans.** In `step`, Path B computes `x < y` with `cmp; setl; movzbl`, then
   tests the byte with `cmp $0x0` before `cmove`, and tests a masked flag the same way before its branch. gcc uses the
   flags directly. This accounts for the 1.6x gap on the branchy kernel. The fix would be in the SSA-to-QBE emitter
   (`scripts/pathb-ssa-qbe.rb`) or in QBE's handling of compares, and needs no QBE fork change if the emitter can fuse
   a compare with its single branch use.
3. **No spills in the hot functions of these kernels** (no stack operands in `dot`, `saxpy`, `crcish` or `step`). So
   register pressure is not the gap on these three; a kernel with more live values would be needed to test it.
4. **Memory-bound integer loop:** no backend differs. Improvements here would come from the loop structure, not codegen.

Limits: three kernels, one host, minimum of five runs (run-to-run noise is a few percent). Per-kernel stats count the
instructions of the named functions only. gcc's and clang's vectorizers are not controlled by these flags beyond -O2.

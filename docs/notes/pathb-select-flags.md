# Path B: a select's compare keeps its flags (QBE fork)

The branchy kernel (`tests/bench/backend/k_branchy.cpp`, measured in docs/notes/pathb-backend-measurement.md) was 1.6x slower
than the gcc backend. Its `step` function computed `x < y` as a boolean (`setl`, `movzbl`) and tested the byte again before
its `cmov`, because QBE's `ifopt` turns the diamond into a select, and the select's arms (`sub`s) clobbered the compare's flags.

The fix is in the QBE fork (take-cheeze/qbe, `amd64/isel.c`, `selsel`): when the flag-setting instruction next to the select
does not define the condition, the condition's own compare (single use) is regenerated right before the conditional moves.
nfcxx pins the fork at that commit (`3rd/qbe`).

Measured (minimum of five runs, the same host as the measurement note):

| Kernel | Path B before | Path B with the fix | gcc backend | clang -O2 |
| --- | ---: | ---: | ---: | ---: |
| `k_branchy` | 0.627 s | 0.482 s | 0.395 s | 0.334 s |
| `k_float` | 0.344 s | 0.337 s | 0.287 s | 0.031 s |
| `k_int` | 0.397 s | 0.391 s | 0.397 s | 0.401 s |

All checksums are unchanged. `step` now compares with `cmp` directly before `cmov` (no `setl`/`movzbl`). The SSA-to-QBE
regression (`tests/pathb-ssa-qbe/run.rb`, 59 cases) passes, and the fork's 78 `test/*.ssa` files compile with identical output.

The float reduction is still 10x behind clang: no vectorizer in either backend (docs/notes/pathb-backend-measurement.md).

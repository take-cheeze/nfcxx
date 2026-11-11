# QBE emitter parser allocation reduction

`scripts/pathb-qbe-emit.rb` shares two frozen parenthesis strings between
`tokenize` and `parse_forms`. Previously, tokenization allocated each delimiter
with `Integer#chr`, and parsing allocated `"("` and `")"` repeatedly for
comparisons. Delimiters only guide parsing; they never enter the resulting
forms. Quoted strings remain `IRStr` objects, and comparisons still use String
value equality, so callers may also pass independently created token strings.

A gprof run on `tests/pathb-ir/eh_libstdcxx_throw.ir` attributed 1,057,317
`mrb_str_new_cstr` calls to `parse_forms` alone. GC was the largest sampled
runtime cost. Profiling was used to choose the change, not to measure speed.

Local Linux measurements on Ryzen AI MAX+ 395, GCC 15.2, Ruby 3.3.8 and the
pinned script world, with the script baseline from `2560b6b0` and both variants
compiled using bc2cpp `93d17867` (PR #888):

| Median of five alternating runs | Original parser | Shared delimiters |
| --- | ---: | ---: |
| bc2cpp sealed executable, `-O3` | 0.503 s | 0.376 s |
| mruby interpreter | 1.229 s | 1.099 s |

Compiled wall time fell about 25%; interpreted wall time fell about 11%.
These are shared-host observations, not performance thresholds. Timings include
startup and output capture but exclude compiler generation and native builds.
Both release executables were checked for absence of profiling instrumentation.
All 20 timed runs returned status zero, empty stderr and identical 1,352,758-byte
stdout (SHA-256 `c9989cf50053e8bb8830c540bffc43cc3b2d4619ad05aaef7caaf2b31da3c9d2`).

Validation:

- Both original and modified sealed builds pass all 920 script-world cases:
  every IR under `tests/pathb-ir` and `tests/mruby/pathb-edge`, plain, `--safe`
  and `--no-prune`, plus usage and error cases. Stdout, stderr and exit status
  match their mruby interpreter runs; the uncaught-error case excludes its
  backtrace, as the existing runner specifies.
- The same 920 cases compare the original and modified scripts on CRuby.
  Only source filenames and line numbers are normalized for the uncaught error.

Reproduce with `tests/bc2cpp/run_pathb_qbe_emit.sh` on the supported Ruby 4.0
environment. For paired measurements, preserve each release binary and
alternate runs on `tests/pathb-ir/eh_libstdcxx_throw.ir`; compare outputs as well
as elapsed time. Local logs and raw timings are under
`build/bc2cpp/nfcxx-qbe-{before,after}.log` and `build/bc2cpp/nfcxx-qbe-ab.json`.

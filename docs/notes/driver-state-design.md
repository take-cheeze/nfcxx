# Driver state for the link and CUDA steps: what stays in bash and how the rest moves to Ruby

This is the design for stages 4 and 6 of docs/notes/driver-port-plan.md, covering the bash state that the link step
and the CUDA rewrite still share with the driver. Line numbers are for `nfcxx` at b4a10a55 and will drift; the names
are the anchors. The first slice (link_records_rm) is implemented on this branch; the rest is ordered below.

## 1. Where things stand

- `link_records_rm` is already one call of `scripts/nfcxx-link.rb records-rm` (commit 33b74e78). Slice 1 below only
  changes how option-like names are reported.
- `link_args` is one call of `scripts/nfcxx-linkargs.rb edg` (tests/nfcxx-linkargs). Its outputs are `eflist` and
  `userinc`. The bash keeps the refusal exit (status 2) and the end-marker check.
- `cu_prepare`, `cpp2_prepare` and `cu_rewrite` still hold logic in bash: the .cu and .cpp2 loops, the copy naming,
  the in-place replacement of `srcs` and `files`, the rewriter's option list, and two effects on later calls
  (`preinc` and `cuda_opts`). The rewrite itself (the plan and its commands) already runs in
  `scripts/nfcxx-cuda-device.rb --execute`.
- The eccp inputs are already a record protocol (`ecp_group`, `eccp_plan_input`, read by `scripts/nfcxx-eccp-plan.rb`).
  The argument loop is one too (`loop_set`, `loop_append`, fed by `scripts/nfcxx-loop.rb`).

## 2. State inventory

Who writes each piece of state, and who reads it. "args" is the argument loop (`loop_set`/`loop_append` records from
scripts/nfcxx-loop.rb); "defaults" is the top-level assignments before the loop.

| name | kind | written by | read by |
|---|---|---|---|
| `files` | array | args (`files)` in loop_append); `cu_prepare` (`-I$sdir` appended, then .cu paths replaced by copies); `cpp2_prepare` (same); 635 (aarch64 `-D`) | `link_args` (979), `link_records_rm` (998, 1028), `cu_prepare` and `cpp2_prepare` (replacement) |
| `srcs` | array | args; `cu_prepare` and `cpp2_prepare` (replacement of a .cu or .cpp2 by its copy) | `trace_unit` (456), the compile and link steps, `cache_check`, the module steps (`mod_*`), the second pass |
| `cflags` | array | args; `cu_prepare` and `cpp2_prepare` (`-I$sdir`, `-I$cppfront_src/include`); 592-635 (cosmo, Darwin, Path B includes) | `cu_rewrite` (the `--cflag=` list, 286), the E/M paths (470), Path B and gcc compiles |
| `preinc` | array | args (`preinc)`); `cu_rewrite` (appends `lib/cuda/nfcxx_cuda.h` when absent, 296) | `pp_pre` (469), `pre_opts` (616), `pb_pre` (879), 844 |
| `cuda_opts` | array | defaults (empty, 161); `cu_rewrite` (`(--cuda)` when NFCXX_CUDA_EDG_LAUNCH is 1, 295) | `eccp_plan_input` (333) |
| `cu_inputs` | array | args | `cu_prepare` (193-207), the `--emit-hip` path (440), the second-pass test (1035-1042), 850 |
| `cpp2_inputs` | array | args | `cpp2_prepare` |
| `cfiles`, `ppflags`, `sysdirs`, `isa`, `pie_opts`, `diag_opts`, `asanopts` | arrays | args | the steps after 456 (not touched by the CUDA or link functions; listed for the eccp groups) |
| `cu_keep` | scalar | `cu_prepare` (`cu_keep=$dir` for -c, 204) | `cu_rewrite` (`--keep-dir`) |
| `cudatmp` | scalar | `cu_prepare` (`mktemp -d`, 194, and its EXIT trap); `cpp2_prepare` (if unset, 229) | `cu_rewrite` (`--tmp`), `eccp_cleanup` (353), the traps at 674, 786, 900, the second pass (1036-1042) |
| `ctmp` | scalar | the C-input step (786) | `eccp_cleanup` |
| `out`, `outset`, `compile_only` | scalars | args (`-o`, `-c`) | `cu_prepare` and `cpp2_prepare` (object name for -c), 983-1008, `moves` |
| `moves` | scalar | 453: `moves=1` unless `compile_only` | `ecp_args` (315, 613, 1013), `link_args` (979), 1014 |
| `obfuscate`, `ir_opt`, `ir_opt_set`, `promote_slots`, `unroll`, `struct_slots` | scalars | defaults (148-157) and args | `cu_rewrite` (287-289) |
| `cache_dir`, `cache_log_file` | scalars | defaults (139-144) and args | `cu_rewrite` (290-291), `cache_check` (847) |
| `trace_unit` | scalar | 456: `srcs[0]`, else `out`; exported as NFCXX_TRACE_UNIT | `cu_rewrite` (285) |
| `BASHPID` | bash | (the shell) | `cu_rewrite` as `--bash-pid` (the trace's process) |
| `eccp_dir`, `keep_intermediates`, `shared` | scalars | 303, 145, args | `eccp_plan` (348), `eccp_cleanup` (353), `eccp_plan` input |
| `eflist`, `userinc` | arrays | `link_args` (966-970) | `eccp_plan_input` (329, 333) |
| `ecp_list`, `eccp_bin`, `eccp_out` | array, scalars | `ecp_args` (1013) | `eccp_plan_input`, the eccp call |
| `eccp_argv`, `eccp_envs`, `eccp_cd` | arrays, scalar | `eccp_plan` (336-348) | the subshell at 1023-1027 |
| environment | exports | 254 (`NFCXX_SYSTEM_PATHS` from CUDA_HOME), 257 (`NFCXX_SYSTEM_PATHS` for amdgpu), 456 (`NFCXX_TRACE_UNIT`), `NFCXX_TIME_LOG` | the rewriter, `--execute`, `ruby` children (ENV) |
| environment (read) | | the user's and the defaults | `cu_rewrite` (through `--execute`: NFCXX_SM, NFCXX_CUDA_*, NFCXX_OBFUSCATE_*, NFCXX_CU_CACHE, CUDA_HOME, HOME, XDG_CACHE_HOME), `cpp2_prepare` (CPPFRONT_SRC, NFCXX_CU_CACHE, XDG_CACHE_HOME, HOME), `link_args` (CUDA_HOME, via Ruby) |

Results of the four functions, in one line each:

- `link_args COMPILE_ONLY MOVES FILE...`: reads `$1`, `$2` and `files`; writes `eflist` and `userinc` (reset each call);
  a refused option exits 2 with the message; no `z` record exits 1.
- `link_records_rm`: reads `files`; writes nothing but the removals (`<stem>.ii`).
- `cu_prepare`: reads `cu_inputs`, `compile_only`, `out`, `outset`, `srcs`, `files`, `cflags`, `preinc`; writes
  `cudatmp`, `cu_keep`, `cflags` (+=), `files` (+= and replacement), `srcs` (replacement), and through `cu_rewrite`,
  `preinc` (+=) and `cuda_opts` (=). Installs the EXIT trap `rm -rf cudatmp; trace_finish`.
- `cu_rewrite FILE COPY`: reads `cflags`, `preinc`, `cudatmp`, `cu_keep`, `trace_unit`, the driver options and the
  cache settings; writes `cuda_opts` and `preinc`; writes the copy file and the device image cache.

## 3. Order of the driver (what must run before what)

1. The argument loop (args, 380-410 and nfcxx-loop.rb) sets `srcs`, `files`, `cflags`, `preinc`, `cu_inputs`,
   `cpp2_inputs`, `out`, `outset`, `compile_only`, the driver options and the cache settings.
2. 450: the SYCL check (its own run, which re-enters the driver).
3. 453: `moves`. 456: `trace_unit`.
4. 461 `cu_prepare`, 462 `cpp2_prepare`: they rewrite `srcs` and `files`, and add to `cflags` and `preinc`.
   **Must precede** 613 (the `ecp_args` of sysdirs is independent, but the include lists built after 461 are not), 979
   (`link_args` reads the rewritten `files`), 592-635 (pb and gcc flags use `cflags`) and 616 (`pre_opts` reads
   `preinc`).
5. 979 `link_args`, then 983-996 (the `-c` removal of `<stem>.ii` and `<stem>.ti`), 998 `link_records_rm`, 1006
   `cache_check`.
6. 1013 `ecp_args` (the eccp arguments as eccp receives them), 1015 the trap `eccp_cleanup`, 1020 `eccp_plan` (reads
   every eccp group, including `cuda_opts`), the eccp run (1023-1027, in a subshell with `cd` and `export`), 1028
   `link_records_rm`.
7. 1035-1050: the second pass for kernel instances from the host compile (re-runs `$root/nfcxx` with `args0`, the
   arguments as given, and NFCXX_CUDA_HOST_SYMBOLS set). It reads `cudatmp`.
8. 1051 `cache_store`, then the -MD dependency file.

## 4. One shape for passing state to Ruby and back

Use the record protocol that `ecp_group` and `nfcxx-eccp-plan.rb` already use, for both directions.

- **Records.** NUL-terminated. `k NAME` starts a group; each `v VALUE` adds one value. An empty group has no `v`. A
  scalar is a group with one value. A group that is not sent is empty. Values may contain anything except NUL.
- **Input (bash to Ruby).** One helper, `state_put NAME VALUE...`, which generalizes `ecp_group`. A call sends the
  groups it needs on standard input, as `eccp_plan_input` does.
- **Output (Ruby to bash).** Ruby writes every group it changes, in full (replacement, not a diff), then `z`. A refusal
  is `x MESSAGE` (bash prints it on standard error and exits 2, as `link_args` does). The reader stops with status 1
  when it does not see `z`, as `ecp_args`, `eccp_plan` and `link_args` already do.
- **Readers in bash.** Explicit readers per call, as `link_args` has (`case $rec in e*) ...`), not a generic one. Bash
  3.2 (macOS) has no `declare -n` and no associative arrays, and `eval` on names is not needed for a fixed list.
- **Shared Ruby half.** One module, `scripts/driver-state.rb`, with `read_groups` and `write_groups`. `read_groups` is
  now in `nfcxx-eccp-plan.rb`; it moves there. The tests of the existing ports keep passing against it.
- **Working directory and exports** are not state in this protocol: they stay in bash (section 5).

Example, for the cu step (slice 5 below): bash sends `cu_inputs`, `srcs`, `files`, `cflags`, `preinc`, `out`, `outset`,
`compile_only`, `cudatmp`, the driver options, and `BASHPID`; Ruby runs the .cu loop (one `--execute` per input, in
process) and replies with `srcs`, `files`, `cflags`, `preinc`, `cuda_opts`, `cu_keep`, and `z`.

## 5. What stays in bash, and why

- **EXIT traps.** Each `trap ... EXIT` replaces the previous one, so the last trap set decides what is removed. The
  traps at 194 (cu_prepare), 229 (cpp2_prepare), 351-357 (eccp_cleanup, set at 1015), 674, 786 and 900 each remove
  `cudatmp` and others. They stay in bash. Ruby reports directory paths; bash owns the removal.
- **`mktemp -d`** for `cudatmp`, `ctmp`, `eccp_dir`. The path must be known to the trap, so bash creates it and passes
  it down.
- **The eccp subshell.** `cd "$eccp_cd"`, `export` of `eccp_envs`, and the command itself run in bash (1023-1027).
  `trace_start`/`trace_end` stay in bash until stage 8 (trace.sh is sourced).
- **The second pass.** It re-executes `$root/nfcxx` with the caller's arguments and an environment prefix. It stays
  until the driver body is ported (stage 8).
- **`ensure_tool`** (line 278): the rewriter's build at source time, with its lock directory and `sleep`.
- **Exports** (254, 257, 456): the rewriter and the children read them from the environment. Ruby may set its own
  environment for children, but the exports stay in bash (they must exist before `ensure_tool` and the first call).
- **Status chain.** `|| exit $?` after each Ruby call, and the `z` check after each read, stay. A Ruby stop prints its
  own message once; bash does not repeat it.

## 6. Order of the remaining slices

Each slice is one commit with its test. Test names are the existing runners.

**Slice 1: link_records_rm (done on this branch).** `scripts/nfcxx-link.rb` runs `rm -f` itself for a name that starts
with `-`, so rm's own message and status are the bash's (the port's hand-written option messages were wrong for
`--name=value` and for `--force=value`). 13 new cases in tests/nfcxx-link/run.sh; the three that differ on the old port
fail there. Depends on nothing. Test: tests/nfcxx-link (19 to 32).

**Slice 2: the `-c` removal and the protocol.** Move 983-996 (remove `<stem>.ii` and `<stem>.ti` for each source, the
first taking the `-o` name) into `scripts/nfcxx-link.rb` (`compile-clean`), and introduce `scripts/driver-state.rb` and
`state_put` with the reader pattern. Depends on slice 1 (the same file). Test: tests/nfcxx-link (new cases for the
naming rule) and tests/nfcxx-driver.

**Slice 3: cu_prepare's data part.** The `-I$sdir` additions, the replacement of `srcs` and `files` by copies, and the
copy's name (`basename .cu` plus `.cpp`), in Ruby; the bash still calls `cu_rewrite` per input. Depends on slice 2.
Test: tests/nfcxx-cuda-device (stubs) and a new case group in tests/nfcxx-driver.

**Slice 4: cu_rewrite's option list.** The `--cflag`, `--ir-opt`, `--promote-slots` and cache options are built in Ruby
from the record input; Ruby returns `cuda_opts` and `preinc`. Depends on slice 2. Test: tests/nfcxx-cuda-device
(run.sh, key.sh); the frozen bash copy tests/nfcxx-cuda-device/nfcxx-bash it compared against was removed with the bash driver.

**Slice 5: the .cu loop.** `cu_prepare` becomes: bash `mktemp -d` and the trap, then one Ruby call that runs slices 3 and
4 and the `--execute` plan for each input in process, and returns the state. Depends on slices 3 and 4.
Test: tests/nfcxx-cuda-device, and tests/nfcxx-cuda-live where a toolkit exists (not on this machine).

**Slice 6: cpp2_prepare.** The same shape as slice 5 with cppfront as the translator (a program, run from Ruby in a
scratch directory). Depends on slices 3 and 5. Test: a stub cppfront in the driver tests.

**Slice 7: the eccp call.** Merge `ecp_args` and `eccp_plan` into one call that takes the whole state (including
`cuda_opts` and `preinc`, final after slices 4 and 5) and returns the argument vector, the exports, and the directory.
`moves` is still set in bash (453). Depends on slices 4 and 5. Test: tests/nfcxx-ecp-arg, and a new tests/nfcxx-eccp-plan. The run.sh that nfcxx and
scripts/nfcxx-eccp-plan.rb cite does not exist in the tree (see risk 11), so slice 7 writes the bash oracle first.

**Slice 8: link_args and the eccp inputs. Done (PR #1242).** The link arguments are planned with the eccp call:
`scripts/nfcxx-eccp-plan.rb` computes `eflist` and `userinc` from the link's files, and the bash function `link_args` is
gone. The link refusal runs ahead of the compile cache (the eccp path, the plan, and the refusal come before `compile_clean`,
`link_records_rm` and `cache_check`), so a refused link option stops the driver with status 2 even on a cache hit. That
cache behaviour change was approved. Tests: tests/nfcxx-eccp-plan (17), tests/nfcxx-linkargs (49), tests/nfcxx-link (45).

**After slice 8.** The second pass and `cache_store` are stage 2 and stage 8 work; they do not depend on slices 1 to 8.

Stage 4 is done when `link_args`, `link_records_rm`, `eccp_cleanup`, `ecp_args` and `eccp_plan` are one-line calls or
gone (slices 1, 2, 7, 8). Stage 6 is done when `cu_prepare`, `cu_rewrite` and `cpp2_prepare` are one-line calls or gone
(slices 3 to 6).

## 7. Risks

1. **Trap replacement.** Several functions set `trap ... EXIT`, and the last one set wins. Today `eccp_cleanup` (1015)
   replaces `cu_prepare`'s trap when `moves` is 1, and it removes `cudatmp` too; a -c build keeps `cu_prepare`'s trap.
   A port that moves the removal into Ruby, or drops a directory from a trap, leaves temporary directories behind or
   removes a copy a later link needs. Mitigation: keep every trap in bash; test the directories after each run (the
   existing `tests/nfcxx-link` cleanup cases cover the order).
2. **bash 3.2.** The driver runs on macOS (bash 3.2). Do not add `declare -n`, `mapfile`, associative arrays or `${x,,}`.
   The `${arr[@]+"${arr[@]}"}` idiom under `set -u` stays.
3. **The -c copy and the cache key.** The per-user copy directory (`cu_dir`, the SHA-1 of `realpath -m OBJ`) is read by
   the link through the object's record. Changing its key breaks a -c build that is linked later. Keep it byte-identical
   and keep its test (tests/nfcxx-cuda-device/key.sh).
4. **Untested end to end here.** There is no CUDA toolkit on this machine (`CUDA_HOME` is unset), so the device path
   (slices 3 to 6) is checked only with stubs. A regression that only a real toolkit shows would pass here. Run
   tests/nfcxx-cuda-live with a toolkit before slice 5 lands.
5. **Two copies of the reader.** `ecp_group` (bash) and `read_groups` (Ruby) must agree on the record format. Slice 2
   puts the Ruby half in one module; the bash half is one function. A format change touches both.
6. **Silent stops.** `done < <(...)` hides the Ruby status, so every reader needs the `z` check. A reader without it lets
   a crashed helper leave arrays half-filled. Every new reader keeps the check.
7. **The `-c` removal naming rule.** The first source takes the `-o` name (983-996). A port that uses the wrong stem
   deletes another object's `.ti`. Slice 2 adds the cases.
8. **Option-like names in the removal.** `rm` is now run for names that start with `-` (slice 1). This needs `rm` on PATH,
   which bash already requires; if a platform's `rm` words differ, the test's expected output (the bash's own rm) is
   the reference, not the port.
9. **Shared state in the second pass.** The second pass re-runs the whole driver with `args0`. A Ruby call that caches
   results in a file (the device image cache, `cu_dir`) must not change the first pass's answer on the second pass.
10. **Bash status of the rewrite.** `--execute` stops with the bash's status and message (exit 2 and 3 and the
    ptxas 123). A Ruby caller of `--execute` must return those statuses unchanged, so slice 5 cannot wrap them.
11. **Missing eccp-plan test.** `scripts/nfcxx-eccp-plan.rb` and `nfcxx` (337) both cite `tests/nfcxx-eccp-plan/run.sh`,
    which is not in the tree or its history. The eccp command line therefore has no differential test. Slice 7 adds the
    oracle before it changes the command construction.

## 8. What this design does not decide

- Whether `moves` moves to Ruby. It is one line (453) and ecp_args needs it first; it can wait for slice 7.
- The trace spans of the driver's own steps (`trace_start` in cu_prepare, if any). They stay with trace.sh until
  stage 8, and the rewriter's spans are already Ruby's.

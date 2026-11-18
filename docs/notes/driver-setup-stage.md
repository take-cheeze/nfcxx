# The setup stage (B3): the order and the state

This note plans stage B3 of docs/notes/driver-body-port.md: the backend, sanitizer, cosmo, freestanding, host-probe and
target decisions of ./nfcxx. Most of the decisions are already Ruby planners; what is left in bash is the order in which
they run and the variables that carry one planner's answer into the next. Nothing here changes ./nfcxx.

## The steps, in the order the bash runs them

Each step is an `eval` of a planner's statements (or a call that sets variables). "Reads" and "sets" are the bash variables.

1. **Default backend** (`scripts/nfcxx-backend.rb default`). Reads backend, backend_explicit, freestanding, cosmo, emit_c,
   target, preprocess, depmode, shared, the host. Sets backend, default_backend, pb_fs_host.
2. **Sanitizer** (`scripts/nfcxx-asan-c.rb plan`). Reads asan, backend, asanopts. Sets asan_c. Refuses with status 2.
3. **Instantiation** (`scripts/nfcxx-instantiate.rb plan`). Reads instantiate, the host. Sets the instantiation statements.
4. **Cosmo** (`scripts/nfcxx-cosmo-setup.rb setup`), only with cosmo=1. Reads root, backend, backend_explicit, path_b, gnu.
   Sets the cosmo variables. Refuses with status 2.
5. **Freestanding or hosted headers** (`scripts/nfcxx-freestanding-setup.rb plan`). Reads freestanding, gnu, the host, root.
   Sets extra, sys_inc, hosted_libs, gnu. The hosted case reads the host's include directories inside a trace span.
6. **System include directories** (bash: `ecp_args`, then `sys_inc` from ecp_list). Reads sysdirs. Sets sys_inc.
7. **Host cflags** (`scripts/nfcxx-host-cflags.rb plan`). Reads backend, freestanding, the host, root. Sets the cflags.
8. **GNU version option** (`scripts/nfcxx-gnu-opts.rb plan`). Reads dialect, gnu, root. Sets the front end's version option.
9. **k1om toolchain** (`scripts/nfcxx-k1om-env.rb plan`). Reads target, freestanding, backend_explicit, backend, root.
   Sets the k1om environment (only with the target).
10. **Target** (`scripts/nfcxx-target.rb plan`). Reads target, freestanding, emit_c, root, gnu_opts. Sets gnu_opts and the
    target's environment.
11. **Path B override** (bash: `[ $path_b = 0 ] || { backend=pathb; default_backend=0; }`). Sets backend, default_backend.
12. **Backend environment** (`scripts/nfcxx-backend-env.rb plan`). Reads backend, freestanding, pb_fs_host, root. Sets the
    backend's environment.

## What the dependencies force

- **backend** is written by step 1 (the default) and step 11 (the Path B override, bash line 539). The override runs after
  steps 2, 4, 7, 9 and 10 in ./nfcxx, so those planners see the default's backend, not pathb, when --backend is not given but
  NFCXX_PATH=b is set. Only steps 11 and 12 see the overridden value. A Ruby version must keep this order exactly; computing
  the backend once, before the planners, changes the output of cosmo, host cflags, k1om and the target when path_b=1.
- **gnu** is written by step 5 and read by steps 4, 8 and 10. Step 4 (cosmo) runs before step 5, so cosmo sees the gnu the
  command line gave, not the one step 5 picks.
- **gnu_opts** is built by steps 8 and 10 and read by step 10. The order of the words matters: the target's words follow
  the version option.
- **The trace span** of step 5 (the host headers) must still wrap the same work; the Ruby version must start and end the span
  at the same point, or the trace file changes.

## Shape of the port

One Ruby module, `scripts/nfcxx-setup.rb`, holds the state as a hash and runs the twelve steps in the order above, each
through the planner's existing `plan` entry point (in-process, not a new process per step). Its output is one statement list
that bash evaluates in one `eval`, plus the trace calls the bash makes. The bash keeps only the call and the eval.

## Tests

- A differential test, as for the other stages: the bash setup block copied verbatim against the Ruby output for each
  combination of backend, freestanding, cosmo, target and dialect that the suites use (default, NFCXX_BACKEND=gcc,
  pathb, freestanding, cosmo, linux_k1om, a clang dialect). The statements and the variables must be the bash's.
- The refusals (status 2 and their messages) for each planner that refuses.
- The EDG-built suites in CI: tests/nfcxx-cosmo, tests/nfcxx-k1om, tests/driver-target, tests/driver-freestanding, tests/trace.

## Open questions

1. In-process calls (`require`) or one Ruby process per step? (Recommendation: in-process; the planners are already Ruby
   code behind a `plan` CLI, so each has a function to call.)
2. Is the state hash the bash variables by name (a direct mapping, easy to check), or a struct? (Recommendation: the names,
   so the differential test compares them one for one.)

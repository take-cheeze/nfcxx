# Porting the bash drivers (nfcxx, nfcc) and their sourced helpers to Ruby

The goal is to remove the shell drivers. The bash `nfcxx` (about 1,340 lines, 22 functions) and `nfcc` (about 500
lines, 13 functions) run every path that the Ruby routes do not plan (scripts/nfcxx.rb). They source trace.sh,
bundle-wrap.sh, cuda-driver-wrap.sh, amdgpu-env.sh and host-sys.sh. Each stage below moves one group of functions to
Ruby, with a differential test against the bash driver on the same arguments (status, stdout and the produced
objects or programs). A stage is done when its bash functions have no callers left; the bash driver keeps the rest,
and the Ruby entry (scripts/nfcxx.rb) routes to it until the last stage.

## Ported already (on this branch)

- The plan printers and runner for the gcc and Path B routes, the argument loops (scripts/nfcxx-loop.rb,
  scripts/driver-loop.rb), and the live facts (scripts/nfcxx-gcc-plan.rb, scripts/nfcxx-pathb.rb).
- The helpers the driver runs as programs: gcc-cc, pathb-cc, pathb-dump, cuda-cub, sycl-integration-header,
  asan-vla, safeptr-rt, ehshim, pathb-ldrt, cil-cc, k1om-cc, the k1om assembler, cosmo-libc, host-sys (module).
- nfcc, the driver's Ruby half (stages 1 and 8 for nfcc): scripts/nfcc.rb runs the decisions of scripts/driver-loop.rb
  (its option loop, Path B, compile and link) with the real environment, host answers, temporary directory and
  commands. tests/nfcc/loop-state.sh checks the decisions against the bash (364 cases); tests/nfcc/port-driver.sh runs
  60 command lines through ./nfcc and scripts/nfcc.rb and compares status, stdout, stderr and every output file.
  ./nfcc is now a wrapper that runs scripts/nfcc.rb; the bash driver it replaced is kept as tests/nfcc/nfcc-bash, the reference
  for the differential tests (tests/nfcc/port-driver.sh, option-state.sh, the wp_option tests). The bundle wrapper (--bundle-*: the driver again, then build/nfcbundle) and the CUDA
  driver wrapper (--cuda-driver=, a libcuda on the link line: the shim) run in scripts/nfcc.rb too, checked against the bash
  by tests/nfcc/port-driver.sh (60 command lines). The shim's success path needs a real CUDA toolkit and is not tested here.

## Stages

1. nfcc option handling: `die`, `add_arg` (response files), `need`, `onoff`-style flags, `wp_option` and
   `pathb_option`. Test: tests/nfcc (loop-state, option-state, response-file, wp-option) against the bash.
2. nfcxx cache: `cache_sha`, `cache_log`, `cache_remote_get`, `cache_remote_put`, `cache_lookup` (the compile cache
   key and the GHA remote tier). Test: tests/nfcxx-cache. scripts/nfcxx-cache.rb already has the key logic; the bash
   calls to it are what remains.
   Progress: `cache_log`, `cache_remote_get` and `cache_remote_put` are calls of scripts/nfcxx-cache-io.rb (log, remote-get,
   remote-put; the GHA client is behind it). Test: tests/nfcxx-cache-io (against the frozen bash, bash-oracle.sh). Still in
   bash: `cache_sha` and the key computation in `cache_lookup`, and the gating of `cache_check` and `cache_store`.
3. Modules: `mod_is_module_src`, `mod_decl_name`, `mod_imports`, `mod_check_src`, `mod_build_program`. Test:
   tests/nfcxx-modules (its plan printer exists: scripts/nfcxx-modules.rb).
4. Eccp steps and link: `ecp_arg`, `eccp_cleanup`, `link_records_rm`, and the link dispatch. Test: the live
   differential (tests/nfcxx-live) and tests/nfcxx-gcc.
   Progress: `eccp_cleanup` and `link_records_rm` run scripts/nfcxx-link.rb. The link argument loop (-I, -l, -lcudart, -Wl and
   the objects) is scripts/nfcxx-linkargs.rb (`edg`), shared with the gcc plan; tests/nfcxx-linkargs checks it against the
   bash loop. `ecp_args` answers all of a driver call's arguments in one ruby call (`ecp-arg.rb --batch`).
   The eccp command line is planned by scripts/nfcxx-eccp-plan.rb: the argument vector in the bash's order, the variable
   a shared link exports (EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS) and the directory the call runs in (the temporary directory of
   a link, and the keep-intermediates note). It reads the call's arrays as NUL-separated records (`eccp_plan_input`).
   Still in bash: `mktemp -d` and the EXIT trap (eccp_cleanup), the `moves` decision (ecp_args needs it before the plan),
   the trace spans, the subshell that runs the command, and the second CUDA pass.
5. SYCL pre-pass: `sycl_kernel_headers` (the header script is already ported). Test: tests/nfcxx-prepass.
6. CUDA: `cu_prepare`, `cu_rewrite`, `ir_opt_device`, `cu_amd_build`, `cu_device_key`, `cu_device_build`, and the
   rewriter build (tools/cuda-rewrite). Needs a CUDA toolkit to test end to end; the stubs (tests/nfcxx-cuda-device,
   tests/nfcxx-cuda-driver) cover the planning.
   Done: none of the bash functions above is left. cu_rewrite is one call to `scripts/nfcxx-cuda-device.rb --execute`,
   which runs the plan through scripts/nfcxx-run.rb (the host copy, the device unit, the device IR, ptxas, the device image
   cache, the embedding), with the bash's messages, statuses and trace spans. cu_prepare asks `--cu-dir` for the copy's
   directory. The bash originals are kept as tests/nfcxx-cuda-device/nfcxx-bash (the oracle of run.sh and key.sh, and of
   tests/nfcxx-cuda-live with a toolkit). The rewriter's build stays in the driver's startup (ensure_tool).
7. Trace and time log: trace.sh (sourced by the driver and by every helper it runs). Port the functions to a Ruby
   module used by the Ruby helpers, and keep the driver's inline calls until stage 8.
   Done as a module: scripts/trace.rb (the same files and formats), checked against trace.sh by tests/trace/run.sh.
   trace.sh stays until stage 8, since the bash driver still calls it.
8. The remaining driver body (the dispatch in nfcxx, and nfcc's main), and bundle-wrap.sh, cuda-driver-wrap.sh,
   amdgpu-env.sh (sourced; they go when the body does). The last stage removes the bash drivers and makes
   scripts/nfcxx.rb and scripts/nfcc.rb the entries.

Stage 8 depends on stages 1 to 7. Stages 1 to 5 are testable here; stage 6 needs CUDA. For nfcc, stage 8 is done except
the bundle and CUDA wrappers (see "Ported already"); nfcxx is not started.

## Not done yet

- scripts/pathb-cc: the bash file is still in the tree with an uncommitted on-disk edit that calls the removed
  scripts/pathb-dump. The committed Ruby port (scripts/pathb-cc.rb) is the one the callers use.

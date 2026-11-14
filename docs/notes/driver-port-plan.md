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

## Stages

1. nfcc option handling: `die`, `add_arg` (response files), `need`, `onoff`-style flags, `wp_option` and
   `pathb_option`. Test: tests/nfcc (loop-state, option-state, response-file, wp-option) against the bash.
2. nfcxx cache: `cache_sha`, `cache_log`, `cache_remote_get`, `cache_remote_put`, `cache_lookup` (the compile cache
   key and the GHA remote tier). Test: tests/nfcxx-cache. scripts/nfcxx-cache.rb already has the key logic; the bash
   calls to it are what remains.
3. Modules: `mod_is_module_src`, `mod_decl_name`, `mod_imports`, `mod_check_src`, `mod_build_program`. Test:
   tests/nfcxx-modules (its plan printer exists: scripts/nfcxx-modules.rb).
4. Eccp steps and link: `ecp_arg`, `eccp_cleanup`, `link_records_rm`, and the link dispatch. Test: the live
   differential (tests/nfcxx-live) and tests/nfcxx-gcc.
5. SYCL pre-pass: `sycl_kernel_headers` (the header script is already ported). Test: tests/nfcxx-prepass.
6. CUDA: `cu_prepare`, `cu_rewrite`, `ir_opt_device`, `cu_amd_build`, `cu_device_key`, `cu_device_build`, and the
   rewriter build (tools/cuda-rewrite). Needs a CUDA toolkit to test end to end; the stubs (tests/nfcxx-cuda-device,
   tests/nfcxx-cuda-driver) cover the planning.
7. Trace and time log: trace.sh (sourced by the driver and by every helper it runs). Port the functions to a Ruby
   module used by the Ruby helpers, and keep the driver's inline calls until stage 8.
8. The remaining driver body (the dispatch in nfcxx, and nfcc's main), and bundle-wrap.sh, cuda-driver-wrap.sh,
   amdgpu-env.sh (sourced; they go when the body does). The last stage removes the bash drivers and makes
   scripts/nfcxx.rb and scripts/nfcc.rb the entries.

Stage 8 depends on stages 1 to 7. Stages 1 to 5 are testable here; stage 6 needs CUDA.

## Not done yet

- scripts/pathb-cc: the bash file is still in the tree with an uncommitted on-disk edit that calls the removed
  scripts/pathb-dump. The committed Ruby port (scripts/pathb-cc.rb) is the one the callers use.

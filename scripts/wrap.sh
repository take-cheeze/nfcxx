# Sourced by nfcxx: its --bundle-* and --cuda-driver= wrappers, which are scripts/wrap.rb's (docs/notes/bundle.md,
# docs/notes/cuda-driver.md). Needs $root and RUBY (default ruby). The bash originals are tests/wrap/bundle-wrap.sh and
# tests/wrap/cuda-driver-wrap.sh.
#   bundle_wrap DRIVER ARGS...: returns when there is nothing to do (wrap.rb exits 254); the process ends otherwise.
#   cuda_driver_wrap DRIVER ARGS...: returns with cuda_driver_args set (the arguments without --cuda-driver=), or runs the
#     driver again with the shim in place of libcuda (EXEC, the process is replaced).
bundle_wrap() {
  local rc=0
  "${RUBY:-ruby}" "$root/scripts/wrap.rb" bundle "$@" || rc=$?
  [ $rc != 254 ] || return 0
  exit $rc
}
cuda_driver_wrap() {
  local out rc=0 kind a
  out=$("${RUBY:-ruby}" "$root/scripts/wrap.rb" cuda-driver "$@") || rc=$?
  [ $rc = 0 ] || exit $rc
  { read -r kind; cuda_driver_args=(); while IFS= read -r a; do cuda_driver_args+=("$a"); done; } <<< "$out"
  if [ "$kind" = EXEC ]; then
    NFCXX_CUDA_DRIVER=libcuda exec "$1" ${cuda_driver_args[@]+"${cuda_driver_args[@]}"}
  fi
  return 0
}

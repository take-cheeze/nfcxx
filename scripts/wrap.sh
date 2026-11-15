# Sourced by nfcxx: its --bundle-* and --cuda-driver= wrappers, which are scripts/wrap.rb's (docs/notes/bundle.md,
# docs/notes/cuda-driver.md). wrap.rb exits 254 when there is nothing to do: the bundle wrapper then returns, and the CUDA one
# returns with cuda_driver_args (the arguments without --cuda-driver=), read from the NUL-terminated file it writes. Needs
# $root and RUBY (default ruby). The bash originals are tests/wrap/bundle-wrap.sh and tests/wrap/cuda-driver-wrap.sh.
bundle_wrap() {
  local rc=0
  "${RUBY:-ruby}" "$root/scripts/wrap.rb" bundle "$@" || rc=$?
  [ $rc != 254 ] || return 0
  exit $rc
}
cuda_driver_wrap() {
  local list="${TMPDIR:-/tmp}/nfcxx-cuda-args.$$" rc=0 a
  "${RUBY:-ruby}" "$root/scripts/wrap.rb" cuda-driver "$list" "$@" || rc=$?
  if [ $rc = 254 ]; then
    cuda_driver_args=()
    while IFS= read -r -d '' a; do cuda_driver_args+=("$a"); done < "$list"
    rm -f "$list"
    return 0
  fi
  rm -f "$list"
  exit $rc
}

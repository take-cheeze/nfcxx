# The bash originals of nfcxx's link_records_rm and eccp_cleanup, verbatim (scripts/nfcxx-link.rb is the port). Sourced by
# tests/nfcxx-link/run.sh; trace_finish is a stub there (trace.sh is not under test).
trace_finish() { :; }
eccp_cleanup() {  # the EXIT trap of a build that runs eccp in a temporary directory (and of the C-input and .cu steps)
  local rc=$?
  if [ -n "$eccp_dir" ] && [ $keep_intermediates = 0 ]; then rm -rf "$eccp_dir"; fi
  if [ -n "${cudatmp:-}" ]; then rm -rf "$cudatmp"; fi
  if [ -n "${ctmp:-}" ]; then rm -rf "$ctmp"; fi
  trace_finish
  return $rc
}
link_records_rm() {  # link_records_rm: removes <stem>.ii beside each object of this link (see "A link writes" below)
  local f
  for f in ${files[@]+"${files[@]}"}; do
    case $f in *.o) rm -f "${f%.o}.ii" ;; esac
  done
}

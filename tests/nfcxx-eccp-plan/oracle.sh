# The bash original of nfcxx's eccp call, verbatim: the lines of the pre-port nfcxx (commit 26dc75bb^, lines 1039-1062), from
# the "if [ $moves = 1 ]" that makes the temporary directory through the eccp command, the subshell that runs it and its
# trace span. scripts/nfcxx-eccp-plan.rb replaced the command construction (the argument vector, the shared link's export and
# the directory); the mktemp, the trap and the trace stay in nfcxx. tests/nfcxx-eccp-plan/run.sh sources this file and calls
# oracle_eccp after it sets the inputs the block reads (eccp_bin, eccp_out, std, dialect, the arrays, moves, keep_intermediates,
# shared). The eccp_bin and eccp_out words are set by the test, in place of ecp_args (tests/nfcxx-ecp-arg checks that).
# eccp_cleanup is the bash original of the EXIT trap (tests/nfcxx-link/oracle.sh); trace_start and trace_end are stubs.
trace_start() { :; }
trace_end() { :; }
trace_finish() { :; }
eccp_cleanup() {  # the EXIT trap of a build that runs eccp in a temporary directory (and of the C-input and .cu steps)
  local rc=$?
  if [ -n "$eccp_dir" ] && [ $keep_intermediates = 0 ]; then rm -rf "$eccp_dir"; fi
  if [ -n "${cudatmp:-}" ]; then rm -rf "$cudatmp"; fi
  if [ -n "${ctmp:-}" ]; then rm -rf "$ctmp"; fi
  trace_finish
  return $rc
}
oracle_eccp() {  # the eccp call of nfcxx (the lines below, verbatim)
if [ $moves = 1 ]; then
  eccp_dir=$(mktemp -d); trap eccp_cleanup EXIT
  [ $keep_intermediates = 0 ] || echo "nfcxx: intermediates kept in $eccp_dir (--keep-intermediates)" >&2
fi
t=$(trace_start)
(
  [ -z "$eccp_dir" ] || cd "$eccp_dir"
  # A shared link: EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS replaces eccp's link options (the C compile options), so the link
  # options among them go there with -shared: -Wl,... (-soname, -rpath, --gc-sections), -fuse-ld=, -pthread, -rdynamic.
  # Without them a library lost its SONAME and RUNPATH. (eccp splits the variable at spaces.)
  if [ $shared = 1 ]; then
    lk=(-shared) prev=
    for a in ${picopts[@]+"${picopts[@]}"} ${eflist[@]+"${eflist[@]}"} ${inst_opts[@]+"${inst_opts[@]}"}; do
      if [ "$prev" = --c_to_obj_option ]; then
        case $a in -Wl,*|-fuse-ld=*|-pthread|-rdynamic) lk+=("$a") ;; esac
      fi
      prev=$a
    done
    export EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS="${lk[*]}"
  fi
  "$eccp_bin" "$std" --"$dialect" --wdir / ${extra[@]+"${extra[@]}"} ${inst_opts[@]+"${inst_opts[@]}"} ${modopts[@]+"${modopts[@]}"} ${diag_opts[@]+"${diag_opts[@]}"} ${userinc[@]+${userinc[@]+"${userinc[@]}"}} ${sys_inc[@]+"${sys_inc[@]}"} ${hosted_libs[@]+"${hosted_libs[@]}"} --c_to_obj_option -O2 --c_to_obj_option -fwrapv --c_to_obj_option -fno-strict-aliasing ${keep_static[@]+${keep_static[@]+"${keep_static[@]}"}} ${eh_unwind[@]+${eh_unwind[@]+"${eh_unwind[@]}"}} --c_to_obj_option -fgnu89-inline ${picopts[@]+${picopts[@]+"${picopts[@]}"}} \
    ${cobjs[@]+${cobjs[@]+"${cobjs[@]}"}} ${pre_opts[@]+${pre_opts[@]+"${pre_opts[@]}"}} ${cuda_opts[@]+${cuda_opts[@]+"${cuda_opts[@]}"}} ${eflist[@]+${eflist[@]+"${eflist[@]}"}} ${shim[@]+${shim[@]+"${shim[@]}"}} ${vlart[@]+${vlart[@]+"${vlart[@]}"}} ${rtlib[@]+${rtlib[@]+"${rtlib[@]}"}} -o "$eccp_out"
)
trace_end "$t" "eccp (front end, C compile, link)" eccp
}

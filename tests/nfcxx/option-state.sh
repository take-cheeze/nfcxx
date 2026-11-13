#!/usr/bin/env bash
# The state nfcxx's argument loop leaves behind, for one argument list: the oracle for the Ruby port (scripts/nfcxx-loop.rb).
# The harness is nfcxx's own code: its setup and its loop (up to the loop's "done"), with nfcxx's root, and with the one step
# that builds a tool (ensure_tool, which runs ninja) stubbed out. The variables the loop sets are dumped in the port's order.
# The default environment: NFCXX_* variables are not read by this slice (the port refuses them by default).
#   tests/nfcxx/option-state.sh ARG...    prints the state, one variable per line; an error as nfcxx prints it
#   tests/nfcxx/option-state.sh --self    checks the harness on a few argument lists
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

scalars="std out outset emit_c emit_hip backend backend_explicit path_b ir_opt ir_opt_set eh_unwind_on eh_shim_on
cache_dir cache_log_file keep_intermediates time_log instantiate promote_slots unroll struct_slots pathb_c
ld_name obfuscate dialect dialect_asked gnu gnu_user freestanding cosmo target trace moddir asan safeptr
sanitize shared pic rdynamic compile_only pthread preprocess xlang stdin_src depmode dfile dtarget depphony
ncpp nobj"
arrays="files cflags cfiles cu_inputs cpp2_inputs srcs ppflags pie_opts preinc sysdirs isa diag_opts asanopts"

harness() {
  # the stub of the tool build (the body of ensure_tool is kept, under another name, for nothing else to call)
  echo 'ensure_tool() { return 0; }'
  # nfcxx's setup and loop: up to the loop's closing "done"
  awk 'seen && /^done$/ { print; exit } /^while \[ \$# -gt 0 \]; do$/ { seen = 1 } { print }' "$root/nfcxx" |
    sed -e "s|^root=\$(cd \"\$(dirname \"\$0\")\" && pwd)|root=$root|" -e 's/^ensure_tool() {/ensure_tool_real() {/'
  echo 'dump_arr() { declare -p "$1" >/dev/null 2>&1 || return 0; local -n r=$1; [ ${#r[@]} -eq 0 ] && return 0; local x; for x in "${r[@]}"; do printf "%s+=%s\n" "$1" "$x"; done; }'
  for v in $scalars; do echo "printf '%s=%s\\n' $v \"\${$v-}\""; done
  for v in $arrays; do echo "dump_arr $v"; done
}
harness > "$tmp/harness.sh"

state() { bash "$tmp/harness.sh" "$@" 2>&1; }

if [ "${1:-}" = --self ]; then
  pass=0; fail=0
  check() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: want [$2] got [$1]"; fi; }
  check "$(state -c a.cpp -o a.o | grep '^compile_only=')" "compile_only=1"
  check "$(state -c a.cpp -o a.o | grep '^out=')" "out=a.o"
  check "$(state -c a.cpp -DX=1 | grep '^cflags+=')" "cflags+=-DX=1"
  check "$(state -c a.cpp -O2 | grep '^files+=-O2')" "files+=-O2"
  check "$(state -c a.cpp --backend=qbe | grep '^backend=')" "backend=qbe"
  echo "$pass passed, $fail failed"
  [ "$fail" = 0 ]
  exit $?
fi
state "$@"

#!/bin/bash
# Differential test of nfcxx's eccp command line. The port is nfcxx's eccp call: state_put, eccp_plan_input, eccp_plan and
# the lines of the call that stay in bash (the temporary directory, the trap, the trace span), taken from ./nfcxx as they are.
# It runs scripts/nfcxx-eccp-plan.rb. The oracle is tests/nfcxx-eccp-plan/oracle.sh: the bash the port replaced, verbatim.
# Each case runs both sides with a stub eccp that records its working directory, EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS (set or
# unset) and its argv. The argv, the working directory, the standard error (the keep note), the status and the temporary
# directories left must be the same. The refused case has no oracle (the bash cannot build a bad record stream); it checks the
# planner's refusal and that eccp does not run.
#
#   bash tests/nfcxx-eccp-plan/run.sh          (ECCP_SHOW=1 prints each case's outcome)
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ruby_bin=$(command -v ruby) || { echo "nfcxx-eccp-plan: ruby is not on PATH" >&2; exit 2; }

# the port, as nfcxx has it: the functions, and the call (the lines from the moves test to the trace span of eccp)
sed -n '/^state_put() {/,/^}/p;/^eccp_plan_input() {/,/^}/p;/^eccp_plan() {/,/^}/p;/^eccp_cleanup() {/,/^}/p' "$repo/nfcxx" > "$work/thin_defs.sh"
sed -n '/^if \[ \$moves = 1 \]; then$/,/^eccp_plan$/p' "$repo/nfcxx" > "$work/thin_call.sh"; sed -n '/^t=\$(trace_start)$/,/^trace_end "\$t" "eccp (front end/p' "$repo/nfcxx" >> "$work/thin_call.sh"
for f in "$work/thin_defs.sh" "$work/thin_call.sh"; do
  [ -s "$f" ] || { echo "nfcxx-eccp-plan: nothing to test in nfcxx ($f is empty)" >&2; exit 2; }
done
grep -q '^eccp_plan() {' "$work/thin_defs.sh" && grep -q 'eccp_plan$' "$work/thin_call.sh" \
  || { echo "nfcxx-eccp-plan: nfcxx's eccp call has moved (update the extraction)" >&2; exit 2; }

# the stub eccp: records the working directory, the exported variable and the argv of each call, then exits with ECCP_RC
stub=$work/bin/eccp; mkdir -p "$work/bin" "$work/usercwd"
cat > "$stub" <<'STUB'
#!/bin/bash
{
  printf 'cwd %s\n' "$(pwd -P)"
  if [ -n "${EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS+x}" ]; then printf 'env %s\n' "$EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS"; else printf 'env (unset)\n'; fi
  for a in "$@"; do printf 'arg %s\n' "$a"; done
} >> "$ECCP_LOG"
exit "${ECCP_RC:-0}"
STUB
chmod +x "$stub"

# the inputs both sides read (the arrays nfcxx sets, and the scalars): defaults, a case's setup overrides them
prelude="set -euo pipefail; root=$repo; RUBY=$ruby_bin; trace_start() { :; }; trace_end() { :; }; trace_finish() { :; }
eccp_bin=$stub; std=--c++23; dialect=gnu; eccp_out=/nfcxx-test/a.out; moves=0; keep_intermediates=0; shared=0; eccp_dir=
extra=(); inst_opts=(); modopts=(); diag_opts=(); userinc=(); sys_inc=(); hosted_libs=(); keep_static=(); eh_unwind=()
picopts=(); cobjs=(); pre_opts=(); cuda_opts=(); eflist=(); shim=(); vlart=(); rtlib=(); files=(); compile_only=0"

# normalize TMPD TEXT: the side's temporary directory (and the directories mktemp made in it) as <tmp>
normalize() {
  printf '%s\n' "$2" | sed -e "s#$1/tmp[.][A-Za-z0-9_]*#<tmp>#g" -e "s#$1#<tmp-base>#g"
}

# run_side SIDE SETUP [THIN_PLAN]: one side of a case, in its own bash, with its own temporary directory; prints the outcome
run_side() {
  local side=$1 setup=$2 plan=${3:-} tmpd=$work/tmp-$1 log=$work/log-$1 loader rc err
  rm -rf "$tmpd" "$log"; mkdir -p "$tmpd"; tmpd=$(cd "$tmpd" && pwd -P)
  if [ "$side" = thin ]; then
    loader="source '$work/thin_defs.sh'; ${plan:+$plan; }source '$work/thin_call.sh'"
  else
    loader="source '$here/oracle.sh'; oracle_eccp"
  fi
  err=$(cd "$work/usercwd" && env -u EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS ECCP_LOG="$log" TMPDIR="$tmpd" \
    bash -c "$prelude; $setup; $loader" 2>&1 >/dev/null); rc=$?
  printf 'status %s\n' "$rc"
  printf '== stderr\n%s\n' "$(normalize "$tmpd" "$err")"
  local calls=0 text=""
  [ -e "$log" ] && { calls=$(grep -c '^cwd ' "$log"); text=$(normalize "$tmpd" "$(cat "$log")"); }
  printf 'calls %s\n== log\n%s\n' "$calls" "$text"
  printf 'left %s\n' "$(find "$tmpd" -mindepth 1 -maxdepth 1 | wc -l)"
}

pass=0; fail=0
report() {  # report NAME OK DETAIL
  if [ "$2" = 1 ]; then
    pass=$((pass + 1)); echo "ok   $1"
  else
    fail=$((fail + 1)); echo "FAIL $1"; [ -z "$3" ] || printf '%s\n' "$3" | sed 's/^/     /'
  fi
}
case_() {  # case_ NAME SETUP: the port and the oracle give the same outcome, and eccp runs once
  local name=$1 setup=$2 t o
  t=$(run_side thin "$setup"); o=$(run_side oracle "$setup")
  if [ "$t" != "$o" ]; then
    report "$name" 0 "oracle:
$o
port:
$t"
  elif ! printf '%s\n' "$t" | grep -qx 'calls 1'; then
    report "$name" 0 "eccp did not run once:
$t"
  else
    report "$name" 1 ""
  fi
  [ -z "${ECCP_SHOW:-}" ] || printf '%s\n' "$t"
}

case_ "plain compile: one source, a temporary directory" 'moves=1; pre_opts=(a.cc)'
case_ "link with objects" 'moves=1; cobjs=(a.o b.o); hosted_libs=(-lm); rtlib=(-lrt)'
case_ "-shared: the variable and -fPIC" 'moves=1; shared=1; picopts=(--c_to_obj_option -fPIC --c_to_obj_option -Wl,-soname,libx.so.1); cobjs=(a.o)'
case_ "-pthread: the C compile option" 'moves=1; picopts=(--c_to_obj_option -pthread); cobjs=(a.o)'
case_ "-rdynamic: the C compile option" 'moves=1; picopts=(--c_to_obj_option -rdynamic); cobjs=(a.o)'
case_ "-c with -o: the user's directory, no note" 'moves=0; pre_opts=(a.cc); eccp_out=/nfcxx-test/a.o'
case_ "keep-intermediates: the note and the directory kept" 'moves=1; keep_intermediates=1; cobjs=(a.o)'
case_ "temporary directory in use: removed, no note" 'moves=1; cobjs=(a.o)'
case_ "-c with keep-intermediates: no directory, no note" 'moves=0; keep_intermediates=1; pre_opts=(a.cc); eccp_out=/nfcxx-test/a.o'
case_ "extra options: a word with a space and an empty word" 'moves=1; extra=(-DNAME=a\ b "" -O0 -I/x)'
case_ "modopts and diag_opts" 'moves=1; modopts=(-fmodules-ts); diag_opts=(--diag_suppress 1234); cobjs=(a.o)'
case_ "cuda_opts and rtlib" 'moves=1; cuda_opts=(--cuda_arch sm_80); rtlib=(-lcudart); cobjs=(a.o)'
case_ "shared link: link options across picopts, eflist and inst_opts" 'moves=1; shared=1; picopts=(--c_to_obj_option); files=(-Wl,--gc-sections -O2 -fuse-ld=mold); eflist=(--c_to_obj_option -Wl,--gc-sections -O2 -fuse-ld=mold); inst_opts=(--c_to_obj_option -pthread -rdynamic --c_to_obj_option -Wl,-rpath,/x -O3 -Wl,-z,now); cobjs=(a.o)'
case_ "shared link with no link options: -shared alone" 'moves=1; shared=1; cobjs=(a.o)'
case_ "a link that is not shared: no variable, -Wl kept as an option" 'moves=1; shared=0; picopts=(--c_to_obj_option -Wl,-rpath,/x); cobjs=(a.o)'
case_ "eccp's status is the call's status" 'moves=1; export ECCP_RC=3; cobjs=(a.o)'

# refused plan: the planner refuses a record stream whose scalar group (out) has two values; the bash cannot make one
refused() {
  local name="refused plan: a scalar group with two values is refused, eccp does not run"
  local tmpd=$work/tmp-refused log=$work/log-refused out rc want
  rm -rf "$tmpd" "$log"; mkdir -p "$tmpd"; tmpd=$(cd "$tmpd" && pwd -P)
  out=$(cd "$work/usercwd" && env -u EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS ECCP_LOG="$log" TMPDIR="$tmpd" bash -c \
    "$prelude; moves=1; cobjs=(a.o); source '$work/thin_defs.sh'
     eccp_plan_input() { state_put eccp \"\$eccp_bin\"; state_put std \"\$std\"; state_put dialect \"\$dialect\"; state_put out \"\$eccp_out\" extra; }
     source '$work/thin_call.sh'" 2>&1 >/dev/null); rc=$?
  want="nfcxx-eccp-plan: group out needs one value"
  if [ "$rc" = 1 ] && [ "$out" = "$want" ] && [ ! -e "$log" ] && [ -z "$(ls -A "$tmpd")" ]; then
    report "$name" 1 ""
  else
    report "$name" 0 "status $rc
$out"
  fi
}
refused

echo "eccp-plan: $pass passed, $fail failed"
[ "$fail" = 0 ]

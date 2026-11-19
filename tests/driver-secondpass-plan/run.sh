#!/bin/bash
# The second pass's gate, host symbols, found check and re-run arguments: the bash of nfcxx before scripts/nfcxx-second-pass.rb
# plan (OLD, verbatim from origin/main) against the driver now (NEW: the eval of plan, then the re-run). Each case runs both in
# a copy of its directory, with a stub ./root/nfcxx that logs its arguments and NFCXX_ environment and returns a status.
# Compared: stdout, stderr, status, the stub's log and the host symbols file.   bash tests/driver-secondpass-plan/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pass=0; fail=0

cat > "$t/old.sh" <<'BLOCK'
if [ ${#cu_inputs[@]} = 1 ] && [ -z "${NFCXX_CUDA_HOST_SYMBOLS:-}" ] && [ $preprocess = 0 ] && [ -f "$out" ] \
   && [ -s "$cudatmp/$(basename "${cu_inputs[0]}" .cu).dev.kernels.unresolved" ]; then
  hsyms=$cudatmp/host.syms
  "${RUBY:-ruby}" "$root/scripts/nfcxx-second-pass.rb" host-symbols "$out" "$hsyms" || true   # nm -C, the _INTERNAL_ scopes removed
  # the unresolved kernels that the host symbols define: scripts/nfcxx-second-pass.rb found (B7)
  found=$("${RUBY:-ruby}" "$root/scripts/nfcxx-second-pass.rb" found "$hsyms" "$cudatmp/$(basename "${cu_inputs[0]}" .cu).dev.kernels.unresolved")
  if [ $found = 1 ]; then
    t=$(trace_start)
    # (the second pass is not cached: the --cache option is left out, and NFCXX_CACHE emptied)
    args2=(); for a in "${args0[@]}"; do case $a in --cache=*) ;; *) args2+=("$a") ;; esac; done
    "${RUBY:-ruby}" "$root/scripts/nfcxx-second-pass.rb" rerun "$root" "$hsyms" "$$" ${args2[@]+"${args2[@]}"} || exit $?   # the re-run (scripts/nfcxx-second-pass.rb)
    trace_end "$t" "second pass (kernel instances from the host compile)" eccp
  fi
fi
BLOCK

# The span moved into the re-run (scripts/nfcxx-second-pass.rb rerun), so the new side has none of the bash trace lines; the
# bash side's are dropped here, and the span is checked by the last cases.
sed -i '/^ *t=\$(trace_start)$/d; /^ *trace_end "\$t" "second pass/d' "$t/old.sh"

cat > "$t/new.sh" <<'BLOCK'
eval "$("${RUBY:-ruby}" "$root/scripts/nfcxx-second-pass.rb" plan "$out" "$cudatmp" "${#cu_inputs[@]}" "${cu_inputs[0]-}" "$preprocess" "${NFCXX_CUDA_HOST_SYMBOLS-}" ${args0[@]+"${args0[@]}"})"   # the gate, host symbols, found and args2 (plan); not cached
if [ $sp_run = 1 ]; then
  "${RUBY:-ruby}" "$root/scripts/nfcxx-second-pass.rb" rerun "$root" "$hsyms" "${BASHPID:-$$}" ${args2[@]+"${args2[@]}"} || exit $?   # the re-run and its trace span (scripts/nfcxx-second-pass.rb)
fi
BLOCK

# the stub driver: logs its arguments and the NFCXX_ environment, returns STUB_RC
mkdir -p "$t/stub"
cat > "$t/stub/nfcxx" <<'STUB'
#!/bin/bash
{ printf 'argv:'; printf ' [%s]' "$@"; echo; env | grep '^NFCXX_' | sort | sed 's/^/env: /'; } >> "$LOGFILE"
exit "${STUB_RC:-0}"
STUB
chmod +x "$t/stub/nfcxx"

# the object with a template instance and an internal-namespace kernel (its host symbols are the bash's nm -C | sed)
printf 'namespace _INTERNAL_1234 { int kern(int x) { return x; } }\nint plain(int y) { return y; }\ntemplate<class T> T tmpl(T v) { return v; }\nint use() { return plain(1) + tmpl<int>(2) + _INTERNAL_1234::kern(3); }\n' > "$t/h.cpp"
if ! (cd "$t" && g++ -c h.cpp -o h.o 2>/dev/null); then echo "driver-secondpass-plan: the test object did not build"; exit 1; fi

# mk LABEL CU_LIST PREPROCESS HAVE_OBJ UNRESOLVED(printf %b, or absent) STUB_RC EXTRA ARGS(bash words): one case directory
mk() {
  local d="$t/case-$1"; mkdir -p "$d/tmp" "$d/root"
  ln -s "$repo/scripts" "$d/root/scripts"; cp "$t/stub/nfcxx" "$d/root/nfcxx"
  [ "$4" = 1 ] && cp "$t/h.o" "$d/m.o"
  [ "$5" = absent ] || printf '%b' "$5" > "$d/tmp/m.dev.kernels.unresolved"
  cat > "$d/vars.sh" <<VARS
root="\$PWD/root"; out="\$PWD/m.o"; cudatmp="\$PWD/tmp"
cu_inputs=($2); preprocess=$3; args0=($8)
export STUB_RC=$6 NFCXX_CACHE=/outer-cache NFCXX_CACHE_REMOTE=/outer-remote
$7
VARS
}

# run_side DIR BLOCK: the block in a driver-like shell (set -euo pipefail); stdout, stderr, status, log and host symbols kept
run_side() {
  local d=$1 block=$2
  (
    cd "$d" || exit 99
    export LOGFILE="$d/log"; : > "$LOGFILE"
    unset NFCXX_CUDA_HOST_SYMBOLS RUBY
    . ./vars.sh
    trace_start() { echo T; }
    trace_end() { echo "trace_end: $*"; }
    set -euo pipefail
    . "$block"
  ) > "$d/out" 2> "$d/err"; echo $? > "$d/rc"
  sed -i "s|$d|@DIR@|g" "$d/log" "$d/out" "$d/err"   # the copies' own paths, the same on both sides
  cat "$d/tmp/host.syms" > "$d/hs" 2>/dev/null || : > "$d/hs"
}

# case LABEL WANT_RUN ...mk args: builds the case, runs OLD and NEW in copies, compares
case_run() {
  local label=$1 want=$2; shift 2
  mk "$label" "$@"
  rm -rf "$t/old-$label" "$t/new-$label"
  cp -a "$t/case-$label" "$t/old-$label"; cp -a "$t/case-$label" "$t/new-$label"
  run_side "$t/old-$label" "$t/old.sh"; run_side "$t/new-$label" "$t/new.sh"
  local ran=0; [ -s "$t/old-$label/log" ] && ran=1
  if [ "$ran" != "$want" ]; then fail=$((fail + 1)); echo "FAIL $label: the bash ran the re-run $ran times, want $want"; return; fi
  local bad=""
  for f in out err rc log hs; do cmp -s "$t/old-$label/$f" "$t/new-$label/$f" || bad="$bad $f"; done
  if [ -z "$bad" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $label: differs in:$bad"
    for f in out err rc log hs; do diff "$t/old-$label/$f" "$t/new-$label/$f" | sed "s/^/  $f: /" | head -8; done; fi
}

ARGS='-c m.cpp --cache=/x -o m.o'
case_run no-unresolved       0 'm.cu' 0 1 absent 0 '' "$ARGS"
case_run empty-unresolved    0 'm.cu' 0 1 '' 0 '' "$ARGS"
case_run no-match            0 'm.cu' 0 1 'nosuch\n' 0 '' "$ARGS"
case_run found               1 'm.cu' 0 1 'tmpl\n' 0 '' "$ARGS"
case_run found-status-7      1 'm.cu' 0 1 'tmpl\n' 7 '' "$ARGS"
case_run found-second-name   1 'm.cu' 0 1 'plain\nnosuch\ntmpl\n' 0 '' "$ARGS"
case_run blank-name-line     1 'm.cu' 0 1 '\ntmpl\n' 0 '' "$ARGS"
case_run no-final-newline    0 'm.cu' 0 1 'tmpl' 0 '' "$ARGS"
case_run two-inputs          0 'm.cu n.cu' 0 1 'tmpl\n' 0 '' "$ARGS"
case_run host-symbols-set    0 'm.cu' 0 1 'tmpl\n' 0 'export NFCXX_CUDA_HOST_SYMBOLS=/given/syms' "$ARGS"
case_run preprocess-1        0 'm.cu' 1 1 'tmpl\n' 0 '' "$ARGS"
case_run no-object           0 'm.cu' 0 0 'tmpl\n' 0 '' "$ARGS"
case_run quoted-args         1 'm.cu' 0 1 'tmpl\n' 0 '' "-c 'my file.cpp' --cache=/x --cache=y -o 'a'\\''b.o' -DX='a b'"
case_run no-args-cache       1 'm.cu' 0 1 'tmpl\n' 0 '' "-c m.cpp -o m.o"

# the span of the re-run (the bash's trace_end, now in the re-run): a time log line when it succeeds and none when it fails,
# written directly, and a pending record (NUL-separated, six fields) when the driver batches its spans
for rc in 0 7; do
  mk "span-$rc" 'm.cu' 0 1 'tmpl\n' "$rc" '' "$ARGS"
  ( export NFCXX_TIME_LOG="$t/tl-$rc" NFCXX_TRACE_UNIT=m.o; unset NFCXX_TRACE_PENDING; run_side "$t/case-span-$rc" "$t/new.sh" )
  n=$(awk -F'\t' '$2 == "eccp" && $3 == "second pass (kernel instances from the host compile)" && $4 == "m.o"' "$t/tl-$rc" 2>/dev/null | wc -l | tr -d ' ')
  want=$([ "$rc" = 0 ] && echo 1 || echo 0)
  if [ "$n" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL span status $rc: $n time log lines, want $want"; fi
  rm -f "$t/pend-$rc"; : > "$t/pend-$rc"
  ( export NFCXX_TRACE=/dev/null NFCXX_TRACE_PENDING="$t/pend-$rc" NFCXX_TRACE_UNIT=m.o; run_side "$t/case-span-$rc" "$t/new.sh" )
  n=$(tr '\0' '\n' < "$t/pend-$rc" | grep -c '^eccp$' || true)
  if [ "$n" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL pending span status $rc: $n records, want $want"; fi
done

echo "driver-secondpass-plan: $pass passed, $fail failed"
[ $fail = 0 ]

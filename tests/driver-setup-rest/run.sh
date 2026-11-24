#!/bin/bash
# The setup's rest (docs/notes/driver-body-port.md, item 3): the golden check of the driver's behavior on a table of argument
# lists (cases.txt) for the setup pieces the Ruby driver plans now: instantiation, --cosmo, the freestanding and host header
# probes (with their trace span), the host cflags, the GNU options, --target and --target=linux_k1om. Each case runs ./nfcxx in
# its own directory, with an EDG build whose bin/eccp logs its arguments and exits 1, a stub cosmocc, an EDG base with target
# tables and a k1om root; it records the stdout, the driver's stderr lines, the status, the eccp calls, the files left behind,
# the trace's event names and the time log's categories and names, with the paths normalized.
#   bash tests/driver-setup-rest/run.sh            compares every case with its golden, then checks the body's protocol
#   bash tests/driver-setup-rest/run.sh --record   writes the goldens (only on a tree whose behavior is the reference)
set -u
here=$(cd "$(dirname "$0")" && pwd -P); src=$(cd "$here/../.." && pwd -P)
mode=${1:-check}
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
# the environment is pinned, as in tests/driver-setup-stage/run.sh: the cases run a copy of the repository without build/ (the
# driver reads ROOT/build for QBE, the EH shim, EDG's libC.a and cosmocc's tree), so the result does not depend on the checkout's build
repo=$work/root
mkdir -p "$repo" && (cd "$src" && tar --exclude=./build --exclude=./.git -cf - .) | (cd "$repo" && tar -xf -) || exit 1
ruby "$repo/scripts/nfcxx-ensure-tool.rb" "$repo/tools/cuda-rewrite" "$repo/build/cuda-rewrite" >/dev/null 2>&1 || true
mkdir -p "$work/src" "$work/tmp" "$work/stub/bin" "$work/edgbase/lib_linux_aarch64" "$work/edgbase/lib_linux_armv7" \
  "$work/k1om/bin"
printf 'int main() { return 0; }\n' > "$work/src/a.cpp"
printf 'int b() { return 1; }\n' > "$work/src/b.cpp"
printf 'int main(void) { return 0; }\n' > "$work/src/a.c"
# the EDG build: bin/eccp logs its arguments (one per line) to NFCXX_STUB_LOG and fails
cat > "$work/stub/bin/eccp" <<'STUB'
#!/bin/sh
{ echo "eccp:"; for a in "$@"; do echo "  $a"; done; } >> "$NFCXX_STUB_LOG"
exit 1
STUB
chmod +x "$work/stub/bin/eccp"
# the cosmocc stub: its -dumpfullversion is the version the driver reads (no x86_64-linux-cosmo-g++ beside it)
cat > "$work/stub/bin/cosmocc" <<'STUB'
#!/bin/sh
[ "$1" = -dumpfullversion ] && { echo 12.3.0; exit 0; }
exit 1
STUB
chmod +x "$work/stub/bin/cosmocc"
printf '#!/bin/sh\nexit 0\n' > "$work/k1om/bin/k1om-mpss-linux-gcc"; chmod +x "$work/k1om/bin/k1om-mpss-linux-gcc"

# normalize: the repository, the work directory and the temporary directories (their names are random) become fixed words
normalize() {
  sed -e "s#$repo#<REPO>#g" -e "s#$work#<WORK>#g" \
      -e 's#nfcxx-[a-z]*\.[A-Za-z0-9_]*#nfcxx-<T>#g' -e 's#\.build\.[A-Za-z0-9]*/#.build.<T>/#g' \
      -e 's#<WORK>/tmp/[^ :/]*#<TMPDIR>#g' -e 's#line [0-9][0-9]*: #line N: #g'
}

# run_case N LINE: writes the recording of case N to $work/out/case-NN.txt
run_case() {
  local n=$1 line=$2 envs args d
  envs=${line%%|*}; args=${line#*|}
  envs=${envs//@WORK@/$work}
  d=$work/run/$n; mkdir -p "$d"; cp "$work"/src/* "$d/"
  # the environment is fixed: the variables the driver reads are the ones named on the case's line
  # shellcheck disable=SC2086
  (cd "$d" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$work/tmp" EDG_BUILD="$work/stub" NFCXX_STUB_LOG="$d/eccp.log" NFCXX_OWNED_MODPLAN="$work/modplan" \
      $envs "$repo/nfcxx" $args > "$d/.out" 2> "$d/.err"; echo $? > "$d/.rc")
  {
    echo "== case $n:${envs:+ $envs}${args:+ $args}" | normalize
    echo "-- status: $(cat "$d/.rc")"
    echo "-- stdout"; normalize < "$d/.out"
    echo "-- stderr"; grep -e '^nfcxx:' -e '^eccp:' "$d/.err" | normalize
    echo "-- eccp"; if [ -f "$d/eccp.log" ]; then normalize < "$d/eccp.log"; else echo "(none)"; fi
    echo "-- files"
    (cd "$d" && ls -A | grep -v -e '^\.' -e '^eccp.log$' -e '^a\.cpp$' -e '^b\.cpp$' -e '^a\.c$' | sort) | normalize
    if [ -f "$d/trace.json" ]; then
      echo "-- trace names"
      cat "$d"/trace*.json 2>/dev/null | grep -o '"name": *"[^"]*"' | sort | uniq -c | normalize
    fi
    if [ -f "$d/time.log" ]; then
      echo "-- time log (category, name, unit)"
      cut -f2- "$d/time.log" | normalize
    fi
  } > "$work/out/case-$(printf %02d "$n").txt"
}

mkdir -p "$work/out"
n=0
while IFS= read -r line; do
  case $line in ''|\#*) continue ;; esac
  n=$((n + 1))
  run_case "$n" "$line"
done < "$here/cases.txt"

if [ "$mode" = --record ]; then
  mkdir -p "$here/golden"
  rm -f "$here"/golden/case-*.txt
  cp "$work"/out/case-*.txt "$here/golden/"
  echo "driver-setup-rest: recorded $n goldens in $here/golden"
  exit 0
fi

pass=0; fail=0
for f in "$work"/out/case-*.txt; do
  g=$here/golden/$(basename "$f")
  if [ -f "$g" ] && cmp -s "$f" "$g"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $(basename "$f"): $(head -1 "$f")"; [ -f "$g" ] && diff "$g" "$f" | head -20; fi
done
# The body's protocol checks (the statements it evals from the driver's environment) were retired with the
# bash body (driver-setup-rest, -rest2 and -stage: the Ruby driver reads its own planner's values).
echo "driver-setup-rest: $pass passed, $fail failed"
[ "$fail" = 0 ]

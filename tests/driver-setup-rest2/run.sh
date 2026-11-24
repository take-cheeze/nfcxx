#!/bin/bash
# The setup's rest of the body (docs/notes/driver-body-port.md, item 3): the golden check of the driver's behavior on a table of
# argument lists (cases.txt) for the setup pieces the body still ran in bash on main: the -fsanitize=address check and asan_c, the
# Path B pb_flags tail, the backend environment (NFCXX_CC), and the trace unit. Each case runs ./nfcxx in its own directory, with an
# EDG build whose bin/eccp logs its arguments and the NFCXX_ variables it sees, then exits 1. It records the stdout, the driver's
# stderr lines (^nfcxx: and ^eccp:), the status, the eccp calls, the files left behind, and the trace's event names, with the paths
# normalized.
#   bash tests/driver-setup-rest2/run.sh            compares every case with its golden
#   bash tests/driver-setup-rest2/run.sh --record   writes the goldens (only on a tree whose behavior is the reference)
set -u
here=$(cd "$(dirname "$0")" && pwd -P); src=$(cd "$here/../.." && pwd -P)
mode=${1:-check}
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
# the cases run a copy of the repository without build/ (the driver reads ROOT/build for QBE, the EH shim and EDG's libC.a), so the
# result does not depend on the checkout's build (the QBE stub is the only build product the copy has)
repo=$work/root
mkdir -p "$repo" && (cd "$src" && tar --exclude=./build --exclude=./.git -cf - .) | (cd "$repo" && tar -xf -) || exit 1
# a QBE stub in the copy only: the Path B checks see QBE built, so the cases reach the Path B flags and the backend environment
mkdir -p "$repo/build/qbe" && printf '#!/bin/sh\nexit 0\n' > "$repo/build/qbe/qbe" && chmod +x "$repo/build/qbe/qbe"
mkdir -p "$work/src" "$work/tmp" "$work/stub/bin"
printf 'int main() { return 0; }\n' > "$work/src/a.cpp"
printf 'int b() { return 1; }\n' > "$work/src/b.cpp"
printf 'int main(void) { return 0; }\n' > "$work/src/a.c"
# the EDG build: bin/eccp logs its arguments (one per line), then the NFCXX_ variables the driver's backend environment and trace
# unit set, to NFCXX_STUB_LOG, and fails
cat > "$work/stub/bin/eccp" <<'STUB'
#!/bin/sh
{ echo "eccp:"; for a in "$@"; do echo "  $a"; done
  echo "  env NFCXX_CC=${NFCXX_CC-unset} NFCXX_TRACE_UNIT=${NFCXX_TRACE_UNIT-unset} NFCXX_TRACE_OWNER=${NFCXX_TRACE_OWNER:+set}"
} >> "$NFCXX_STUB_LOG"
exit 1
STUB
chmod +x "$work/stub/bin/eccp"

# normalize: the repository, the work directory and the temporary directories (their names are random) become fixed words
normalize() {
  sed -e "s#$repo#<REPO>#g" -e "s#$work#<WORK>#g" \
      -e 's#nfcxx-[a-z]*\.[A-Za-z0-9_]*#nfcxx-<T>#g' -e 's#\.build\.[A-Za-z0-9]*/#.build.<T>/#g' \
      -e 's#nfcxx-[^/ ]*-[0-9][0-9]*-[A-Za-z0-9][A-Za-z0-9]*#nfcxx-<T>#g' -e 's#tmp\.[A-Za-z0-9][A-Za-z0-9-]*/#tmp.<R>/#g' -e 's#<WORK>/tmp/[^ :/]*#<TMPDIR>#g' -e 's#line [0-9][0-9]*: #line N: #g'
}

# run_case N LINE: writes the recording of case N to $work/out/case-NN.txt
run_case() {
  local n=$1 line=$2 envs args d
  envs=${line%%|*}; args=${line#*|}
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
      cat "$d/trace.json" 2>/dev/null | grep -o '"name": *"[^"]*"' | sort | uniq -c | normalize
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
  echo "driver-setup-rest2: recorded $n goldens in $here/golden"
  exit 0
fi

pass=0; fail=0
for f in "$work"/out/case-*.txt; do
  g=$here/golden/$(basename "$f")
  if [ -f "$g" ] && cmp -s "$f" "$g"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $(basename "$f"): $(head -1 "$f")"; [ -f "$g" ] && diff "$g" "$f" | head -20; fi
done
# The body's protocol checks (the statements it evals from the driver's environment) were retired with the
# bash body (driver-setup-rest, -rest2 and -stage: the Ruby driver reads its own planner's values).
echo "driver-setup-rest2: $pass passed, $fail failed"
[ "$fail" = 0 ]

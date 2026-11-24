#!/bin/bash
# The setup stage (B3, docs/notes/driver-setup-stage.md): the golden check of the driver's behavior on a table of argument
# lists (cases.txt). Each case runs ./nfcxx in its own directory, with an EDG build whose bin/eccp logs its arguments and exits
# 1, and records the stdout, the stderr, the status, the eccp calls, the files left behind and the trace's event names, with
# the paths normalized. golden/case-NN.txt is the recording on the bash setup (before the setup moved to the Ruby driver).
#   bash tests/driver-setup-stage/run.sh            compares every case with its golden
#   bash tests/driver-setup-stage/run.sh --record   writes the goldens (only on a tree whose behavior is the reference)
set -u
here=$(cd "$(dirname "$0")" && pwd -P); src=$(cd "$here/../.." && pwd -P)
mode=${1:-check}
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
# the environment is pinned: the driver reads ROOT/build (QBE, the EH shim, EDG's libC.a, cpfe's tree, cosmocc, cppfront), which
# EDG_BUILD does not cover, so the cases run a copy of the repository without build/ (and without .git). The copy is the
# checkout's files as they are, so the driver under test is this tree's. The tool the driver builds on first use
# (tools/cuda-rewrite) is built before the cases, its output discarded, so no case records the build's messages.
repo=$work/root
mkdir -p "$repo" && (cd "$src" && tar --exclude=./build --exclude=./.git -cf - .) | (cd "$repo" && tar -xf -) || exit 1
ruby "$repo/scripts/nfcxx-ensure-tool.rb" "$repo/tools/cuda-rewrite" "$repo/build/cuda-rewrite" >/dev/null 2>&1 || true
mkdir -p "$work/src" "$work/tmp" "$work/stub/bin"
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
  d=$work/run/$n; mkdir -p "$d"; cp "$work"/src/* "$d/"
  # the environment is fixed: the variables the driver reads are the ones named on the case's line
  # shellcheck disable=SC2086
  (cd "$d" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$work/tmp" EDG_BUILD="$work/stub" NFCXX_STUB_LOG="$d/eccp.log" \
      $envs "$repo/nfcxx" $args > "$d/.out" 2> "$d/.err"; echo $? > "$d/.rc")
  {
    echo "== case $n:${envs:+ $envs}${args:+ $args}"
    echo "-- status: $(cat "$d/.rc")"
    echo "-- stdout"; normalize < "$d/.out"
    echo "-- stderr"; normalize < "$d/.err"
    echo "-- eccp"; if [ -f "$d/eccp.log" ]; then normalize < "$d/eccp.log"; else echo "(none)"; fi
    echo "-- files"
    (cd "$d" && ls -A | grep -v -e '^\.' -e '^eccp.log$' -e '^a\.cpp$' -e '^b\.cpp$' -e '^a\.c$' | sort) | normalize
    if [ -f "$d/trace.json" ] || [ -f "$d/trace2.json" ]; then
      echo "-- trace names"
      cat "$d"/trace*.json 2>/dev/null | grep -o '"name": *"[^"]*"' | sort | uniq -c | normalize
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
  echo "driver-setup-stage: recorded $n goldens in $here/golden"
  exit 0
fi

pass=0; fail=0
for f in "$work"/out/case-*.txt; do
  g=$here/golden/$(basename "$f")
  if [ -f "$g" ] && cmp -s "$f" "$g"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $(basename "$f"): $(head -1 "$f")"; [ -f "$g" ] && diff "$g" "$f" | head -20; fi
done
# The body's protocol checks (the statements it evals from the driver's environment) were retired with the
# bash body (driver-setup-rest, -rest2 and -stage: the Ruby driver reads its own planner's values).
echo "driver-setup-stage: $pass passed, $fail failed"
[ "$fail" = 0 ]

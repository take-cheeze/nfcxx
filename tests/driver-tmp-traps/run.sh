#!/bin/bash
# Golden tests for the temporary directories of the driver (the body's mktemp -d, EXIT traps and temp_cleanup), against a stub
# EDG front end (eccp logs its argv and exits 0 after writing its -o file, or exits 1 with NFCXX_STUB_FAIL=1). Each case runs
# ./nfcxx in a fresh work directory with TMPDIR set to an empty directory T, and records:
#   - the status and stdout of the run;
#   - the driver's stderr lines (^nfcxx: and ^eccp:);
#   - the files and directories left in T when the run ends (normalized: random names are placeholders, numbers are N);
#   - the argv the stub eccp was given (normalized).
# Usage: bash tests/driver-tmp-traps/run.sh            compare every case with golden/
#        bash tests/driver-tmp-traps/run.sh --record   write golden/ (only for a baseline on origin/main)
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
mode=${1:-compare}
gold="$here/golden"
work=$(mktemp -d "${TMPDIR:-/tmp}/driver-tmp-traps.XXXXXX"); trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# the stub EDG front end: logs its argv, writes its -o file, or fails when NFCXX_STUB_FAIL=1
edg="$work/edg"; mkdir -p "$edg/bin"
cat > "$edg/bin/eccp" <<'EOF'
#!/bin/bash
echo "argv: $*" >> "$NFCXX_STUB_LOG"
o=""; prev=""
for a in "$@"; do if [ "$prev" = "-o" ]; then o=$a; fi; prev=$a; done
if [ "${NFCXX_STUB_FAIL:-0}" = 1 ]; then echo "eccp: stub failure" >&2; exit 1; fi
if [ -n "$o" ]; then : > "$o"; fi
exit 0
EOF
chmod +x "$edg/bin/eccp"

# a fresh source tree for one case: the inputs every case uses
newdir() {  # newdir NAME: a work directory with the inputs; prints its path
  local d="$work/case.$1"; rm -rf "$d"; mkdir -p "$d/home" "$d/tmp" "$d/sub"
  printf 'int main() { return 0; }\n' > "$d/a.cpp"
  printf 'int main() { return 0; }\n' > "$d/a.cu"
  printf 'int f() { return 1; }\n' > "$d/b.cpp"
  printf 'int f() { return 1; }\n' > "$d/b.o"
  printf 'int main() { return 0; }\n' > "$d/c.cpp2"
  printf 'export module m;\nexport int g() { return 2; }\n' > "$d/m.cppm"
  printf 'int main() { return 0; }\n' > "$d/sub/s.cpp"
  echo "$d"
}

# normalize: placeholders for the random names of mktemp and Ruby's mktmpdir, and for numbers (pids, timestamps)
norm() {  # norm < text: the case directory (CASE_DIR), its TMPDIR (CASE_T), the work directory and the repository
  sed -E -e "s#$CASE_DIR#<CASE>#g" -e "s#$CASE_T#<T>#g" -e "s#$work#<WORK>#g" -e "s#$repo#<REPO>#g" \
    -e 's#(nfcxx-[a-z]+|tmp|cudatmp|ctmp|ptmp|modplan)[^/ ]*#\1.<R>#g' -e 's#/cu/[A-Za-z0-9]+/#/cu/<H>/#g' \
    -e 's#[0-9]{3,}#N#g'
}

# run_case NAME [ENV=VAL ...] -- ARGS... : runs ./nfcxx with ARGS in the case directory; NFCXX_CASE_PRE (a shell snippet) runs first
run_case() {
  local name=$1; shift
  local envs=() pre=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  local d; d=$(newdir "$name"); CASE_DIR=$d; CASE_T="$d/tmp"
  local T="$d/tmp" log="$d/stub.log" out="$d/stdout" err="$d/stderr"
  : > "$log"
  if [ -n "${CASE_SETUP:-}" ]; then (cd "$d" && eval "$CASE_SETUP"); fi
  local st
  (cd "$d" && env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$d/home" TMPDIR="$T" RUBY=ruby \
      EDG_BUILD="$edg" EDG_BASE="$d/no-edg-base" NFCXX_BACKEND=gcc NFCXX_STUB_LOG="$log" "${envs[@]}" \
      "$repo/nfcxx" "$@" > "$out" 2> "$err")
  st=$?
  {
    echo "== $name"
    echo "status: $st"
    echo "-- stdout"
    norm < "$out"
    echo "-- stderr"
    grep -E '^(nfcxx|eccp):' "$err" | norm || true
    echo "-- left in TMPDIR"
    ( cd "$T" && find . -mindepth 1 | sort ) | while IFS= read -r p; do
      local k=f; [ -d "$T/$p" ] && k=d
      local np; np=$(printf '%s' "$p" | norm)
      if [ $k = d ]; then echo "dir $np entries=$(find "$T/$p" -mindepth 1 | wc -l)"; else echo "file $np"; fi
    done
    echo "-- eccp argv"
    norm < "$log"
  } > "$work/got.$name"
  if [ "$mode" = --record ]; then
    mkdir -p "$gold"; mv "$work/got.$name" "$gold/$name.txt"
  elif cmp -s "$work/got.$name" "$gold/$name.txt"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name (diff: $gold/$name.txt against the run)"; diff "$gold/$name.txt" "$work/got.$name" | head -20
  fi
}

# the cases: each gets a fresh work directory; the trace file (if any) is written in the work directory, not in TMPDIR
run_case cu-c-no-o -- -c a.cu
run_case cu-c-o -- -c a.cu -o out.o
run_case cu-link -- a.cu -o prog
run_case cpp2-c -- -c c.cpp2
run_case cpp2-c-o -- -c c.cpp2 -o c.o
run_case cpp-c -- -c a.cpp
run_case cpp-c-o-sub -- -c a.cpp -o sub/out.o
run_case cpp-link -- a.cpp -o prog
run_case link-objects -- b.o a.cpp -o prog
run_case c-keep -- -c a.cpp --keep-intermediates
run_case link-keep-env NFCXX_KEEP_INTERMEDIATES=1 -- a.cpp -o prog
run_case failing-compile NFCXX_STUB_FAIL=1 -- -c a.cpp
run_case failing-link NFCXX_STUB_FAIL=1 -- a.cpp -o prog
run_case failing-compile-keep NFCXX_STUB_FAIL=1 -- -c a.cpp --keep-intermediates
run_case module-build -- -c m.cppm -o m.o --module-dir=mods
run_case module-build-link -- m.cppm -o mprog --module-dir=mods
run_case e-run -- -E a.cpp
run_case e-run-cu -- -E a.cu
run_case trace-c -- --trace="$work/trace-c.json" -c a.cpp -o a.o
run_case trace-link -- --trace=trace-link.json a.cpp -o prog
run_case fsyntax -- -fsyntax-only a.cpp
run_case fsyntax-cu -- -fsyntax-only a.cu
run_case emit-c -- --emit-c a.cpp -o a.c
run_case depfile -- -c a.cpp -o a.o -MD -MF a.d
run_case cu-failing-compile NFCXX_STUB_FAIL=1 -- -c a.cu -o out.o
run_case subdir-link -- sub/s.cpp -o sub/prog

if [ "$mode" = --record ]; then echo "recorded $(ls "$gold" | wc -l) goldens in $gold"; exit 0; fi
echo "driver-tmp-traps: $pass passed, $fail failed"
[ "$fail" = 0 ]

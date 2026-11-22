#!/bin/bash
# The wrappers of the driver (--bundle-libs, --cuda-driver=) and their order before the rest of the driver: the golden of each case
# (stdout, the driver's stderr lines and the status, temporary paths normalized) is golden/, recorded from the driver before the
# wrappers moved to scripts/nfcxx.rb. A stub eccp logs the command the driver runs.
#   bash tests/driver-wrap/run.sh            checks against golden/
#   bash tests/driver-wrap/run.sh --record   writes golden/ (only before a change of behaviour)
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
record=0; [ "${1-}" = --record ] && record=1
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
mkdir -p "$work/tmp" "$work/edg/bin"
printf 'int a = 1;\n' > a.cpp
printf '#!/bin/sh\necho "eccp: $*" >&2\nexit 1\n' > "$work/edg/bin/eccp"; chmod +x "$work/edg/bin/eccp"

cases() {
  cat <<'CASES'
plain-c|-c a.cpp
bundle-plain|--bundle-libs -c a.cpp
bundle-exclude|--bundle-libs --bundle-exclude=libm -c a.cpp
cuda-auto|--cuda-driver=auto -c a.cpp
cuda-cudart|--cuda-driver=cudart -c a.cpp
cuda-bogus|--cuda-driver=bogus -c a.cpp
fso-bundle|-fsyntax-only --bundle-libs a.cpp
cuda-link|--cuda-driver=libcuda a.cpp -lcuda -o x.bin
CASES
}

run_case() {
  local so se
  so=$(cd "$work" && env -i PATH="$PATH" HOME="$HOME" RUBY="$(command -v ruby)" TMPDIR="$work/tmp" EDG_BUILD="$work/edg" NFCXX_BACKEND=gcc \
        "$repo/nfcxx" "$@" 2>"$work/stderr"; echo "status=$?")
  se=$(grep -E "^nfcxx:|^eccp:" "$work/stderr")
  printf 'stdout:\n%s\nstderr:\n%s\n' "$so" "$se" | sed -E -e "s#$work/tmp/[^ \"]*#TMPPATH#g" -e "s#$work#WORK#g" -e "s#$repo#ROOT#g" -e "s#/\.build\.[A-Za-z0-9]*/#/.build.TMP/#g"
}

while IFS='|' read -r name args; do
  [ -n "$name" ] || continue
  # shellcheck disable=SC2086
  got=$(run_case $args)
  if [ "$record" = 1 ]; then
    mkdir -p "$here/golden"; printf '%s\n' "$got" > "$here/golden/$name.txt"; pass=$((pass + 1))
  elif [ -f "$here/golden/$name.txt" ] && [ "$got" = "$(cat "$here/golden/$name.txt")" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name ($args)"
    [ -f "$here/golden/$name.txt" ] && diff <(cat "$here/golden/$name.txt") <(printf '%s\n' "$got") | sed 's/^/  /' | head -12
  fi
done < <(cases)

if [ "$record" = 1 ]; then echo "driver-wrap: recorded $pass cases"; exit 0; fi
echo "driver-wrap: $pass passed, $fail failed"
[ "$fail" = 0 ]

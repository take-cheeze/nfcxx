#!/bin/bash
# The early exits of the driver (the refusals and the emit-hip route the frozen body takes right after the argument loop, before
# the setup). The expected output (stdout, stderr and status of each case) is golden/ , recorded from the driver before the
# early exits moved to scripts/nfcxx-early-exit.rb. Each case runs the driver through scripts/nfcxx.rb (the live path).
#   bash tests/driver-early-exit/run.sh            checks the cases against golden/
#   bash tests/driver-early-exit/run.sh --record   writes golden/ from the current driver (only before a change of behaviour)
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
record=0; [ "${1-}" = --record ] && record=1
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
printf 'int main(){return 0;}\n' > a.cpp
printf 'int x;\n' > b.cu
mkdir -p "$work/edg/bin" && printf '#!/bin/sh\nexit 1\n' > "$work/edg/bin/eccp" && chmod +x "$work/edg/bin/eccp"

# the cases: NAME, the EDG_BUILD of the environment, then the arguments (one line each, word-split)
cases() {
  cat <<'EOF'
no-input|$work/edg|
emit-hip-cpp|$work/edg|--emit-hip a.cpp
emit-hip-two|$work/edg|--emit-hip b.cu b.cu
stdin-not-E|$work/edg|-c -
xlang-c|$work/edg|-c -x c a.cpp
xlang-none-ok|$work/edg|-c -x none a.cpp
depmode-no-c|$work/edg|-MD a.cpp
depmode-bogus-dialect|$work/edg|-c --dialect=bogus a.cpp
edg-missing|/nonexistent|-c a.cpp
edg-missing-compile-only-no|/nonexistent|--dialect=bogus a.cpp
dialect-bogus|$work/edg|-c --dialect=bogus a.cpp
EOF
}

# run_case NAME EDG ARGS: the driver's stdout, stderr and status, as one text block
run_case() {  # run_case NAME EDG ARGS...
  local name=$1 edg=$2; shift 2
  local so se st
  so=$(cd "$work" && env -i PATH="$PATH" HOME="$HOME" RUBY="$(command -v ruby)" EDG_BUILD="$edg" \
        ruby "$repo/scripts/nfcxx.rb" "$@" 2>"$work/stderr"; echo "status=$?")
  se=$(grep "^nfcxx:" "$work/stderr")   # the driver's own lines: the build tools print their compiler output too
  printf 'stdout:\n%s\nstderr:\n%s\n' "$so" "$se"
}

while IFS='|' read -r name edg args; do
  [ -n "$name" ] || continue
  edg=$(eval echo "$edg")
  # word-split the arguments as the other suites do (nfcxx-driver): no quoting inside the case table
  # shellcheck disable=SC2086
  got=$(run_case "$name" "$edg" $args)
  if [ "$record" = 1 ]; then
    mkdir -p "$here/golden"; printf '%s\n' "$got" > "$here/golden/$name.txt"
    pass=$((pass + 1))
  elif [ -f "$here/golden/$name.txt" ] && [ "$got" = "$(cat "$here/golden/$name.txt")" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name ($args)"
    [ -f "$here/golden/$name.txt" ] && diff <(cat "$here/golden/$name.txt") <(printf '%s\n' "$got") | sed 's/^/  /' | head -12
  fi
done < <(cases)

if [ "$record" = 1 ]; then echo "driver-early-exit: recorded $pass cases"; exit 0; fi
echo "driver-early-exit: $pass passed, $fail failed"
[ "$fail" = 0 ]

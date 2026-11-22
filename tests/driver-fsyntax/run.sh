#!/bin/bash
# -fsyntax-only (the driver's type check): the driver rewrites the command (a -c compile with a temporary object, or the -E
# route without -fsyntax-only) and runs it again. A stub eccp logs the command it is given, so the golden shows the rewrite.
# The expected output (stdout, stderr and status of each case, with temporary paths normalized) is golden/, recorded from the
# driver before the rewrite moved to scripts/nfcxx-syntax-only.rb.
#   bash tests/driver-fsyntax/run.sh            checks the cases against golden/
#   bash tests/driver-fsyntax/run.sh --record   writes golden/ (only before a change of behaviour)
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
record=0; [ "${1-}" = --record ] && record=1
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
mkdir -p "$work/tmp" "$work/edg/bin"
printf 'int a = 1;\n' > a.cpp
# the stub eccp: logs its arguments to stderr and fails, so the run stops at the compile
printf '#!/bin/sh\necho "eccp: $*" >&2\nexit 1\n' > "$work/edg/bin/eccp"; chmod +x "$work/edg/bin/eccp"

# the cases: NAME, then the arguments (one line each, word-split)
cases() {
  cat <<'EOF'
fso-c|-fsyntax-only -c a.cpp
fso-c-o|-c a.cpp -fsyntax-only -o out.o
fso-E|-fsyntax-only -E a.cpp
fso-no-c|-fsyntax-only a.cpp -o x.o
fso-std|-fsyntax-only -std=c++17 -DX=1 a.cpp
fso-missing|-fsyntax-only -c missing.cpp
plain-c|-c a.cpp
EOF
}

# run_case ARGS...: stdout, the driver's stderr and the status, with the temporary paths normalized
run_case() {
  local so se st
  so=$(cd "$work" && env -i PATH="$PATH" HOME="$HOME" RUBY="$(command -v ruby)" TMPDIR="$work/tmp" EDG_BUILD="$work/edg" NFCXX_BACKEND=gcc \
        "$repo/nfcxx" "$@" 2>"$work/stderr"; echo "status=$?")
  se=$(grep -E "^nfcxx:|^eccp:|error" "$work/stderr")
  printf 'stdout:\n%s\nstderr:\n%s\n' "$so" "$se" | sed -E -e "s#$work/tmp/[^ \"]*#TMPPATH#g" -e "s#$work#WORK#g" -e 's#WORKTMP/x.o#TMPPATH#g'
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

if [ "$record" = 1 ]; then echo "driver-fsyntax: recorded $pass cases"; exit 0; fi
echo "driver-fsyntax: $pass passed, $fail failed"
[ "$fail" = 0 ]

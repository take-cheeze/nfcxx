#!/bin/bash
# The driver's temporary directories are removed on every exit: a .cpp2 build (cppfront's translation directory and the
# front end's temporary directory) leaves nothing in TMPDIR, on success and on failure, run by the bash driver directly and
# by the Ruby driver (NFCXX_RUBY_DRIVER=1). A failing build is a forced C error; a success is a .cpp2 file alone and with a C file.
# Needs cppfront (build/cppfront); skipped without it.
#   bash tests/driver-tmp-leak/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
if [ ! -x "$repo/build/cppfront" ]; then echo "driver-tmp-leak: skipped (no build/cppfront)"; exit 0; fi
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
src="$work/src"; mkdir -p "$src"
printf '#include <cstdio>\nmain: () -> int = {\n    std::printf("hi\\n");\n    return 0;\n}\n' > "$src/hello.cpp2"
printf 'int cfn(void) { return 1; }\n' > "$src/cfn.c"
printf 'int cfn(void) { return ; ;\n' > "$src/bad.c"

# check NAME STATUS-WANT ENV... -- ARGS: runs the driver (bash, or the Ruby driver with NFCXX_RUBY_DRIVER=1) in $src with a
# fresh TMPDIR; the status must be STATUS-WANT and TMPDIR must be empty afterwards
check() {
  local name=$1 want=$2; shift 2
  local env_words=() args=() sep=0
  for a in "$@"; do if [ $sep = 0 ] && [ "$a" = -- ]; then sep=1; elif [ $sep = 0 ]; then env_words+=("$a"); else args+=("$a"); fi; done
  local t st left
  t=$(mktemp -d)
  ( cd "$src" && env TMPDIR="$t" ${env_words[@]+"${env_words[@]}"} "$repo/nfcxx" "${args[@]}" >/dev/null 2>&1 ); st=$?
  left=$(find "$t" -mindepth 1 | wc -l)
  rm -rf "$t"
  if [ "$st" = "$want" ] && [ "$left" = 0 ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "FAIL $name: status $st (want $want), $left entries left in TMPDIR"; fi
}

for mode in bash ruby; do
  if [ $mode = ruby ]; then ruby=(NFCXX_RUBY_DRIVER=1); else ruby=(); fi
  check "$mode: cpp2 alone succeeds" 0 ${ruby[@]+"${ruby[@]}"} -- -o p hello.cpp2
  check "$mode: cpp2 and C succeed" 0 ${ruby[@]+"${ruby[@]}"} -- -o p hello.cpp2 cfn.c
  check "$mode: cpp2 and bad C fail" 1 ${ruby[@]+"${ruby[@]}"} -- -o p hello.cpp2 bad.c
done

echo "driver-tmp-leak: $pass passed, $fail failed"
[ "$fail" = 0 ]

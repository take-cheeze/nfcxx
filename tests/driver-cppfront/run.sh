#!/bin/bash
# The cppfront refusals of ./nfcxx (scripts/nfcxx-cpp2.rb run, the .cpp2 step of cpp2_prepare): with build/cppfront missing, or
# with no include/cpp2util.h under the cppfront source (CPPFRONT_SRC), a .cpp2 input is refused with the message and status 2 the
# bash prints, both by the bash driver and by the Ruby driver (NFCXX_RUBY_DRIVER=1). The cases run on a copy of the driver whose
# build directory links everything except what the case removes, so the shared build is not touched.
#   bash tests/driver-cppfront/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
if [ ! -x "$repo/build/cppfront" ] || [ ! -d "$repo/build/cppfront-src" ]; then echo "driver-cppfront: skipped (no build/cppfront or cppfront-src)"; exit 0; fi
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
printf '#include <cstdio>\nmain: () -> int = {\n    std::printf("hi\\n");\n    return 0;\n}\n' > "$work/hello.cpp2"

# mk DIR EXCLUDE...: a copy of the driver in DIR, its build directory linking everything of the repository's build except EXCLUDE
mk() {
  local dir=$1; shift
  mkdir -p "$dir/build" "$dir/tests/driver-body"
  cp "$repo/nfcxx" "$dir/nfcxx"; cp -r "$repo/scripts" "$dir/scripts"; cp "$repo/tests/driver-body/nfcxx-oracle.sh" "$dir/tests/driver-body/nfcxx-oracle.sh"
  local e x s skip
  for e in "$repo"/build/*; do
    x=$(basename "$e"); skip=0
    for s in "$@"; do [ "$x" = "$s" ] && skip=1; done
    [ $skip = 1 ] || ln -s "$e" "$dir/build/$x"
  done
}

# check NAME MSG DIR ENV... : runs the driver of DIR on hello.cpp2 with the environment words; the status must be 2 and
# stderr must be exactly MSG
check() {
  local name=$1 msg=$2 dir=$3; shift 3
  local out st
  out=$(cd "$work" && env TMPDIR="$work" "$@" bash "$dir/nfcxx" -o p hello.cpp2 2>&1 >/dev/null); st=$?
  if [ "$st" = 2 ] && [ "$out" = "$msg" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "FAIL $name: status $st, stderr [$out] (want status 2 and [$msg])"; fi
}

mk "$work/nobin" cppfront
MSG_NOBIN="nfcxx: cppfront is not built; run scripts/setup-cppfront.sh (docs/notes/cpp2.md)"
mkdir -p "$work/emptysrc"
mk "$work/nohdr"
MSG_NOHDR="nfcxx: no cpp2util.h under $work/emptysrc; run scripts/setup-cppfront.sh"
for mode in bash ruby; do
  if [ $mode = ruby ]; then ruby_env=(NFCXX_RUBY_DRIVER=1); else ruby_env=(); fi
  check "$mode: cppfront not built" "$MSG_NOBIN" "$work/nobin" ${ruby_env[@]+"${ruby_env[@]}"}
  check "$mode: no cpp2util.h" "$MSG_NOHDR" "$work/nohdr" ${ruby_env[@]+"${ruby_env[@]}"} CPPFRONT_SRC="$work/emptysrc"
done

echo "driver-cppfront: $pass passed, $fail failed"
[ "$fail" = 0 ]

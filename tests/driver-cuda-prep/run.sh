#!/bin/bash
# The .cu and .cpp2 preparation (cu_prepare and cpp2_prepare of the frozen body): each case runs ./nfcxx on a .cu or .cpp2
# input with -c or a link, with and without -o, -I, -D and --cuda-driver=. A stub eccp logs its arguments and fails, so the run
# stops at the compile. The golden records, per case, the driver's stdout, its stderr, its status and the stub's log, with the
# temporary paths and the cache keys normalized (golden/ is recorded from the driver before a change of the preparation).
#   bash tests/driver-cuda-prep/run.sh            checks the cases against golden/
#   bash tests/driver-cuda-prep/run.sh --record   writes golden/ (only before a change of behaviour)
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
record=0; [ "${1-}" = --record ] && record=1
if [ ! -x "$repo/build/cuda-rewrite" ] || [ ! -x "$repo/build/cppfront" ]; then
  echo "driver-cuda-prep: skipped (no build/cuda-rewrite or build/cppfront)"; exit 0
fi
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tmp" "$work/home" "$work/edg/bin" "$work/inc" "$work/sub" "$work/out"
cat > "$work/a.cu" <<'EOF'
#include "h.h"
__global__ void kern(int *p) { p[0] = VALUE; }
int main() { return FOO; }
EOF
printf '#define VALUE 7\n' > "$work/inc/h.h"
printf '#include "h.h"\n__global__ void other(int *p) { p[1] = VALUE + 1; }\n' > "$work/b.cu"
printf '__global__ void sub(float *p) { p[0] = 0.5f; }\nint sub_host() { return 3; }\n' > "$work/sub/c.cu"
printf 'main: () -> int = {\n    std::cout << "hi\\n";\n    return 0;\n}\n' > "$work/x.cpp2"
printf 'main: () -> int = {\n    return 1;\n}\n' > "$work/y.cpp2"
# the stub eccp: logs its arguments (ECCP_LOG) and fails
printf '#!/bin/sh\necho "eccp: $*" >> "$ECCP_LOG"\nexit 1\n' > "$work/edg/bin/eccp"; chmod +x "$work/edg/bin/eccp"

# the cases: NAME|ARGUMENTS (word-split)
cases() {
  cat <<'EOF'
cu-c|-c a.cu
cu-c-o|-c a.cu -o out/a.o
cu-c-o-nodir|-c b.cu -o b.o
cu-link|a.cu
cu-link-o|a.cu -o prog
cu-c-I|-c a.cu -Iinc -o a.o
cu-link-I|-Iinc a.cu -o prog
cu-c-D|-c a.cu -DFOO=2 -o a.o
cu-link-D|-DFOO=2 a.cu -o prog
cu-cudriver-link|--cuda-driver=cudart a.cu -o prog
cu-cudriver-c|--cuda-driver=libcuda -c a.cu -o a.o
cu-two-c|-c a.cu b.cu
cu-sub-c|-c sub/c.cu -o c.o
cu-two-link|a.cu sub/c.cu -o prog
cu-c-missing-dir|-c nosuch/x.cu -o n.o
cu-keep-c|--keep-intermediates -c a.cu -o keep.o
cpp2-c-o|-c x.cpp2 -o x.o
cpp2-c|-c x.cpp2
cpp2-link|x.cpp2 -o xprog
cpp2-link-I|-Iinc x.cpp2 -o xprog
cpp2-two-c|-c x.cpp2 y.cpp2
cpp2-c-missing|-c nosuch.cpp2 -o n.o
mix-c|-c a.cu x.cpp2 -o mix.o
mix-link|a.cu x.cpp2 -o mixprog
EOF
}

# run_case ARGS...: the driver's stdout, stderr and status, and the stub's log, with the paths and keys normalized
run_case() {
  local so se st log
  rm -f "$work/eccp.log" "$work/stderr"
  so=$(cd "$work" && env -i PATH="$PATH" HOME="$work/home" RUBY="$(command -v ruby)" TMPDIR="$work/tmp" \
        EDG_BUILD="$work/edg" ECCP_LOG="$work/eccp.log" "$repo/nfcxx" "$@" 2>"$work/stderr" </dev/null; echo "status=$?")
  se=$(cat "$work/stderr")
  log=$(cat "$work/eccp.log" 2>/dev/null)
  # the diagnostics of the rewriter wrap a long path onto indented lines, at a width that depends on the temporary directory's name: an indented line is joined to the one before it
  se=$(printf '%s\n' "$se" | awk '{ if (/^ /) { sub(/^ +/, ""); printf "%s", $0 } else { if (NR > 1) printf "\n"; printf "%s", $0 } } END { printf "\n" }')
  printf 'stdout:\n%s\nstderr:\n%s\neccp:\n%s\n' "$so" "$se" "$log" \
    | sed -E -e "s#$work#WORK#g" -e "s#$repo#REPO#g" -e "s#$(realpath -m "$repo/build/cppfront-src")#REPO/build/cppfront-src#g" -e 's#nfcxx-tmp\.[0-9A-Za-z_-]+#nfcxx-tmp.T#g' -e 's#nfcxx-cu[0-9A-Za-z_-]+#nfcxx-cu.T#g' \
        -e 's#(nfcxx-[a-z]+\.|tmp\.)[0-9A-Za-z_-]{6,}#\1T#g' -e 's#\b[0-9a-f]{40}\b#HASH#g' -e 's#\b[0-9a-f]{16}\b#HASH16#g' -e 's#\.build\.[0-9A-Za-z_]+#.build.T#g'
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

if [ "$record" = 1 ]; then echo "driver-cuda-prep: recorded $pass cases"; exit 0; fi
echo "driver-cuda-prep: $pass passed, $fail failed"
[ "$fail" = 0 ]

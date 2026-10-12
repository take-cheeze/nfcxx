#!/usr/bin/env bash
# Speed of nfcast with and without the inlining of small functions (docs/notes/ast.md, "Inlining"): runs tests/ast/bench/*.lua,
# best of RUNS (default 3), in seconds, once per target. Indicative only; nothing asserts on a time. Not part of CI.
#   tests/ast/bench.sh [TARGET...]      TARGET: host (g++ -O2 -std=c++20, the default), gcc and qbe (nfcxx back ends)
#   RUNS=n                              runs per program and setting
#   LUA=/path/to/lua                    also time a reference Lua (default: build/ast-ref/lua when it exists)
cd "$(dirname "$0")/../.."
targets=("$@")
[ ${#targets[@]} = 0 ] && targets=(host)
runs=${RUNS:-3}
lua=${LUA:-}
[ -z "$lua" ] && [ -x build/ast-ref/lua ] && lua=build/ast-ref/lua
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
srcs=(lib/ast/nfcast_core.cpp lib/ast/nfcast_ops.cpp lib/ast/nfcast_parse.cpp lib/ast/nfcast_nodes.cpp lib/ast/nfcast_lib.cpp)
best() {  # best RUNS wall-clock times of a command (output discarded), in seconds
  local b=999999 t i
  for i in $(seq 1 "$runs"); do
    local s=$(date +%s.%N)
    "$@" > /dev/null 2>&1
    t=$(echo "$(date +%s.%N) - $s" | bc -l)
    if (( $(echo "$t < $b" | bc -l) )); then b=$t; fi
  done
  printf '%.2f' "$b"
}
for t in "${targets[@]}"; do
  case $t in
    host) g++ -O2 -std=c++20 -I lib/ast tests/ast/driver.cpp "${srcs[@]}" -o "$tmp/driver.$t" || exit 1 ;;
    *) NFCXX_BACKEND=$t ./nfcxx -O2 -I lib/ast tests/ast/driver.cpp "${srcs[@]}" -o "$tmp/driver.$t" || exit 1 ;;
  esac
  printf '%-8s %-10s %10s %10s %8s %s\n' "$t" program "inline" "no inline" speedup "${lua:+reference Lua}"
  for f in tests/ast/bench/*.lua; do
    name=$(basename "$f" .lua)
    on=$(NFCAST_INLINE=1 "$tmp/driver.$t" "$f" 2>&1 | md5sum | cut -c1-8)
    off=$(NFCAST_INLINE=0 "$tmp/driver.$t" "$f" 2>&1 | md5sum | cut -c1-8)
    [ "$on" = "$off" ] || echo "WARNING: $name prints different results with and without inlining"
    ton=$(NFCAST_INLINE=1 best "$tmp/driver.$t" "$f")
    toff=$(NFCAST_INLINE=0 best "$tmp/driver.$t" "$f")
    tref=""
    [ -n "$lua" ] && tref=$(best "$lua" "$f")
    printf '%-8s %-10s %10s %10s %7.2fx %s\n' "$t" "$name" "$ton" "$toff" "$(echo "$toff / $ton" | bc -l)" "$tref"
  done
done

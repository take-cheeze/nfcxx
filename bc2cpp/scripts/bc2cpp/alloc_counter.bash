#!/usr/bin/env bash
# ALLOC_COUNTER: links a counting copy of the headless host (trace_host_alloc) for a closed bc2cpp build: the same
# objects and libraries as trace_host, plus alloc_counter.cxx, with `ld --wrap` on mrb_obj_alloc and
# mrb_basic_alloc_func. The host then writes a count per allocation chain at exit when BC2CPP_ALLOCCNT_OUT names a
# file. Read the counts with alloc_counter_report.rb; the whole sweep is `ALLOC_COUNT_DIR=DIR host_sweep.bash BUILD`.
#
# Usage: scripts/bc2cpp/alloc_counter.bash [BUILD_DIR]   (default ./build-closed-bc2cpp)
#   BC2CPP_GAME_DIR  the RPG2000 project the plain-host step is run on (default: the world's data/Nepheshel206beta/...).
#   Output: BUILD_DIR/trace-host/trace_host_alloc, linked -no-pie so a return address is a link address (addr2line).
set -euo pipefail

tree="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
root="${BC2CPP_WORLD_ROOT:-$tree}"
build_dir="$(cd "${1:-$root/build-closed-bc2cpp}" && pwd)"
host_dir="$build_dir/trace-host"
mruby_lib="$build_dir/closed/lib/libmruby.a"
mruby_inc="$build_dir/closed/include"
cxx="${CXX:-c++}"

if [ ! -s "$host_dir/trace_host.o" ] || [ ! -s "$host_dir/liblvgl.a" ] || [ ! -s "$host_dir/libuni-algo.a" ]; then
  game="${BC2CPP_GAME_DIR:-$root/data/Nepheshel206beta/Nepheshel206Rbeta}"
  echo "alloc_counter: building the plain host first (trace_host.bash, one frame)"
  BC2CPP_HOST_FRAMES=1 "$tree/scripts/bc2cpp/trace_host.bash" "$build_dir" "$game" > "$host_dir.build.log" 2>&1 || true
fi
for f in trace_host.o liblvgl.a libuni-algo.a; do
  [ -s "$host_dir/$f" ] || { echo "alloc_counter: $host_dir/$f is missing; see $host_dir.build.log" >&2; exit 1; }
done

# The closed target's defines (trace_host.bash, int_defs there too); the layout-relevant ones must match libmruby.a.
int_defs=()
[ -d "$build_dir/closed/mrbgems/mruby-bigint" ] && int_defs+=(-DMRB_USE_BIGINT)
[ "${BC2CPP_CLOSED_WIO_INT:-0}" = 1 ] && int_defs+=(-DMRB_INT32)
"$cxx" -std=gnu++17 -O2 -g -Wall \
  -DMRB_ENABLE_CXX_EXCEPTION -DMRB_DEBUG "${int_defs[@]}" \
  -DMRB_STR_LENGTH_MAX=0 -DMRB_HEAP_PAGE_SIZE=256 -DKHASH_INITIAL_SIZE=16 \
  -I"$mruby_inc" -I"$root/3rd/mruby/include" \
  -c "$tree/scripts/bc2cpp/alloc_counter.cxx" -o "$host_dir/alloc_counter.o"

"$cxx" -no-pie -o "$host_dir/trace_host_alloc" "$host_dir/trace_host.o" "$host_dir/alloc_counter.o" \
  "$mruby_lib" "$host_dir/liblvgl.a" "$host_dir/libuni-algo.a" -lpthread -lm -Wl,--gc-sections \
  -Wl,--wrap=mrb_obj_alloc -Wl,--wrap=mrb_basic_alloc_func
echo "built $host_dir/trace_host_alloc"

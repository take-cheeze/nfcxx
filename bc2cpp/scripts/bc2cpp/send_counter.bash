#!/usr/bin/env bash
# SEND_COUNTER: links a counting copy of the headless host (trace_host_counted) for a closed bc2cpp build: the same
# objects and libraries as trace_host, plus send_counter.cxx, with `ld --wrap` on the by-name send, yield and method
# search functions the build's libmruby.a defines. The host then writes a count per call site at exit when
# BC2CPP_SENDCNT_OUT names a file (send_counter.cxx). Read the counts with send_counter_report.rb; the whole sweep is
# `SEND_COUNT_DIR=DIR scripts/bc2cpp/host_sweep.bash BUILD`.
#
# Usage: scripts/bc2cpp/send_counter.bash [BUILD_DIR]   (default ./build-closed-bc2cpp)
#   BC2CPP_GAME_DIR  the RPG2000 project that plain-host step is run on (default: the world's data/Nepheshel206beta/...).
#   BUILD_DIR must have had trace_host.bash run on it once (trace_host.o and the LVGL and uni-algo libraries); this
#   builds that part itself, for one frame, when it is missing. Output: BUILD_DIR/trace-host/trace_host_counted,
#   linked -no-pie so a return address in the counts is a link address (nm, addr2line).
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
  echo "send_counter: building the plain host first (trace_host.bash, one frame)"
  BC2CPP_HOST_FRAMES=1 "$tree/scripts/bc2cpp/trace_host.bash" "$build_dir" "$game" > "$host_dir.build.log" 2>&1 || true
fi
for f in trace_host.o liblvgl.a libuni-algo.a; do
  [ -s "$host_dir/$f" ] || { echo "send_counter: $host_dir/$f is missing; see $host_dir.build.log" >&2; exit 1; }
done

# Wrap only what the library defines: the baseline fork has no mrb_method_memo or mrb_funcall_send_with_method.
defined=$(nm -g --defined-only "$mruby_lib" 2>/dev/null | awk '$2 ~ /^[TW]$/ {print $3}')
wrap_flags=()
defs=()
for sym in mrb_funcall mrb_funcall_id mrb_funcall_argv mrb_funcall_with_block mrb_funcall_send mrb_funcall_with_method \
           mrb_funcall_send_with_method mrb_yield mrb_yield_argv mrb_yield_with_class mrb_method_search_vm \
           mrb_method_memo mrb_respond_to mrb_obj_respond_to mrb_vm_find_method mrb_method_search; do
  if grep -qx "$sym" <<<"$defined"; then
    wrap_flags+=("-Wl,--wrap=$sym")
    defs+=("-DSC_HAVE_$sym")
  fi
done
echo "send_counter: wrapping ${#wrap_flags[@]} functions"

# The closed target's defines (trace_host.bash); the layout-relevant ones must match libmruby.a.
"$cxx" -std=gnu++17 -O2 -g -Wall "${defs[@]}" \
  -DMRB_ENABLE_CXX_EXCEPTION -DMRB_DEBUG -DMRB_USE_BIGINT \
  -DMRB_STR_LENGTH_MAX=0 -DMRB_HEAP_PAGE_SIZE=256 -DKHASH_INITIAL_SIZE=16 \
  -I"$mruby_inc" -I"$root/3rd/mruby/include" \
  -c "$tree/scripts/bc2cpp/send_counter.cxx" -o "$host_dir/send_counter.o"

"$cxx" -no-pie -o "$host_dir/trace_host_counted" "$host_dir/trace_host.o" "$host_dir/send_counter.o" \
  "$mruby_lib" "$host_dir/liblvgl.a" "$host_dir/libuni-algo.a" -lpthread -lm -Wl,--gc-sections "${wrap_flags[@]}"
echo "built $host_dir/trace_host_counted"

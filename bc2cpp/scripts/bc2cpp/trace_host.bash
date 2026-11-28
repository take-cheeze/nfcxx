#!/usr/bin/env bash
# Headless host for the closed bc2cpp libmruby.a: builds scripts/bc2cpp/trace_host.cxx
# against it, runs RPG2000 New Game for a bounded number of frames, and checks
# the BC2CPP_TRACE_TYPES dump. No SDL, no window: LVGL draws into a discarded
# framebuffer and the input bridges are the closed build's own no-ops.
#
# Usage:
#   scripts/bc2cpp/trace_host.bash [BUILD_DIR] [GAME_DIR]
#
#   BUILD_DIR  the closed_build.bash build (default ./build-closed-bc2cpp);
#              must contain closed/lib/libmruby.a and closed/include/mrbconf.h.
#              Build it with BC2CPP_TRACE_TYPES=1 in the environment to get the
#              PARAM_/RETURN_ rows; without it the dump is not produced and
#              this script says so.
#   GAME_DIR   an RPG2000 project (default data/Nepheshel206beta/Nepheshel206Rbeta,
#              from scripts/download/nepheshel.bash).
#
# Environment:
#   BC2CPP_HOST_FRAMES  RPG2k#main_loop frames to run (default 600).
#   BC2CPP_TRACE_TYPES_OUT  dump file (default BUILD_DIR/trace-host/param_trace.tsv).
#   BC2CPP_HOST_BATTLE_TROOP  open a battle against this troop id after New Game.
#   BC2CPP_HOST_BATTLE_PLAY  1: drive that battle with confirm taps.
#   BC2CPP_HOST_KEYS  scripted key taps, "FRAME:KEY,..." (KEY an RGSS::Input
#                     constant such as C, B or DOWN), e.g. to open the menu or
#                     save. Saving writes into GAME_DIR, so point it at a copy.
#   BC2CPP_HOST_CONTINUE  1: pick Continue on the title instead of New Game.
#   BC2CPP_HOST_PREVIEW_MAP  start New Game on this map id's centre tile.
#   BC2CPP_HOST_GC_STRESS  a full GC before every Nth object allocation after the boot (1: every
#                     one, as MRB_GC_STRESS), so a missing GC root shows up; host_sweep.bash passes it on.
#   BC2CPP_HOST_CLASS_MUTATIONS  a directory: what the run changed in the classes the boot left goes to DIR/PID.tsv
#                     (class_mutations.hxx); class_mutations_report.rb reads a sweep's.
#   BC2CPP_HOST_ROM_GRAPH  1: link the class graph the boot leaves back into the host as const data (mruby's
#                     MRB_ROM_CLASS_GRAPH), after checking that a boot on it leaves the same graph.
#
# Needs on PATH: c++ (g++), cc, ar, nproc, clock_gettime-capable libc (Linux).
set -euo pipefail

# WORLD_ROOT (tools/bc2cpp/world_root.rb): bc2cpp's own tree, and the repository it compiles (the same unless BC2CPP_WORLD_ROOT).
tree="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
root="${BC2CPP_WORLD_ROOT:-$tree}"
build_dir="$(cd "${1:-$root/build-closed-bc2cpp}" && pwd)"
game_dir="$(cd "${2:-$root/data/Nepheshel206beta/Nepheshel206Rbeta}" && pwd)"
frames="${BC2CPP_HOST_FRAMES:-600}"
host_dir="$build_dir/trace-host"
dump="${BC2CPP_TRACE_TYPES_OUT:-$host_dir/param_trace.tsv}"
mruby_lib="$build_dir/closed/lib/libmruby.a"
mruby_inc="$build_dir/closed/include"
jobs="$(nproc)"
cxx="${CXX:-c++}"

for tool in "$cxx" cc ar nproc; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found on PATH" >&2; exit 1; }
done
for f in "$mruby_lib" "$mruby_inc/mrbconf.h" "$root/3rd/lvgl/lvgl.h" \
         "$root/3rd/uni-algo/src/data.cpp" "$root/include/lv_conf.h"; do
  [ -e "$f" ] || { echo "error: missing $f (run closed_build.bash / git submodule update --init --depth 1)" >&2; exit 1; }
done

mkdir -p "$host_dir/lvgl" "$host_dir/uni-algo"

# LVGL 9 as the device builds it: include/lv_conf.h, the same config the
# RGSS natives compile against (mruby-rgss/mrbgem.rake).
export LVGL_CFLAGS="-O1 -g -DLV_CONF_INCLUDE_SIMPLE -I$root/include -I$root/3rd/lvgl -I$root/3rd/lvgl/src"
compile_lvgl() {
  local src="$1" obj
  obj="$host_dir/lvgl/$(echo "${src#"$root/3rd/lvgl/"}" | tr '/' '_').o"
  if [ ! -s "$obj" ] || [ "$src" -nt "$obj" ]; then
    # shellcheck disable=SC2086
    cc -c $LVGL_CFLAGS -w "$src" -o "$obj"
  fi
}
export -f compile_lvgl
export root host_dir
# src/drivers holds the host-window backends (SDL, X11, ...) that the device
# builds never compile and that need headers this host does not have.
find "$root/3rd/lvgl/src" -name '*.c' -not -path '*/drivers/*' -print0 \
  | xargs -0 -P "$jobs" -n 1 bash -c 'compile_lvgl "$0"'
ar rcs "$host_dir/liblvgl.a" "$host_dir"/lvgl/*.o

# uni-algo's data unit, with the same trims build_config.rb's UNI_ALGO_TRIM_DEFINES
# gives mruby-rgss and mruby-lcf, so the tables the headers expose are present.
uni_defs="-DUNI_ALGO_DISABLE_CASE -DUNI_ALGO_DISABLE_PROP -DUNI_ALGO_DISABLE_SCRIPT -DUNI_ALGO_DISABLE_SEGMENT_GRAPHEME -DUNI_ALGO_DISABLE_SEGMENT_WORD"
# shellcheck disable=SC2086
"$cxx" -std=gnu++17 -O1 -g -c $uni_defs -I"$root/3rd/uni-algo/include" \
  "$root/3rd/uni-algo/src/data.cpp" -o "$host_dir/uni-algo/data.o"
ar rcs "$host_dir/libuni-algo.a" "$host_dir/uni-algo/data.o"

lookup_defs=()
lookup_link=()
if [ "${BC2CPP_METHOD_LOOKUP_HOOK:-0}" = 1 ]; then
  lookup_defs=(-DMRB_USE_METHOD_LOOKUP_HOOK)
  lookup_link=(-no-pie)
fi

# Driver. The defines are the closed target's (build_config.rb `closed`):
# C++ exception mode, debug, and the string/heap/khash caps. Layout-relevant
# ones must match libmruby.a. The integer model: MRB_USE_BIGINT where the build has mruby-bigint, MRB_INT32 for the Wio model
# (build_config.rb, BC2CPP_CLOSED_WIO_INT=1, which the build and this run must share).
int_defs=()
[ -d "$build_dir/closed/mrbgems/mruby-bigint" ] && int_defs+=(-DMRB_USE_BIGINT)
# MRB_ROM_CLASS_GRAPH (build_config.rb): class.h's method-table accessor then reads a ROM class's slot.
grep -a -q mrb_rom_graph_claim "$mruby_lib" && int_defs+=(-DMRB_ROM_CLASS_GRAPH)
[ "${BC2CPP_CLOSED_WIO_INT:-0}" = 1 ] && int_defs+=(-DMRB_INT32)
# GFX_BACKEND: a libmruby.a built with RGSS_GFX_OWN (BC2CPP_CLOSED_GFX=own) draws through its own compositor.
grep -a -q rgss_own_display_create "$mruby_lib" && int_defs+=(-DRGSS_GFX_OWN)
"$cxx" -std=gnu++17 -O1 -g -Wall "${lookup_defs[@]}" \
  -DMRB_ENABLE_CXX_EXCEPTION -DMRB_DEBUG "${int_defs[@]}" \
  -DMRB_STR_LENGTH_MAX=0 -DMRB_HEAP_PAGE_SIZE=256 -DKHASH_INITIAL_SIZE=16 \
  -DLV_CONF_INCLUDE_SIMPLE \
  -I"$mruby_inc" -I"$root/3rd/mruby/include" -I"$root/include" -I"$root/3rd/lvgl" \
  -c "$tree/scripts/bc2cpp/trace_host.cxx" -o "$host_dir/trace_host.o"
# --gc-sections: the closed libmruby.a is built with one section per function (build_config.rb
# GC_SECTIONS), so the host keeps only what it reaches, as a device build does.
"$cxx" "${lookup_link[@]}" -o "$host_dir/trace_host" "$host_dir/trace_host.o" \
  "$mruby_lib" "$host_dir/liblvgl.a" "$host_dir/libuni-algo.a" -lpthread -lm -Wl,--gc-sections \
  -Wl,--wrap=mrb_obj_alloc

echo "built $host_dir/trace_host"

# ROM_GRAPH (BC2CPP_HOST_ROM_GRAPH=1): the class graph this host's boot leaves, dumped as C (trace_host.cxx,
# BC2CPP_HOST_ROM_GRAPH_DUMP), is linked back in, so its classes are const data; the boot of that host must dump the
# same C again, or the graph is not what the boot builds.
if [ "${BC2CPP_HOST_ROM_GRAPH:-0}" = 1 ]; then
  graph="$host_dir/rom_graph.c"
  BC2CPP_HOST_ROM_GRAPH_DUMP="$graph" BC2CPP_HOST_ROM_GRAPH_DUMP_ONLY=1 "$host_dir/trace_host" "$game_dir" 1 \
    > "$host_dir/rom_graph.log" 2>&1 || { cat "$host_dir/rom_graph.log" >&2; exit 1; }
  cc -std=gnu99 -O1 -g -c "${int_defs[@]}" -I"$mruby_inc" -I"$root/3rd/mruby/include" "$graph" \
    -o "$host_dir/rom_graph.o"
  "$cxx" "${lookup_link[@]}" -o "$host_dir/trace_host" "$host_dir/trace_host.o" "$host_dir/rom_graph.o" \
    "$mruby_lib" "$host_dir/liblvgl.a" "$host_dir/libuni-algo.a" -lpthread -lm -Wl,--gc-sections \
    -Wl,--wrap=mrb_obj_alloc
  BC2CPP_HOST_ROM_GRAPH_DUMP="$host_dir/rom_graph.again.c" BC2CPP_HOST_ROM_GRAPH_DUMP_ONLY=1 \
    "$host_dir/trace_host" "$game_dir" 1 > "$host_dir/rom_graph.again.log" 2>&1 \
    || { cat "$host_dir/rom_graph.again.log" >&2; exit 1; }
  grep -q 'on the graph' "$host_dir/rom_graph.again.log" \
    || { echo "error: the host did not take its ROM class graph" >&2; exit 1; }
  if ! cmp -s "$graph" "$host_dir/rom_graph.again.c"; then
    echo "error: the boot on the ROM class graph left a different graph" >&2
    diff "$graph" "$host_dir/rom_graph.again.c" | head -40 >&2
    exit 1
  fi
  echo "ROM class graph: $(head -1 "$graph")"
fi

# The dump exists only in a BC2CPP_TRACE_TYPES=1 build (tools/bc2cpp/param_trace.rb).
# The dump functions are static, so look for the row tag they print instead of a symbol.
traced=no
if grep -a -q 'PARAM_TRACE_SYMBOL' "$mruby_lib"; then traced=yes; fi

rm -f "$dump"
BC2CPP_TRACE_TYPES_OUT="$dump" "$host_dir/trace_host" "$game_dir" "$frames" \
  | tee "$host_dir/run.log"

if [ "$traced" = yes ]; then
  rows=$(grep -c '^PARAM_\|^RETURN_' "$dump" || true)
  echo "trace rows: $rows ($dump)"
  if [ "$rows" -eq 0 ]; then
    echo "error: traced build produced no PARAM_/RETURN_ rows" >&2
    exit 1
  fi
else
  echo "note: $mruby_lib has no PARAM_TRACE_SYMBOL dump; rebuild with BC2CPP_TRACE_TYPES=1 for trace rows" >&2
fi

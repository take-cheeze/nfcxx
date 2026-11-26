#!/usr/bin/env bash
# The sizes and the memory of the programs the lowering suite builds (tests/mrbbc/lower/run.sh): one row per value program,
#   name  ir_bytes  text_bytes  rss_kb  heap_total  heap_peak  gc_total  gc_peak  collections
# ir_bytes is the lowered IR, text_bytes the .text of the program's own object (QBE's output assembled; the runtime is not
# in it), rss_kb the peak resident size (/usr/bin/time), heap_total the bytes the runtime requested from malloc and
# heap_peak the most it held at once (runtime/count_alloc.c; the arena of the 4-byte layout is not malloc's), gc_total and
# gc_peak the collector's bytes of objects (all, and the most at once; MRBBC_GC_STATS) and collections its runs. A last
# row sums the columns, and the runtime's .text is printed after it. LOWER_FLAGS is passed to the lowering and RT_FLAGS to the C compiler of the runtime (to measure a variant);
# MEASURE_ONLY is a pattern of program names (default all).
#
#   tests/mrbbc/lower/measure.sh > sizes.tsv
# Exit 77 (skip) when mrbc, QBE or /usr/bin/time is missing.
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
src=$root/tools/mrbbc
rt=$root/tests/mrbbc/runtime
dir=$root/tests/mrbbc/lower
MRBC=${MRBC:-$root/bc2cpp/tools/mrbc_rb/bin/mrbc_rb}
export MRBC_FALLBACK=${MRBC_FALLBACK:-/nonexistent}
QBE=${QBE:-$root/build/qbe/qbe}
LOWER_FLAGS=${LOWER_FLAGS:-}
RT_FLAGS=${RT_FLAGS:-}
only=${MEASURE_ONLY:-.}
work=${TMPDIR:-/tmp}/mrbbc-measure.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

if [ ! -x "$MRBC" ] || [ ! -x "$QBE" ] || [ ! -x /usr/bin/time ]; then
  echo "mrbbc-measure: skipped (needs mrbc at $MRBC, QBE at $QBE and /usr/bin/time)" >&2
  exit 77
fi

c++ -std=c++17 -O1 -I"$src" -o "$work/lower" "$src/mrb_rite.cpp" "$src/mrb_lower.cpp" "$src/mrbbc_lower_main.cpp" || exit 1
# shellcheck disable=SC2086
cc -std=c99 -O1 $RT_FLAGS -c -o "$work/mrbrt.o" "$rt/mrbrt.c" || exit 1
# shellcheck disable=SC2086
cc -std=c99 -O1 $RT_FLAGS -c -o "$work/driver.o" "$rt/driver.c" || exit 1
cc -std=c99 -O1 -c -o "$work/count.o" "$rt/count_alloc.c" || exit 1
wrap=-Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=free

text_of() { size -A "$1" | awk '$1 == ".text" { print $2 }'; }

printf 'name\tir_bytes\ttext_bytes\trss_kb\theap_total\theap_peak\tgc_total\tgc_peak\tcollections\n'
sum_ir=0 sum_text=0 sum_rss=0 sum_total=0 sum_peak=0 sum_gt=0 sum_gp=0 sum_gc=0
for rb in "$dir"/*.rb; do
  base=$(basename "$rb" .rb)
  echo "$base" | grep -Eq "$only" || continue
  "$MRBC" -o "$work/$base.rite" "$rb" > /dev/null 2>&1 || { echo "$base: mrbc failed" >&2; exit 1; }
  # shellcheck disable=SC2086
  "$work/lower" $LOWER_FLAGS "$work/$base.rite" > "$work/$base.ir" || { echo "$base: lowering failed" >&2; exit 1; }
  "$root/scripts/mrb.rb" "$root/scripts/pathb-qbe-emit.rb" "$work/$base.ir" > "$work/$base.ssa" || exit 1
  "$QBE" "$work/$base.ssa" > "$work/$base.s" || exit 1
  cc -c -o "$work/$base.o" "$work/$base.s" || exit 1
  cc $wrap -o "$work/$base" "$work/$base.o" "$work/mrbrt.o" "$work/driver.o" "$work/count.o" || exit 1
  MRBBC_GC_STATS=1 /usr/bin/time -f 'rss %M' -o "$work/$base.time" "$work/$base" > /dev/null 2> "$work/$base.err" \
    || { echo "$base: the program failed: $(tail -n 1 "$work/$base.err")" >&2; exit 1; }
  ir=$(wc -c < "$work/$base.ir")
  text=$(text_of "$work/$base.o")
  rss=$(awk '$1 == "rss" { print $2 }' "$work/$base.time")
  read -r total peak < <(awk '$1 == "mrbbc-alloc:" { print $3, $7 }' "$work/$base.err")
  read -r gt gp gc < <(awk '$1 == "mrbbc-gc:" { print $3, $5, $7 }' "$work/$base.err")
  gt=${gt:-0} gp=${gp:-0} gc=${gc:-0}
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$ir" "$text" "$rss" "$total" "$peak" "$gt" "$gp" "$gc"
  sum_ir=$((sum_ir + ir)) sum_text=$((sum_text + text)) sum_rss=$((sum_rss + rss))
  sum_total=$((sum_total + total)) sum_peak=$((sum_peak + peak))
  sum_gt=$((sum_gt + gt)) sum_gp=$((sum_gp + gp)) sum_gc=$((sum_gc + gc))
done
printf 'TOTAL\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sum_ir" "$sum_text" "$sum_rss" "$sum_total" "$sum_peak" "$sum_gt" "$sum_gp" "$sum_gc"
printf 'runtime_text\t%s\n' "$(text_of "$work/mrbrt.o")"

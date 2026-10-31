#!/usr/bin/env bash
# HOST_SWEEP: runs a closed bc2cpp build's headless host (trace_host.bash) over a copy of Nepheshel: the
# scripted scenarios (New Game, a battle, the menu, saving and loading), then every map for 150 frames with
# taps. Fails when any run exits non-zero or prints a proof failure, so a closed build whose registrations,
# stubs or verify stubs break the game fails here rather than on a device.
#
# The host is built once (the first scenario, through trace_host.bash) and every later run calls it directly:
# rebuilding it per map costs about 40 times what the 150-frame run does. Maps run JOBS at a time.
#
# It also holds the closed build's method table to scripts/bc2cpp/method_table_threshold.txt.
#
# Usage: scripts/bc2cpp/host_sweep.bash BUILD_DIR [GAME_DIR] [LOG_DIR]
#   GAME_DIR  default data/Nepheshel206beta/Nepheshel206Rbeta (scripts/download/nepheshel.bash); copied, since
#             saving writes into it.
#   JOBS      maps run at once (default nproc).
#   METHOD_TABLE  'skip' leaves out the method-table size check (a verify build).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build=$(cd "$1" && pwd)
src=${2:-$root/data/Nepheshel206beta/Nepheshel206Rbeta}
logs=${3:-$build/host-sweep}
jobs=${JOBS:-$(nproc)}
rm -rf "$logs"
mkdir -p "$logs"
game=$logs/game
cp -r "$src" "$game"
host=$build/trace-host/trace_host
# What a run must never print: a left-out entry reached (verify build), a violated proof or hint, a stubbed
# body run, or a method lookup that failed.
bad_re='UNREGISTERED_VERIFY|hint violation|proof violated|NoMethodError|ScriptError|guard violation'
failed=0

taps() { local out="" f; for ((f = $1; f <= $2; f += $3)); do out+="$f:C,"; done; echo "${out%,}"; }

run() { # name, then env assignments
  local name=$1 a frames=600
  shift
  for a in "$@"; do case $a in BC2CPP_HOST_FRAMES=*) frames=${a#*=} ;; esac; done
  local survey=()
  if [ "${LOOKUP_SURVEY:-0}" = 1 ]; then survey=("BC2CPP_HOST_LOOKUP_SURVEY=$logs/$name.lookups.tsv" "BC2CPP_VMCNT_OUT=$logs/$name.vm.tsv"); fi
  if [ -x "$host" ] && [ -n "${built:-}" ]; then
    env "${survey[@]}" "$@" BC2CPP_TRACE_TYPES_OUT=/dev/null "$host" "$game" "$frames" > "$logs/$name.log" 2>&1
  else
    env "${survey[@]}" "$@" "$root/scripts/bc2cpp/trace_host.bash" "$build" "$game" > "$logs/$name.log" 2>&1
  fi
  local rc=$?
  built=1
  local bad
  bad=$(grep -c -E "$bad_re" "$logs/$name.log")
  echo "$name rc=$rc bad=$bad $(grep -o 'scene=[A-Za-z:0-9]*' "$logs/$name.log" | sort -u | tr '\n' ' ')"
  if [ "$rc" -ne 0 ] || [ "$bad" -ne 0 ]; then
    failed=1
    tail -20 "$logs/$name.log"
  fi
}

run newgame BC2CPP_HOST_FRAMES=6000 BC2CPP_HOST_KEYS="$(taps 30 6000 12)"
run battle BC2CPP_HOST_FRAMES=4000 BC2CPP_HOST_BATTLE_TROOP=1 BC2CPP_HOST_BATTLE_PLAY=1
# The menu on map 1: open it (B), then each of the first commands, backing out each time.
run menu BC2CPP_HOST_FRAMES=1400 BC2CPP_HOST_PREVIEW_MAP=1 BC2CPP_HOST_KEYS="60:B,100:C,160:B,200:DOWN,230:C,290:B,330:DOWN,360:C,420:B,460:DOWN,490:C,550:B,590:DOWN,620:C,680:B,720:DOWN,750:C,800:C,860:B,900:B"
# Save on map 89 (saving allowed) through three menu positions, then load with Continue.
for d in 3 4 5; do
  k="60:B"
  f=90
  for ((i = 0; i < d; i++)); do
    k+=",$f:DOWN"
    f=$((f + 20))
  done
  k+=",$f:C,$((f + 60)):C,$((f + 120)):C,$((f + 180)):C"
  run save$d BC2CPP_HOST_FRAMES=900 BC2CPP_HOST_PREVIEW_MAP=89 BC2CPP_HOST_KEYS="$k"
done
if ! ls "$game" | grep -qi '^save'; then
  echo "no save written"
  failed=1
fi
run load BC2CPP_HOST_FRAMES=900 BC2CPP_HOST_CONTINUE=1 BC2CPP_HOST_KEYS="$(taps 30 900 15)"

# METHOD_TABLE_THRESHOLD: the closed build's method table may not grow past the recorded size. The lists behind it
# are computed from the sources now, so this is what shows a table that grew (a name the proof could no longer
# drop) instead of a diff in a committed list. Raising it is a deliberate edit of method_table_threshold.txt; a
# smaller table asks for the file to be lowered so the gain stays recorded. METHOD_TABLE=skip leaves it out: a
# verify build (BC2CPP_UNREGISTERED_VERIFY) registers a stub under every name the lists drop, so its table is larger.
if ! BC2CPP_HOST_OMITTED_DEPS=1 "$host" "$game" 1 > "$logs/omitted-dependencies.log" 2>&1; then
  cat "$logs/omitted-dependencies.log"
  failed=1
fi
if [ "${METHOD_TABLE:-check}" = check ]; then
  threshold_file="$root/scripts/bc2cpp/method_table_threshold.txt"
  threshold=$(grep -E '^[0-9]+$' "$threshold_file" | head -1)
  entries=$(BC2CPP_HOST_MT_COUNT=1 "$host" "$game" 1 2> /dev/null | sed -n 's/^TRACE_HOST method_table_entries=//p')
  if [ -z "$threshold" ] || [ -z "$entries" ]; then
    echo "method table: could not read the size ($entries) or the threshold ($threshold)"
    failed=1
  elif [ "$entries" -gt "$threshold" ]; then
    echo "method table: $entries entries, over the recorded $threshold (scripts/bc2cpp/method_table_threshold.txt)"
    failed=1
  elif [ "$entries" -lt "$threshold" ]; then
    echo "method table: $entries entries, under the recorded $threshold; lower scripts/bc2cpp/method_table_threshold.txt to $entries"
  else
    echo "method table: $entries entries (at the recorded threshold)"
  fi
fi

map() {
  local id=$1 log=$logs/map-$1.log
  local survey=()
  if [ "${LOOKUP_SURVEY:-0}" = 1 ]; then survey=("BC2CPP_HOST_LOOKUP_SURVEY=$logs/map-$id.lookups.tsv" "BC2CPP_VMCNT_OUT=$logs/map-$id.vm.tsv"); fi
  env "${survey[@]}" BC2CPP_HOST_FRAMES=150 BC2CPP_HOST_PREVIEW_MAP="$id" BC2CPP_HOST_KEYS="$MAP_TAPS" \
    BC2CPP_TRACE_TYPES_OUT=/dev/null "$host" "$game" 150 > "$log" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ] || grep -q -E "$bad_re" "$log"; then
    echo "$id rc=$rc"
  else
    rm -f "$log"
  fi
}
export -f map
export host game logs bad_re LOOKUP_SURVEY
MAP_TAPS=$(taps 20 150 12)
export MAP_TAPS
total=$(ls "$game"/Map*.lmu | wc -l)
bad_maps=$(for lmu in "$game"/Map*.lmu; do
  echo $((10#$(basename "$lmu" .lmu | sed 's/Map//')))
done | xargs -P "$jobs" -I{} bash -c 'map {}')
if [ -n "$bad_maps" ]; then
  failed=1
  echo "maps failed: $(echo "$bad_maps" | tr '\n' ' ')"
  for id in $(echo "$bad_maps" | awk '{print $1}' | head -3); do tail -20 "$logs/map-$id.log"; done
fi
echo "maps: $((total - $(echo -n "$bad_maps" | grep -c '^'))) of $total ok"
exit "$failed"

#!/usr/bin/env bash
# COLD_PROFILE (tools/bc2cpp/cold_compact.rb): regenerates the world's cold method list from a host sweep.
# Builds the closed library with every compiled method counting its calls (BC2CPP_COLD_PROFILE=1, compaction off so
# the profiled code is the inline code), runs host_sweep.bash over it, and writes sig/bc2cpp/cold_methods.txt.
#
# Usage: scripts/bc2cpp/cold_profile.bash [BUILD_DIR] [GAME_DIR]
#   BUILD_DIR  default ./build-closed-cold-profile; rebuilt from scratch.
#   GAME_DIR   default data/Nepheshel206beta/Nepheshel206Rbeta.
#   COLD_MAX_CALLS  a method called at most this many times over the sweep is cold (default 0).
# Needs what closed_build.bash and host_sweep.bash need (MRBC for the host mrbc).
set -euo pipefail

tree="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
root="${BC2CPP_WORLD_ROOT:-$tree}"
build="${1:-$root/build-closed-cold-profile}"
game="${2:-$root/data/Nepheshel206beta/Nepheshel206Rbeta}"

BC2CPP_COLD_PROFILE=1 BC2CPP_COLD_COMPACT=0 "$tree/scripts/bc2cpp/closed_build.bash" "$build"
build="$(cd "$build" && pwd)"
# A fresh directory per run: the counts of an earlier sweep must not add to these.
counts="$(mktemp -d "$build/cold-counts.XXXXXX")"
BC2CPP_COLD_PROFILE_DIR="$counts" "$tree/scripts/bc2cpp/host_sweep.bash" "$build" "$game"
ruby "$tree/scripts/bc2cpp/cold_profile.rb" "$build" "$counts" "$root/sig/bc2cpp/cold_methods.txt" "${COLD_MAX_CALLS:-0}"

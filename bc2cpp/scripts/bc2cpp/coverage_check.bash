#!/usr/bin/env bash

set -euo pipefail

# Publish tools/bc2cpp/bc2cpp.rb's current whole-program diagnostic in the
# CI job summary. The generated report is intentionally not tracked in git:
# every bc2cpp change alters aggregate dispatch counts and would make parallel
# bc2cpp pull requests conflict on the same generated file.
#
# This regenerates the report against the real, already-built host mrbc and
# appends it to GITHUB_STEP_SUMMARY. It also prints to stdout when run outside
# GitHub Actions, so the report remains available to local callers.
#
# Needs a host mrbc already built -- the same prerequisite
# scripts/bc2cpp/coverage_report.rb's own header documents. Deliberately does
# NOT build one itself: the host mruby build's own gem set (mruby-rgss in
# particular) reaches real vendored headers (e.g. 3rd/stb's
# stb_image_write.h) only cmake/build-mruby.cmake's include paths resolve --
# hand-rolling a second, parallel `rake` invocation here would mean either
# duplicating that include-path setup (a maintenance/drift risk this repo's
# own tooling comments elsewhere explicitly avoid, e.g. compiled_gems.rb's
# "single source of truth" framing) or silently only exercising a narrower
# gem set than the real build's own host mrbc. The `build` job's own `cmake
# --build build` step already produces a real one as a side effect (every
# mruby build, cross or native, bootstraps a host mrbc first -- see root
# CMakeLists.txt's own "the native host build only produces mrbc" comment),
# so this runs right after it and points at that.
#
# Usage: scripts/bc2cpp/coverage_check.bash path/to/mruby/build/dir
#
# Takes the mruby build tree's own root (CMake's MRUBY_BUILD_DIR, e.g.
# build/mruby), not an exact mrbc path: mruby's own build system does not
# always place it at "$build_dir/host/bin/mrbc" -- a host build whose own
# compile flags a plain bootstrap compiler can't share (this project's own
# C++-exceptions-enabled host build included) gets its mrbc from a nested
# sub-build instead (confirmed for real against a CI run: "Config Name:
# host/mrbc", "Output Directory: ../../build/mruby/host/mrbc", i.e.
# "$build_dir/host/mrbc/bin/mrbc", not "$build_dir/host/bin/mrbc" -- that
# nesting is mruby/lib/mruby/build.rb's own `mrbcfile`/`build_mrbc_exec`
# internal bootstrap logic, not anything this project's build_config.rb
# controls, so hardcoding either exact path is a real drift risk this
# search sidesteps entirely).

cd "$(dirname "$0")/../.."

build_dir="${1:-}"
if [ -z "$build_dir" ] || [ ! -d "$build_dir" ]; then
  echo "usage: $0 path/to/mruby/build/dir" >&2
  exit 1
fi

mrbc="$(find "$build_dir" -maxdepth 6 -type f -name mrbc -path '*/bin/mrbc' -perm -u+x -print -quit)"
if [ -z "$mrbc" ]; then
  echo "error: no executable bin/mrbc found under $build_dir" >&2
  exit 1
fi

summary_file="${GITHUB_STEP_SUMMARY:-}"
if [ -n "$summary_file" ]; then
  {
    echo '## bc2cpp coverage report'
    echo
    echo 'Generated from the current whole-program bc2cpp diagnostic.'
    echo
    echo '```text'
  } >> "$summary_file"
  MRBC="$mrbc" ruby scripts/bc2cpp/coverage_report.rb | tee -a "$summary_file"
  echo '```' >> "$summary_file"
else
  MRBC="$mrbc" ruby scripts/bc2cpp/coverage_report.rb
fi

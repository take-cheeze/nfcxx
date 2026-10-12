#!/usr/bin/env bash

set -euo pipefail

# Publish the optcarrot standalone bc2cpp coverage report in CI's job summary.
# The generated report is intentionally not tracked: bc2cpp changes update
# aggregate counts and otherwise make concurrent compiler PRs conflict.
#
# Usage: scripts/optcarrot/bc2cpp_coverage_check.bash path/to/mruby/build/dir

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
    echo '## optcarrot bc2cpp coverage report'
    echo
    echo "Generated from optcarrot's real source as its own closed world."
    echo
    echo '```text'
  } >> "$summary_file"
  MRBC="$mrbc" ruby tools/optcarrot_probe/optcarrot_bc2cpp_coverage_report.rb | tee -a "$summary_file"
  echo '```' >> "$summary_file"
else
  MRBC="$mrbc" ruby tools/optcarrot_probe/optcarrot_bc2cpp_coverage_report.rb
fi

#!/usr/bin/env bash
# STATIC_DISPATCH_LISTS: compute the lists of method-table entries the closed-list proof leaves out
# (tools/bc2cpp/static_dispatch_registrations.rb --emit; docs/bc2cpp-unregistered-methods.md) for this tree, and print
# the path of the file. A file already there for the same sources is reused, so an unchanged tree costs a digest.
#
# Usage:
#   export BC2CPP_STATIC_DISPATCH_LISTS="$(scripts/bc2cpp/static_dispatch_lists.bash [BUILD_DIR])"
#
#   BUILD_DIR  where the lists go (BUILD_DIR/bc2cpp/static_dispatch_lists.json) and where a host mrbc is built when
#              MRBC is not set (default ./build-closed-bc2cpp, closed_build.bash's).
#   MRBC       a host mrbc of this tree's mruby pin; without it one is built into BUILD_DIR/host.
#
# Needs what closed_build.bash needs (ruby with prism, rake, a C compiler, bison, gperf); everything but the proof
# itself goes to stderr, so the command substitution above holds only the path.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_dir="${1:-$root/build-closed-bc2cpp}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"

if [ -z "${MRBC:-}" ]; then
  MRBC="$build_dir/host/mrbc/bin/mrbc"
  if [ ! -x "$MRBC" ]; then
    # Only mrbc is wanted. The build configuration reads these lists at load, and there are none yet: 'none' leaves
    # nothing out, which no mrbc build depends on.
    # shellcheck source=scripts/mruby/standalone_prep.bash
    . "$root/scripts/mruby/standalone_prep.bash" >&2
    unset MRUBY_FORCE_NO_CXX_EXCEPTION
    (
      cd "$root/3rd/mruby" && BC2CPP_STATIC_DISPATCH_LISTS=none MRUBY_CONFIG="$root/build_config.rb" \
        MRUBY_BUILD_DIR="$build_dir" PROJECT_BUILD_DIR="$build_dir" MRUBY_TARGET=closed RPGMAKER_BC2CPP=1 \
        rake "$MRBC" >&2
    )
  fi
fi

MRBC="$MRBC" ruby "$root/tools/bc2cpp/static_dispatch_registrations.rb" --emit "$build_dir/bc2cpp" >&2
echo "$build_dir/bc2cpp/static_dispatch_lists.json"

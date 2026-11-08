#!/usr/bin/env bash
# FRAMES_ONLY (docs/bc2cpp-vm-free-runtime-plan.md, Phase 5): derives a closed build in which mruby's vm.c is replaced
# by tools/bc2cpp/runtime/vm_frames.cxx, the call-frame machinery with no path into bytecode. The source build is not
# touched; the derived directory has the same layout, so host_sweep.bash and trace_host.bash take it as is.
#
# Usage: scripts/bc2cpp/frames_only_archive.bash SRC_BUILD_DIR DST_BUILD_DIR
#   Run it with the environment closed_build.bash ran in (the compile flags are read back from the build).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$(cd "${1:?usage: frames_only_archive.bash SRC_BUILD_DIR DST_BUILD_DIR}" && pwd)"
dst="${2:?usage: frames_only_archive.bash SRC_BUILD_DIR DST_BUILD_DIR}"
mkdir -p "$dst/closed/lib" "$dst/closed/src"
dst="$(cd "$dst" && pwd)"
[ -f "$src/closed/lib/libmruby.a" ] || { echo "error: $src/closed/lib/libmruby.a missing" >&2; exit 1; }

# The compile line of vm-cxx.o is the closed target's C++ flags; ask the build for it rather than copying them.
# shellcheck source=scripts/mruby/standalone_prep.bash
. "$root/scripts/mruby/standalone_prep.bash"
# As closed_build.bash: C++ exceptions on, and no -D_FORTIFY_SOURCE at -O0-style flags from Nix's wrapper.
unset MRUBY_FORCE_NO_CXX_EXCEPTION
no_fortify=()
for flag in ${NIX_HARDENING_ENABLE:-}; do
  case "$flag" in fortify | fortify3) ;; *) no_fortify+=("$flag") ;; esac
done
if [ -n "${NIX_HARDENING_ENABLE+set}" ]; then export NIX_HARDENING_ENABLE="${no_fortify[*]}"; fi
touch "$src/closed/src/vm-cxx.cxx"
out=$(cd "$root/3rd/mruby" && MRUBY_CONFIG="$root/build_config.rb" MRUBY_BUILD_DIR="$src" PROJECT_BUILD_DIR="$src" \
  MRUBY_TARGET=closed RPGMAKER_BC2CPP=1 BC2CPP_STATIC_DISPATCH_LISTS="${BC2CPP_STATIC_DISPATCH_LISTS:-none}" \
  rake -v "$src/closed/src/vm-cxx.o" 2>&1)
line=$(grep -E -m1 -- ' -MMD -c .* -o "[^"]*vm-cxx\.o"' <<<"$out") || { echo "error: no compile line for vm-cxx.o" >&2; exit 1; }
cxx=${line%% -MMD -c *}
flags=${line#* -MMD -c }
flags=${flags% -o *}
eval "$cxx -c $flags -o \"\$dst/closed/src/vm_frames.o\" \"\$root/tools/bc2cpp/runtime/vm_frames.cxx\""

cp "$src/closed/lib/libmruby.a" "$dst/closed/lib/libmruby.a"
ar d "$dst/closed/lib/libmruby.a" vm-cxx.o
ar r "$dst/closed/lib/libmruby.a" "$dst/closed/src/vm_frames.o"
ln -sfn "$src/closed/include" "$dst/closed/include"
echo "wrote $dst/closed/lib/libmruby.a (vm-cxx.o replaced by vm_frames.o)"

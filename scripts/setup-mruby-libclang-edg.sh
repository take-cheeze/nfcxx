#!/usr/bin/env bash
# mruby with the mruby-libclang-edg gem (lib/libclang-edg/mruby): build/libclang-edg/mruby/bin/mruby, an interpreter
# whose scripts can use LibclangEdg::Index, TranslationUnit and Cursor over build/libclang-edg/libclang-edg.so.
# Uses the mruby checkout of scripts/setup-mruby.sh (build/mruby-tool/src, the same pin) and needs the same host
# tools (ruby, rake, a C compiler, make, ar). Builds scripts/build-libclang-edg.sh's library first if it is missing.
#   FORCE=1   rebuild even if bin/mruby exists
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${LIBCLANG_EDG_OUT:-$root/build/libclang-edg}
work=$out/mruby
src=$root/build/mruby-tool/src
exe=$work/bin/mruby
cc=${CC:-cc}

[ -z "${FORCE:-}" ] && [ -x "$exe" ] && exit 0
[ -e "$out/libclang-edg.so" ] || "$root/scripts/build-libclang-edg.sh"
[ -d "$src/.git" ] || "$root/scripts/setup-mruby.sh"
command -v ruby >/dev/null || { echo "setup-mruby-libclang-edg: ruby is needed to bootstrap mruby's build" >&2; exit 1; }
if command -v rake >/dev/null; then rake=(rake)
elif [ -x "$(ruby -e 'print Gem.bindir')/rake" ]; then rake=("$(ruby -e 'print Gem.bindir')/rake")
else rake=(ruby -rrake -e 'Rake.application.run(ARGV)' --); fi

mkdir -p "$work/bin"
cp "$root/lib/libclang-edg/mruby/build_config.rb" "$work/build_config.rb"
log=$work/build.log
if ! (cd "$src" && MRUBY_CC=$cc NFCXX_ROOT=$root LIBCLANG_EDG_OUT=$out MRUBY_CONFIG=$work/build_config.rb \
        MRUBY_BUILD_DIR=$work/out "${rake[@]}" -j"$(nproc 2>/dev/null || echo 2)" all) >"$log" 2>&1; then
  tail -20 "$log" >&2; echo "setup-mruby-libclang-edg: build failed (full log: $log)" >&2; exit 1
fi
cp "$work/out/host/bin/mruby" "$exe.new" && mv "$exe.new" "$exe"
echo "setup-mruby-libclang-edg: built $exe" >&2

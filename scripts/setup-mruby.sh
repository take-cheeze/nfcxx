#!/usr/bin/env bash
# Build the small standalone `mruby` interpreter that runs nfcxx's own scripts (see scripts/mrb and
# docs/notes/mruby-scripting.md) into build/mruby-tool/bin/mruby. Does nothing if it is already built.
#   MRUBY_CC=<cc>   Build a second interpreter, bin/mruby-nfcc, with this C compiler and linker instead of
#                   the host cc (MRUBY_CC=$PWD/nfcc dogfoods the compiler, as tests/realworld/run_mruby.sh
#                   does; NFCXX_BACKEND picks its back end). The host-cc bin/mruby is always built first:
#                   scripts/qbe-cc runs mruby, so an nfcc build needs one to exist.
#                   Run scripts with it via MRB=build/mruby-tool/bin/mruby-nfcc scripts/mrb ...
#   FORCE=1         rebuild even if bin/mruby exists
# Needs ruby and the rake gem (mruby's `minirake` is only a shim that execs `rake`; see the note).
cd "$(dirname "$0")/.."
root=$PWD; work=$root/build/mruby-tool
pin=831da26b9021de0369d17b71b5667e2941a1a32d   # mruby/mruby tag 4.0.0, same pin as tests/realworld/run_mruby.sh
src=$work/src
if [ -n "${MRUBY_CC:-}" ] && [ "$MRUBY_CC" != cc ]; then
  MRUBY_CC= "$0" || exit 1                       # the host interpreter first (no-op when present)
  cc=$MRUBY_CC; tag=-nfcc
else
  cc=cc; tag=
fi
exe=$work/bin/mruby$tag
[ -z "${FORCE:-}" ] && [ -x "$exe" ] && exit 0
command -v ruby >/dev/null || { echo "setup-mruby: ruby (CRuby) is needed to bootstrap mruby's build" >&2; exit 1; }
if command -v rake >/dev/null; then rake=(rake)
elif [ -x "$(ruby -e 'print Gem.bindir')/rake" ]; then rake=("$(ruby -e 'print Gem.bindir')/rake")
else rake=(ruby -rrake -e 'Rake.application.run(ARGV)' --); fi
"${rake[@]}" --version >/dev/null 2>&1 || { echo "setup-mruby: the rake gem is needed (apt-get install rake)" >&2; exit 1; }
mkdir -p "$work"
# One build at a time (parallel compiles can all find the interpreter missing); re-check once locked.
exec 9>"$work/.lock"; flock 9
[ -z "${FORCE:-}" ] && [ -x "$exe" ] && exit 0
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/mruby/mruby || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "setup-mruby: fetching mruby $pin failed" >&2; exit 1; }
fi
git -C "$src" checkout -q "$pin" || exit 1
# mruby writes a .lock file next to its config, so the config is copied into the work dir.
cp scripts/mruby-tool-config.rb "$work/build_config$tag.rb"
log=$work/build$tag.log
if ! (cd "$src" && MRUBY_CC=$cc MRUBY_CONFIG=$work/build_config$tag.rb MRUBY_BUILD_DIR=$work/out$tag \
        "${rake[@]}" -j"$(nproc)" all) >"$log" 2>&1; then
  tail -20 "$log" >&2; echo "setup-mruby: build failed (full log: $log)" >&2; exit 1
fi
mkdir -p "$work/bin"
cp "$work/out$tag/host/bin/mruby" "$exe.new" && mv "$exe.new" "$exe"
echo "setup-mruby: built $exe (cc=$cc)" >&2

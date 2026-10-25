#!/usr/bin/env bash
# Build the small standalone `mruby` interpreter that runs nfcxx's own scripts (see scripts/mrb and
# docs/notes/mruby-scripting.md) into build/mruby-tool/bin/mruby. Does nothing if it is already built.
# No rake: scripts/mruby-ninja.rb reads mruby's build config and gems and writes a ninja build file, and ninja builds it.
#   MRUBY_CC=<cc>   Build a second interpreter, bin/mruby-nfcc, with this C compiler and linker instead of
#                   the host cc (MRUBY_CC=$PWD/nfcc dogfoods the compiler, as tests/realworld/run_mruby.sh
#                   does; NFCXX_BACKEND picks its back end). The host-cc bin/mruby is always built first:
#                   scripts/qbe-cc runs mruby, so an nfcc build needs one to exist.
#                   Run scripts with it via MRB=build/mruby-tool/bin/mruby-nfcc scripts/mrb ...
#   FORCE=1         rebuild even if bin/mruby exists
# Needs ruby (CRuby, stdlib only), ninja, git, flock, and the host tools of the vendored gems: a C compiler, make,
# ar, gzip and tar (docs/notes/mruby-scripting.md). The 3rd/ gems are submodules: `git submodule update --init`.
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
command -v ruby >/dev/null || { echo "setup-mruby: ruby (CRuby) is needed to generate the build file" >&2; exit 1; }
command -v ninja >/dev/null || { echo "setup-mruby: ninja is needed (apt-get install ninja-build)" >&2; exit 1; }
for f in 3rd/mruby-onig-regexp/mrbgem.rake 3rd/mruby-json/mrbgem.rake; do
  [ -f "$f" ] || { echo "setup-mruby: $f is missing (git submodule update --init 3rd/mruby-onig-regexp 3rd/mruby-json)" >&2; exit 1; }
done
# The gems under 3rd/ build Onigmo with the host's `make`, `ar`, `gzip` and `tar` (mrbgem.rake of mruby-onig-regexp;
# its configure script ships in the tarball, so only `sh` is needed to run it). Fail here, not 10 minutes into the build.
missing=
for t in "$cc" make ar gzip tar; do
  command -v "$t" >/dev/null 2>&1 && continue
  case $t in make) p=make ;; ar) p=binutils ;; gzip|tar) p=$t ;; *) p="build-essential (or gcc)" ;; esac
  missing="$missing${missing:+; }$t (apt-get install $p)"
done
[ -z "$missing" ] || { echo "setup-mruby: host tool(s) missing: $missing" >&2; exit 1; }
mkdir -p "$work"
# One build at a time (parallel compiles can all find the interpreter missing); re-check once locked.
exec 9>"$work/.lock"; command -v flock >/dev/null && flock 9 || true
[ -z "${FORCE:-}" ] && [ -x "$exe" ] && exit 0
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/mruby/mruby || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "setup-mruby: fetching mruby $pin failed" >&2; exit 1; }
fi
git -C "$src" checkout -q "$pin" || exit 1
# First step: the ninja build file for mruby, from the config and the gems' own mrbgem.rake files. Then ninja builds it.
out=$work/out$tag
log=$work/build$tag.log
if ! (MRUBY_CC=$cc NFCXX_ROOT=$root ruby scripts/mruby-ninja.rb generate "$src" scripts/mruby-tool-config.rb "$out" &&
      ninja -C "$out" "$out/host/bin/mruby") >"$log" 2>&1; then
  tail -20 "$log" >&2; echo "setup-mruby: build failed (full log: $log)" >&2; exit 1
fi
mkdir -p "$work/bin"
cp "$out/host/bin/mruby" "$exe.new" && mv "$exe.new" "$exe"
echo "setup-mruby: built $exe (cc=$cc, ninja)" >&2

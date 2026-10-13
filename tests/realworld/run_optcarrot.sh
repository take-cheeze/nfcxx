#!/usr/bin/env bash
# Real-world benchmark: optcarrot (mame/optcarrot, a pure-Ruby NES emulator used as a Ruby implementation benchmark),
# unmodified upstream source, run headless by an mruby built with nfcc. Migrated from rpg-maker-clone's
# tools/optcarrot_probe (its interpreted-mruby configuration; the bc2cpp compiled configurations stay there).
# The check is the video checksum of the 180-frame run on examples/Lan_Master.nes: 59662, equal to CRuby's.
# Sources are cloned into build/realworld at the pins below, not vendored; mruby is the pin of run_mruby.sh.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
#   OPTCARROT_FRAMES=N      frames to run (default 180; the checksum is checked only for 180)
#   OPTCARROT_CONTROL=1     also build mruby with plain host gcc first, as a control
# Needs ruby, rake, make and a shell for Onigmo's ./configure. Prints the frames per second of each run.
# mruby needs two things for optcarrot: mruby-onig-regexp (Regexp) and tests/realworld/optcarrot/mruby-module-function-scope.patch
# (bare `module_function`, which mruby 4.0.0 still treats as a no-op).
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld; here=$root/tests/realworld/optcarrot
mruby_pin=831da26b9021de0369d17b71b5667e2941a1a32d    # mruby/mruby tag 4.0.0, as run_mruby.sh
optcarrot_pin=c215378a27b2dce8d8e5d98a3ed75e0354c5a840 # mame/optcarrot, the pin of rpg-maker-clone's 3rd/optcarrot
onig_pin=4962d7eb42de079f6b3faec4b40560eb2941eeec      # mattn/mruby-onig-regexp master
want=59662; frames=${OPTCARROT_FRAMES:-180}
command -v ruby >/dev/null || { echo "SKIP optcarrot: ruby not installed"; exit 0; }
if command -v rake >/dev/null; then rake=(rake)
elif [ -x "$(ruby -e 'print Gem.bindir')/rake" ]; then rake=("$(ruby -e 'print Gem.bindir')/rake")
else rake=(ruby -rrake -e 'Rake.application.run(ARGV)' --); fi
"${rake[@]}" --version >/dev/null 2>&1 || { echo "SKIP optcarrot: rake not available"; exit 0; }

# fetch NAME URL PIN: a shallow clone of one commit into $work/NAME.
fetch() {
  local dir=$work/$1
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$dir" && git -C "$dir" init -q && git -C "$dir" remote add origin "$2" || return 1
  fi
  if [ "$(git -C "$dir" rev-parse -q --verify "$3^{commit}" 2>/dev/null)" != "$3" ]; then
    git -C "$dir" fetch -q --depth 1 origin "$3" || { echo "SKIP optcarrot: fetching $2 failed"; return 2; }
  fi
  git -C "$dir" checkout -q -f "$3" || return 1
}
for spec in "mruby https://github.com/mruby/mruby $mruby_pin" \
            "optcarrot https://github.com/mame/optcarrot $optcarrot_pin" \
            "mruby-onig-regexp https://github.com/mattn/mruby-onig-regexp $onig_pin"; do
  fetch $spec; rc=$?
  [ $rc -eq 2 ] && exit 0
  [ $rc -eq 0 ] || { echo "FAIL optcarrot: checkout of $spec failed"; exit 1; }
done
src=$work/mruby
git -C "$src" checkout -q -f "$mruby_pin"
patch -d "$src" -p1 -N -s < "$here/mruby-module-function-scope.patch" || { echo "FAIL optcarrot: the module_function patch does not apply to mruby $mruby_pin"; exit 1; }

backends=${NFCXX_BACKEND:-"gcc qbe"}
[ -z "${OPTCARROT_CONTROL:-}" ] || backends="control $backends"
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ruby "$here/build_bundle.rb" "$work/optcarrot" "$tmp/optcarrot_bundle.rb" || { echo "FAIL optcarrot: bundle"; exit 1; }
cp "$here/mruby_build_config.rb" "$tmp/build_config.rb"
for b in $backends; do
  if [ $b = control ]; then cc=gcc; be=gcc; else cc=$root/nfcc; be=$b; fi
  bdir=$tmp/build-$b
  if ! out=$(cd "$src" && NFCXX_BACKEND=$be MRUBY_CC=$cc MRUBY_CONFIG=$tmp/build_config.rb MRUBY_ONIG_DIR=$work/mruby-onig-regexp \
             MRUBY_BUILD_DIR=$bdir "${rake[@]}" -j"$(nproc)" all 2>&1); then
    msg=$(grep -m1 -E '(^|[ :])error|undefined reference|fatal error|invalid instruction' <<<"$out" || tail -1 <<<"$out")
    echo "FAIL $b optcarrot: mruby build blocked: $msg"; fail=1; continue
  fi
  # optcarrot opens its ROM relative to the working directory.
  got=$(cd "$work/optcarrot" && "$bdir/host/bin/mruby" "$tmp/optcarrot_bundle.rb" examples/Lan_Master.nes "$frames" 2>&1); rc=$?
  sum=$(sed -n 's/^checksum: //p' <<<"$got"); fps=$(sed -n 's/^fps: //p' <<<"$got")
  if [ $rc -ne 0 ] || [ -z "$sum" ]; then
    echo "FAIL $b optcarrot: built, but the run gave rc=$rc output='$(tail -3 <<<"$got")'"; fail=1; continue
  fi
  if [ "$frames" = 180 ] && [ "$sum" != $want ]; then
    echo "FAIL $b optcarrot: checksum $sum, want $want (CRuby's)"; fail=1; continue
  fi
  echo "ok   $b optcarrot: $frames frames, checksum $sum${fps:+, $fps fps}"
done
exit $fail

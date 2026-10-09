#!/usr/bin/env bash
# Real-world check: build mruby (MIT, C99 VM and compiler) with its own rake build, with nfcc as the C compiler
# and linker, and run the resulting `mruby`. The source is cloned into build/realworld/mruby, not vendored.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
#   MRUBY_CONTROL=1         also build with plain host gcc first, as a control (about a minute)
# Reports per backend: "built+ran", or the first blocker (build error / wrong run result).
# Needs ruby and rake (apt-get install ruby). The QBE build needs a cproc built with
# scripts/cproc-vaarg-aggregate.patch (re-run scripts/setup-qbe.sh): mruby passes mrb_value through varargs.
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld
pin=831da26b9021de0369d17b71b5667e2941a1a32d   # mruby/mruby tag 4.0.0, 2026-04-20 (newest non-rc tag)
src=$work/mruby
command -v ruby >/dev/null || { echo "SKIP mruby: ruby not installed"; exit 0; }
if command -v rake >/dev/null; then rake=(rake)
elif [ -x "$(ruby -e 'print Gem.bindir')/rake" ]; then rake=("$(ruby -e 'print Gem.bindir')/rake")
else rake=(ruby -rrake -e 'Rake.application.run(ARGV)' --); fi
"${rake[@]}" --version >/dev/null 2>&1 || { echo "SKIP mruby: rake not available"; exit 0; }
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/mruby/mruby || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "SKIP mruby: fetch failed"; exit 0; }
fi
git -C "$src" checkout -q "$pin" || { echo "FAIL mruby: checkout $pin failed"; exit 1; }

backends=${NFCXX_BACKEND:-"gcc qbe"}
[ -z "${MRUBY_CONTROL:-}" ] || backends="control $backends"
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp "$root/tests/realworld/mruby_build_config.rb" "$tmp/build_config.rb"   # mruby writes a .lock file next to its config
for b in $backends; do
  if [ $b = control ]; then cc=gcc; be=gcc; else cc=$root/nfcc; be=$b; fi
  bdir=$tmp/build-$b
  # The build runs in the clone (rake needs its tree) but writes every output under $bdir.
  if ! out=$(cd "$src" && NFCXX_BACKEND=$be MRUBY_CC=$cc MRUBY_CONFIG=$tmp/build_config.rb \
             MRUBY_BUILD_DIR=$bdir "${rake[@]}" -j"$(nproc)" all 2>&1); then
    msg=$(grep -m1 -E '(^|[ :])error|undefined reference|fatal error|invalid instruction' <<<"$out" || tail -1 <<<"$out")
    [ $b = qbe ] && grep -q 'va_arg with non-scalar' <<<"$out" && msg="$msg (cproc lacks scripts/cproc-vaarg-aggregate.patch; re-run scripts/setup-qbe.sh)"
    echo "FAIL $b mruby: build blocked: $msg"; fail=1; continue
  fi
  exe=$bdir/host/bin/mruby
  got=$("$exe" -e 'puts 1+1' 2>&1); rc=$?
  if [ $rc -ne 0 ] || [ "$got" != 2 ]; then
    echo "FAIL $b mruby: built, but -e 'puts 1+1' gave rc=$rc output='$got'"; fail=1; continue
  fi
  got=$("$exe" "$root/tests/realworld/mruby_test.rb" 2>&1); rc=$?
  if [ $rc -ne 0 ] || [[ $got != 'mruby-ok mruby 3 [1, 3, 5, 8] 6765' ]]; then
    echo "FAIL $b mruby: built, puts ok, test script rc=$rc output='$got'"; fail=1; continue
  fi
  echo "ok   $b mruby: built (rake, default gembox) and ran puts 1+1 and the string/array/hash/block/exception script"
done
exit $fail

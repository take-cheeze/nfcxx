#!/usr/bin/env bash
# Real-world check: build TinyCC 0.9.27 (LGPL-2.1) with its own configure and makefile, the way a user would, with
# nfcxx's nfcc as the C compiler, then run the compiler's own test suite (tests/tests2: 84 programs, each compiled and
# run by the new tcc and compared with its .expect output). The source is cloned into build/realworld/tinycc, not
# vendored; the build runs in a scratch copy so that checkout stays clean.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
# Two build settings are not nfcxx's concern and are set here: the system include and library directories are
# multiarch paths that tcc's defaults do not list, and the memory checker (lib/bcheck.c) is left out because it
# uses __malloc_hook, which glibc 2.34 removed.
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld
pin=d348a9a51d32cece842b7885d27a411436d7887b   # TinyCC tag release_0_9_27
src=$work/tinycc
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/TinyCC/tinycc || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "SKIP tinycc: fetch failed"; exit 0; }
fi
git -C "$src" checkout -q "$pin" || { echo "FAIL tinycc: checkout $pin failed"; exit 1; }

backends=${NFCXX_BACKEND:-"gcc qbe"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
machine=$(gcc -dumpmachine)
for b in $backends; do
  d=$tmp/$b
  cp -a "$src" "$d"
  rm -rf "$d/.git"
  inc=$d/include:/usr/local/include:/usr/include/$machine:/usr/include
  libs=/usr/local/lib:/usr/lib/$machine:/usr/lib:/lib/$machine
  if ! (cd "$d" && ./configure --cc="$root/nfcc" --sysincludepaths="$inc" --libpaths="$libs" \
        --crtprefix=/usr/lib/$machine:/usr/lib) > "$tmp/$b.conf" 2>&1; then
    echo "FAIL $b tinycc: configure"; tail -3 "$tmp/$b.conf"; fail=1; continue
  fi
  if ! out=$(cd "$d" && NFCXX_BACKEND=$b make -j4 CC="$root/nfcc" BCHECK_O= 2>&1); then
    echo "FAIL $b tinycc (build)"; grep -E "error" <<<"$out" | head -5; fail=1; continue
  fi
  if ! out=$(cd "$d" && make -C tests/tests2 2>&1); then
    echo "FAIL $b tinycc: tests2 failed"; grep -E "^(Test:|\+|-)" <<<"$out" | tail -8; fail=1; continue
  fi
  echo "ok   $b tinycc: built with nfcc, tests2 passed ($(grep -c '^Test:' <<<"$out") programs)"
done
exit $fail

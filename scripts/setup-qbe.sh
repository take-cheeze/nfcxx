#!/usr/bin/env bash
# Build the QBE back end (3rd/qbe) and the cproc C front end (3rd/cproc) into
# build/qbe and build/cproc. Both build in a copy of the source so the
# submodules stay clean.
#
# 3rd/qbe is take-cheeze/qbe, a daily mirror of https://c9x.me/git/qbe.git (see that
# repo's sync workflow). 3rd/cproc is take-cheeze/cproc, a fork of michaelforney/cproc: its branch
# nfcxx-asan-combined (the pin, a44a644) is the pinned upstream commit plus nfcxx's cproc patches as commits (empty-struct,
# vaarg-aggregate, empty-copy, array-qual; see docs/notes/freestanding.md and docs/notes/realworld.md for what
# each one fixes). Move the pin in .gitmodules and the fork together when rebasing those patches onto a new upstream.
# scripts/qbe-uninit-slot.patch, scripts/qbe-wflag.patch and scripts/qbe-empty-align.patch are applied to the QBE copy. Re-run this script after changing the pin.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)   # macOS has no nproc
git -C "$root" submodule update --init 3rd/qbe 3rd/cproc

for p in qbe cproc; do
  rm -rf "$root/build/$p"; mkdir -p "$root/build"
  cp -r "$root/3rd/$p" "$root/build/$p"
  rm -rf "$root/build/$p/.git"
done
# QBE: scripts/qbe-uninit-slot.patch (a never-stored struct slot passed by value must not become a null load)
patch -d "$root/build/qbe" -p1 --batch < "$root/scripts/qbe-uninit-slot.patch"
# QBE: scripts/qbe-wflag.patch (amd64 isel: a class-l "and" must not feed the flags of a word-sized jnz/select; docs/notes/qbe-wflag.md)
patch -d "$root/build/qbe" -p1 --batch < "$root/scripts/qbe-wflag.patch"
# QBE: scripts/qbe-empty-struct.patch (an empty struct with no alignment left 1 << -1 in parse.c: a garbage alloc size when it
# is passed by value, e.g. libc++'s std::min comparator)
patch -d "$root/build/qbe" -p1 --batch < "$root/scripts/qbe-empty-struct.patch"
# QBE: scripts/qbe-empty-align.patch (an empty member's alignment is 0, not -1: a nested empty class before a bool fed 1 << -1 padding into the struct size; docs/notes/qbe-empty-align.md)
patch -d "$root/build/qbe" -p1 --batch < "$root/scripts/qbe-empty-align.patch"
# QBE: scripts/qbe-apple-addend.patch (arm64 Apple: an address with an offset is sym+off@page, not sym@page+off, which ld64
# rejects as a relocation)
patch -d "$root/build/qbe" -p1 --batch < "$root/scripts/qbe-apple-addend.patch"
make -C "$root/build/qbe" -j"$jobs" >/dev/null
# cproc: scripts/cproc-unprototyped-fnptr.patch (a function declared with "()" is compatible with a prototype, C 6.7.6.3p15;
# EDG emits struct members like "int (*compare)()" that cproc rejected). docs/notes/realworld.md, "optcarrot".
patch -d "$root/build/cproc" -p1 --batch < "$root/scripts/cproc-unprototyped-fnptr.patch"
# cproc: scripts/cproc-dollar-ident.patch ("$" in identifiers, a GCC and EDG extension; bc2cpp keeps "$" in mangled method names).
patch -d "$root/build/cproc" -p1 --batch < "$root/scripts/cproc-dollar-ident.patch"
# cproc on Apple arm64 names its target "aarch64-apple-darwin" (configure takes host and target from the compiler otherwise,
# and "arm64-apple-darwin" is not one of its targets); the host equals the target, so no SDK is asked for.
if [ "$(uname -s)" = Darwin ]; then
  case "$(uname -m)" in arm64) cproc_triple=aarch64-apple-darwin ;; x86_64) cproc_triple=x86_64-apple-darwin ;; esac
  (cd "$root/build/cproc" && ./configure --host=$cproc_triple --target=$cproc_triple >/dev/null && make -j"$jobs" cproc-qbe >/dev/null)
else
  (cd "$root/build/cproc" && ./configure >/dev/null && make -j"$jobs" cproc-qbe >/dev/null)
fi
# Stage 2 (cproc's own build of cproc, build/cproc/stage2): the stage-1 driver spawns qbe from PATH and links with ld
# directly, so it adds neither libgcc nor libstdc++. cproc's long double and __float128 code calls the helpers of
# libnfcxxld.a (be/nfcxx_ldrt.c), which must be on the link line. The archive has one object, so -u on one of its helpers
# pulls all of them; -lgcc/-lgcc_s give __multf3 and friends, -lstdc++ the __float128 to_chars wrappers.
# be/nfcxx_ldrt.c is x87 code (x86-64 only), so the stage-2 build runs only on x86-64 hosts.
if [ "$(uname -m)" = x86_64 ]; then
  ldrt=$("$root/scripts/pathb-ldrt")
  (cd "$root/build/cproc" && PATH="$root/build/qbe:$PATH" make -j"$jobs" stage2 \
    LDFLAGS="-Wl,-u,__nfcxx_ld_add $ldrt -lgcc -lgcc_s -lstdc++" >/dev/null)
fi
if [ "$(uname -m)" = x86_64 ]; then
  echo "built: $root/build/qbe/qbe $root/build/cproc/cproc-qbe $root/build/cproc/stage2/cproc-qbe"
else
  echo "built: $root/build/qbe/qbe $root/build/cproc/cproc-qbe"
fi

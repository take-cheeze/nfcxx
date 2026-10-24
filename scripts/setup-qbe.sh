#!/usr/bin/env bash
# Build the QBE back end (3rd/qbe) and the cproc C front end (3rd/cproc) into
# build/qbe and build/cproc. Both build in a copy of the source so the
# submodules stay clean.
#
# 3rd/qbe is take-cheeze/qbe, a daily mirror of https://c9x.me/git/qbe.git (see that
# repo's sync workflow). 3rd/cproc is take-cheeze/cproc, a fork of michaelforney/cproc: its branch
# nfcxx-qbe-darwin-atomic (the pin, 8ed4e22) is the pinned upstream commit a44a644 plus nfcxx's cproc patches as commits
# (unprototyped-fnptr, dollar-ident, aligned-attr, darwin-ldouble, apple-valist, apple-driver, apple-predefines,
# atomic-builtins), which this script applied before, the __builtin_strstr, __builtin_char_memchr and libc++ string builtins (strchr, strrchr, strpbrk, strlen, memcmp, memmove), and the aarch64-apple va_arg of aggregates. Earlier nfcxx patches (empty-struct, vaarg-aggregate, empty-copy,
# array-qual) are commits of a44a644 itself; see
# docs/notes/freestanding.md and docs/notes/realworld.md for what each one fixes. Move the pin in the submodule and
# this comment together when rebasing those patches onto a new upstream.
# The pin is a84a858, on the fork's branch nfcxx-linux-kernel: the earlier pin (9f706f5, nfcxx-stmt-expr: GNU statement
# expressions ({ ... }), which ASTro's baruby_precise needs, docs/notes/astro.md) plus three commits: the __extension__
# keyword, GNU extended inline asm lowered to out-of-line thunks (docs/notes/inline-asm.md; qbe-cc passes -a so cproc
# writes the thunks to a side file appended to the assembly), the pre-C23 reading of true/false/nullptr/bool as
# identifiers (cproc -K; qbe-cc passes it unless -std=c23), the aligned attribute on a typedef, and GNU attributes
# between a pointer and the declarator name; then the GNU C of the Linux kernel, implemented as gcc does it or refused
# (cproc -p, -V, -G: docs/notes/cproc-nfcxx.md, docs/notes/linux-kernel.md); and weak/visibility without effect where
# there is no inline-asm side file (Mach-O), outside -p, as before cproc took them.
# The nfcxx QBE fixes are commits of the fork (take-cheeze/qbe, the pin in 3rd/qbe): the pin is 55947e6, on its branch
# nfcxx-linux-kernel: the earlier pin (5c5b125) plus 1024 copies in one parallel move (rega.c NPm), and what the kernel's
# objects need (ELF .type/.size for data, -n without floating-point registers for -mno-sse, -U without unwind tables,
# data alignments up to 65536, symbol offsets beyond 32 bits). No patch files are applied.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)   # macOS has no nproc
# ccache when it is installed: the QBE and cproc objects are rebuilt from the same sources in every fresh checkout.
cc_wrap=cc; command -v ccache >/dev/null && cc_wrap="ccache cc"
git -C "$root" submodule update --init 3rd/qbe 3rd/cproc

for p in qbe cproc; do
  rm -rf "$root/build/$p"; mkdir -p "$root/build"
  cp -r "$root/3rd/$p" "$root/build/$p"
  rm -rf "$root/build/$p/.git"
done
make -C "$root/build/qbe" -j"$jobs" CC="$cc_wrap" >/dev/null
# cproc on Apple arm64 names its target "aarch64-apple-darwin" (configure takes host and target from the compiler otherwise,
# and "arm64-apple-darwin" is not one of its targets); the host equals the target, so no SDK is asked for.
if [ "$(uname -s)" = Darwin ]; then
  case "$(uname -m)" in arm64) cproc_triple=aarch64-apple-darwin ;; x86_64) cproc_triple=x86_64-apple-darwin ;; esac
  (cd "$root/build/cproc" && ./configure --host=$cproc_triple --target=$cproc_triple >/dev/null && make -j"$jobs" CC="$cc_wrap" cproc cproc-qbe >/dev/null)
else
  (cd "$root/build/cproc" && ./configure >/dev/null && make -j"$jobs" CC="$cc_wrap" cproc-qbe >/dev/null)
fi
# Stage 2 (cproc's own build of cproc, build/cproc/stage2): the stage-1 driver spawns qbe from PATH and links with ld
# directly, so it adds neither libgcc nor libstdc++. cproc's long double and __float128 code calls the helpers of
# libnfcxxld.a (be/nfcxx_ldrt.c), which must be on the link line. The archive has one object, so -u on one of its helpers
# pulls all of them; -lgcc/-lgcc_s give __multf3 and friends, -lstdc++ the __float128 to_chars wrappers.
# -lm: the stage-1 driver links with ld directly, and libm is needed by cproc's math (without it ld fails with
# "DSO missing from command line" on hosts with --as-needed).
# be/nfcxx_ldrt.c is x87 code (x86-64 only), so the x86-64 stage-2 build links those helpers; it does not run on arm64.
if [ "$(uname -m)" = x86_64 ]; then
  ldrt=$("$root/scripts/pathb-ldrt")
  (cd "$root/build/cproc" && PATH="$root/build/qbe:$PATH" make -j"$jobs" stage2 \
    LDFLAGS="-Wl,-u,__nfcxx_ld_add $ldrt -lgcc -lgcc_s -lstdc++ -lm" >/dev/null)
fi
# Apple arm64 stage 2 (no helper archive: long double is a double there, scripts/cproc-darwin-ldouble.patch). The SDK's
# ARM register state (mach/arm/_structs.h) has __uint128_t arrays that cproc cannot parse, and the stage-2 driver compiles
# its sources with the SDK headers without qbe-cc's defines. So __uint128_t is unsigned for this build only; cproc's
# sources do not use the 128-bit type, and the IR of cproc-qbe from stage 2 is identical to stage 1's on tests/c inputs.
# The stage-2 make needs CFLAGS and CC passed on its own command line here.
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
  (cd "$root/build/cproc" && mkdir -p stage2 && PATH="$root/build/qbe:$PATH" make -j"$jobs" objdir=stage2 \
    stagedeps='cproc cproc-qbe' CC=./cproc CFLAGS='-D__uint128_t=unsigned' LDFLAGS=' -s' stage2/cproc stage2/cproc-qbe >/dev/null)
fi
if [ -x "$root/build/cproc/stage2/cproc-qbe" ]; then
  echo "built: $root/build/qbe/qbe $root/build/cproc/cproc-qbe $root/build/cproc/stage2/cproc-qbe"
else
  echo "built: $root/build/qbe/qbe $root/build/cproc/cproc-qbe"
fi

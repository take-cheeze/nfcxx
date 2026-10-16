#!/usr/bin/env bash
# cross-macos-check.sh: the macOS arm64 compile checks on a Linux host, with the configuration from
# scripts/setup-cross-macos.sh. The C check runs scripts/qbe-cc -S over tests/c/*.c (clang preprocesses for
# arm64-apple-darwin against the clean-room headers, then QBE emits assembly). The C++ check runs
# scripts/macos-cxx-check.sh over tests/cases/*.cpp. Compile and assembly only by default. With --link, each C file that
# compiles is also assembled and linked into a Mach-O arm64 executable against the clean-room stub (tests/macos-sysroot/lib)
# and nfcxx's runtime (be/nfcxx_ldrt.c); the executable is checked for its Mach-O shape and for imports the stub does not
# export. Nothing is run: the executables are for a Mac. Prints the counts; failures are listed with the first line of
# their error. Exit status is 0 when the script ran.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
envf="$root/build/cross-macos.env"
[ -f "$envf" ] || { echo "cross-macos-check: $envf is missing; run scripts/setup-cross-macos.sh first" >&2; exit 2; }
. "$envf"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cpass=0; ctotal=0
for f in "$root"/tests/c/*.c; do
  ctotal=$((ctotal + 1))
  # NFCXX_C_INPUT=1: these are hand-written C files that include the standard headers. Without it, qbe-cc's -undef strips
  # the target's __SIZE_TYPE__ and friends, and every file that includes stddef.h fails.
  if NFCXX_C_INPUT=1 "$root/scripts/qbe-cc" -S "$f" -o "$tmp/c.s" >/dev/null 2>"$tmp/c.err"; then
    cpass=$((cpass + 1)); basename "$f" .c >> "$tmp/cpass.txt"
  else
    echo "C fail $(basename "$f"): $(grep -m1 -E 'error|assert|Error' "$tmp/c.err" || head -1 "$tmp/c.err")"
  fi
done

xpass=0; xtotal=0
mkdir -p "$tmp/cxx"
for f in "$root"/tests/cases/*.cpp; do
  xtotal=$((xtotal + 1))
  if "$root/scripts/macos-cxx-check.sh" "$f" "$tmp/cxx/$(basename "$f" .cpp).s" >/dev/null 2>"$tmp/x.err"; then
    xpass=$((xpass + 1)); basename "$f" .cpp >> "$tmp/cxxpass.txt"
  else
    echo "C++ fail $(basename "$f"): $(grep -m1 -E 'error|Error|fatal|assert' "$tmp/x.err" || head -1 "$tmp/x.err")"
  fi
done

echo "C (tests/c, qbe-cc -S for arm64 Darwin): $cpass of $ctotal pass"
echo "C++ (tests/cases, macos-cxx-check.sh to Darwin assembly): $xpass of $xtotal pass"

if [ "${1:-}" = "--link" ]; then
  stub="$root/tests/macos-sysroot/lib"
  res=$(clang -print-resource-dir)/include
  # the stub's exported names, from its symbols lists (no code behind them)
  sed -n '/symbols:/,/weak-symbols/p' "$stub/libSystem.tbd" | tr -d '[],' | tr -s ' ' '\n' \
    | grep -E '^_|^dyld_stub_binder$' | LC_ALL=C sort -u > "$tmp/stub-syms.txt"
  clang --target=arm64-apple-darwin -O2 -nostdinc -isystem "$NFCXX_MACOS_CLEANROOM/include" -isystem "$res" \
    -c "$root/be/nfcxx_ldrt.c" -o "$tmp/ldrt.o" 2>"$tmp/ldrt.err" \
    || { echo "link: be/nfcxx_ldrt.c does not compile for arm64 Darwin: $(head -1 "$tmp/ldrt.err")"; exit 1; }
  lpass=0; ltotal=0
  while read -r b; do
    ltotal=$((ltotal + 1))
    NFCXX_C_INPUT=1 "$root/scripts/qbe-cc" -S "$root/tests/c/$b.c" -o "$tmp/$b.s" >/dev/null 2>&1
    if ! llvm-mc -triple=arm64-apple-darwin -filetype=obj "$tmp/$b.s" -o "$tmp/$b.o" 2>"$tmp/l.err"; then
      echo "link fail $b: assembly: $(head -1 "$tmp/l.err")"; continue
    fi
    if ! ld64.lld -arch arm64 -platform_version macos 11.0 11.0 -o "$tmp/$b.exe" "$tmp/$b.o" "$tmp/ldrt.o" \
         -L "$stub" -lSystem 2>"$tmp/l.err"; then
      echo "link fail $b: $(grep -m1 error "$tmp/l.err" || head -1 "$tmp/l.err")"; continue
    fi
    hdr=$(llvm-objdump --macho --private-headers "$tmp/$b.exe" 2>/dev/null)
    if ! { echo "$hdr" | grep -q EXECUTE && echo "$hdr" | grep -q ARM64; }; then
      echo "link fail $b: not a Mach-O arm64 executable"; continue
    fi
    extra=$(llvm-nm -u "$tmp/$b.exe" | awk '{print $NF}' | LC_ALL=C sort -u | LC_ALL=C comm -23 - "$tmp/stub-syms.txt" | tr '\n' ' ')
    if [ -n "$extra" ]; then
      echo "link fail $b: imports not in the stub: $extra"; continue
    fi
    lpass=$((lpass + 1))
  done < "$tmp/cpass.txt"
  echo "link (clean-room stub, Mach-O arm64 executables, not run): $lpass of $ltotal of the C files that compile link"

  # C++: each source that reaches assembly, linked against the libSystem stub and the pinned libc++ stub (names the test
  # objects import, from public libc++ and Itanium names; no behaviour). A new import outside both stubs fails the link.
  cxxstub="$root/tests/macos-sysroot/lib"
  cxxnames=$(sed -n '/symbols:/,/weak-symbols/p' "$cxxstub/libc++.tbd" | tr -d '[],' | tr -s ' ' '\n' | grep -E '^_' || true)
  xlpass=0; xltotal=0
  # NFCXX_LINK_OUT keeps the executables (the temporary directory is removed on exit)
  exeout=${NFCXX_LINK_OUT:-$tmp/cxx}; mkdir -p "$exeout"
  for b in $(cat "$tmp/cxxpass.txt" 2>/dev/null); do
    xltotal=$((xltotal + 1))
    if ! llvm-mc -triple=arm64-apple-darwin -filetype=obj "$tmp/cxx/$b.s" -o "$tmp/cxx/$b.o" 2>"$tmp/l.err"; then
      echo "C++ link fail $b: assembly: $(head -1 "$tmp/l.err")"; continue
    fi
    if ! ld64.lld -arch arm64 -platform_version macos 11.0 11.0 -o "$exeout/$b.exe" "$tmp/cxx/$b.o" "$tmp/ldrt.o" \
         -L "$stub" -lSystem -L "$cxxstub" -lc++ 2>"$tmp/l.err"; then
      echo "C++ link fail $b: $(grep -m1 error "$tmp/l.err" || head -1 "$tmp/l.err")"; continue
    fi
    hdr=$(llvm-objdump --macho --private-headers "$exeout/$b.exe" 2>/dev/null)
    if ! { echo "$hdr" | grep -q EXECUTE && echo "$hdr" | grep -q ARM64; }; then
      echo "C++ link fail $b: not a Mach-O arm64 executable"; continue
    fi
    allowed=$(printf '%s\n' "$(cat "$tmp/stub-syms.txt")" "$cxxnames" | LC_ALL=C sort -u)
    extra=$(llvm-nm -u "$exeout/$b.exe" | awk '{print $NF}' | LC_ALL=C sort -u | LC_ALL=C comm -23 - <(printf '%s\n' "$allowed") | tr '\n' ' ')
    if [ -n "$extra" ]; then
      echo "C++ link fail $b: imports not in the stubs: $extra"; continue
    fi
    xlpass=$((xlpass + 1))
  done
  echo "C++ link (clean-room stubs, Mach-O arm64 executables, not run): $xlpass of $xltotal of the C++ sources that reach assembly link"
fi

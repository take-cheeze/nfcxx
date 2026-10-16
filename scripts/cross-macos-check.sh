#!/usr/bin/env bash
# cross-macos-check.sh: the macOS arm64 compile checks on a Linux host, with the configuration from
# scripts/setup-cross-macos.sh. The C check runs scripts/qbe-cc -S over tests/c/*.c (clang preprocesses for
# arm64-apple-darwin against the clean-room headers, then QBE emits assembly). The C++ check runs
# scripts/macos-cxx-check.sh over tests/cases/*.cpp. Compile and assembly only: nothing is linked or run.
# Prints the counts; failures are listed with the first line of their error. Exit status is 0 when the script ran.
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
    cpass=$((cpass + 1))
  else
    echo "C fail $(basename "$f"): $(grep -m1 -E 'error|assert|Error' "$tmp/c.err" || head -1 "$tmp/c.err")"
  fi
done

xpass=0; xtotal=0
for f in "$root"/tests/cases/*.cpp; do
  xtotal=$((xtotal + 1))
  if "$root/scripts/macos-cxx-check.sh" "$f" "$tmp/x.s" >/dev/null 2>"$tmp/x.err"; then
    xpass=$((xpass + 1))
  else
    echo "C++ fail $(basename "$f"): $(grep -m1 -E 'error|Error|fatal|assert' "$tmp/x.err" || head -1 "$tmp/x.err")"
  fi
done

echo "C (tests/c, qbe-cc -S for arm64 Darwin): $cpass of $ctotal pass"
echo "C++ (tests/cases, macos-cxx-check.sh to Darwin assembly): $xpass of $xtotal pass"

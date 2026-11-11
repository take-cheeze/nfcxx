#!/usr/bin/env bash
# macos-stub-tbd.sh INSTALL-NAME OUT.tbd NAMES.txt: writes a clean-room TBD v4 link stub that exports the names in
# NAMES.txt (one Mach-O name per line, with the leading underscore). The names come from the undefined references of
# nfcxx's own test objects (llvm-nm -u), so the stub's contents follow what the objects import and nothing else. It has
# no code and no behaviour: a program linked against it can be checked for its Mach-O shape and its imports, never run.
set -euo pipefail
install=$1; out=$2; names=$3
syms=$(LC_ALL=C sort -u "$names" | paste -sd, - | sed 's/,/, /g')
{
  echo '--- !tapi-tbd'
  echo '# Clean-room link stub written by scripts/macos-stub-tbd.sh from the undefined references of nfcxx'"'"'s C++ test'
  echo '# objects (llvm-nm -u), minus the libSystem stub. Names only: no code and no behaviour; not Apple'"'"'s library.'
  echo 'tbd-version:     4'
  echo 'targets:         [ arm64-macos ]'
  echo "install-name:    $install"
  echo 'current-version: 1'
  echo 'compatibility-version: 1'
  echo 'exports:'
  echo '  - targets:         [ arm64-macos ]'
  echo "    symbols:         [ $syms ]"
  echo '...'
} > "$out"

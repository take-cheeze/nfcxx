#!/usr/bin/env bash
# Builds and runs the machine probe test (lib/prof/nfcxx_machine.c): the probe fills the struct, the text description
# is produced, and the sanity checks in tests/prof/machine.c pass.
set -eu
cd "$(dirname "$0")/../.."
out=build/prof
mkdir -p "$out"
${CC:-gcc} -std=c11 -O2 -Wall -Wextra -Werror -pthread -Ilib/prof \
  lib/prof/nfcxx_machine.c tests/prof/machine.c -o "$out/machine" -lm
"$out/machine"

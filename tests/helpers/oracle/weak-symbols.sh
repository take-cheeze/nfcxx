#!/usr/bin/env bash
# The .weak directives of EDG's generated C (tools/weak-symbols, the C++ port of the former scripts/weak-symbols.rb):
# scripts/weak-symbols [--c-input] [--sym-prefix=P] [--marked=FILE] PREPROCESSED_C ASSEMBLY appends them to ASSEMBLY.
# Builds build/weak-symbols on first use (scripts/tool-ensure.sh). NFCXX_WEAK_SYMBOLS_RB=SCRIPT runs an mruby script
# with the same arguments instead (tests/mruby: the oracle tests/mruby/oracle/weak-symbols.rb).
root=$(cd "$(dirname "$0")/.." && pwd)
if [ -n "${NFCXX_WEAK_SYMBOLS_RB:-}" ]; then exec "$root/scripts/mrb" "$NFCXX_WEAK_SYMBOLS_RB" "$@"; fi
. "$root/scripts/tool-ensure.sh"
tool_ensure weak-symbols || exit $?
exec "$root/build/weak-symbols" "$@"

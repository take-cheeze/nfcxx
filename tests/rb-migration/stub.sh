#!/bin/bash
# Logging stub for the external commands of the setup scripts (tests/rb-migration/run.sh links it under each command name in
# the sandbox's bin directory; the sandbox's root links it as nfcc, nfcxx and build/edg/bin/eccp).
#   NFCX_STUB_LOG   the log: "ENV NAME=value" lines for the variables the scripts set (NFCXX_, MRUBY_, GIT_, GO, CGO_, CC=, EDG_,
#                   LC_, POLY_), then "RUN name args" with the arguments shell-quoted. nproc is not logged.
#   NFCX_STUBDIR    when it holds a file named like the command, that file runs with the arguments: it gives the output and status
#   otherwise the call prints nothing and exits 0
name=$(basename "$0")
if [ "$name" != nproc ]; then
  env | sort | grep -E '^(NFCXX_|MRUBY_|GIT_|GO|CGO_|CC=|EDG_|LC_|POLY_)' | sed 's/^/ENV /' >> "$NFCX_STUB_LOG"
  { printf 'RUN %s' "$name"; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >> "$NFCX_STUB_LOG"
fi
if [ -f "$NFCX_STUBDIR/$name" ]; then exec bash "$NFCX_STUBDIR/$name" "$@"; fi
exit 0

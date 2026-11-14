#!/bin/bash
# Logging stub for the rb-migration differential tests (tests/rb-migration/fetch-build/common.sh links it under each command
# name). It appends the command line to NFCXX_STUB_LOG, with the sandbox's temporary paths shown as TMP, then the variables
# named in NFCXX_STUB_ENV that are set. python3 is logged only for `-m pip`; any other python3 call runs the real one.
# A case's hook NFCXX_STUB_HOOKS/NAME (if it exists) runs in place of the default below; its status and output are the stub's.
name=$(basename "$0")
log() { printf '%s\n' "$*" | sed "s#$NFCXX_STUB_TMP/[^ /]*#TMP#g" >> "$NFCXX_STUB_LOG"; }
if [ "$name" = python3 ] && { [ "$1" != -m ] || [ "$2" != pip ]; }; then exec "$NFCXX_STUB_REAL_PY" "$@"; fi
log "$name $*"
for v in $NFCXX_STUB_ENV; do if [ -n "${!v+x}" ]; then log "ENV $v=${!v}"; fi; done
h=$NFCXX_STUB_HOOKS/$name
if [ -f "$h" ]; then exec "$h" "$@"; fi
if [ "$name" = curl ]; then
  out= url=
  while [ $# -gt 0 ]; do
    case $1 in -o) out=$2; shift ;; http*) url=$1 ;; esac
    shift
  done
  key=$(printf '%s' "$url" | sed 's#[^A-Za-z0-9._-]#_#g')
  f=$NFCXX_STUB_FIX/urls/$key
  if [ -f "$f" ]; then
    if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi
    exit 0
  fi
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
exit 0

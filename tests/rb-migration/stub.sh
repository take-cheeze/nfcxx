#!/bin/bash
# Logging stub for tests/rb-migration/run.sh, linked (or placed) under the name of each command a script runs.
#   every call: "RUN NAME ARGS" and the ENV lines of the variables the scripts pass on (NFCXX_*, EDG_*, RUBY, CXX,
#   LD_LIBRARY_PATH, OPENCL_INCLUDE, JOBS), sorted, to $NFCXX_STUB_LOG
#   output: STUB_OUT_NAME (printf %b) on stdout, the exit status STUB_RC_NAME (default 0); STUB_LOGTEXT_NAME is appended
#   to $NFCXX_PATHB_LOG; STUB_TOUCH_NAME=1 creates the file named after -o. NAME is the basename, upper-cased, with . and - as _.
# Built in: clang -print-resource-dir prints /RES; file -b tells ELF from Mach-O by the magic; mktemp -d makes a
# directory under $NFCXX_STUB_TMP; cp is logged and then run for real.
name=$(basename "$0")
key=$(printf '%s' "$name" | tr 'a-z.-' 'A-Z__')
log() { printf '%s\n' "$*" >> "$NFCXX_STUB_LOG"; }
env | grep -E '^(NFCXX_|EDG_|RUBY=|CXX=|LD_LIBRARY_PATH=|OPENCL_INCLUDE=|JOBS=)' | grep -v '^NFCXX_STUB_' | sort \
  | while IFS= read -r l; do log "ENV $l"; done
log "RUN $name $*"
v="STUB_OUT_$key"; out=${!v-}
v="STUB_RC_$key"; rc=${!v-0}
v="STUB_LOGTEXT_$key"; logtext=${!v-}
v="STUB_TOUCH_$key"; touchit=${!v-}
[ -z "$logtext" ] || [ -z "${NFCXX_PATHB_LOG-}" ] || printf '%b\n' "$logtext" >> "$NFCXX_PATHB_LOG"
case $name in
  clang)
    if [ "${1-}" = -print-resource-dir ]; then echo /RES; fi
    exit 0 ;;
  file)
    f=${!#}
    if [ "$(head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; then echo "ELF 64-bit LSB executable"
    else echo "Mach-O 64-bit arm64"; fi
    exit 0 ;;
  mktemp)
    d=$NFCXX_STUB_TMP/d$RANDOM$RANDOM
    mkdir -p "$d" && echo "$d"
    exit 0 ;;
  cp)
    /bin/cp "$@" 2>/dev/null
    exit $? ;;
esac
[ -z "$out" ] || printf '%b' "$out"
if [ -n "$touchit" ]; then
  prev=""
  for a in "$@"; do [ "$prev" = -o ] && : > "$a"; prev=$a; done
fi
exit "$rc"

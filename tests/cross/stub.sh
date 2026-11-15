#!/bin/bash
# Logging stub for tests/cross/run.sh, linked (or placed) under the name of each command a cross tool runs.
# Every call appends "RUN NAME ARGS" to $NFCXX_STUB_LOG, then:
#   clang -print-resource-dir prints /RES; clang and clang++ otherwise do nothing;
#   cpfe writes a stand-in C file to its --gen_c_file_name= (not when STUB_NOOUT is set) and exits with STUB_RC_CPFE when
#   that is set (its stderr says so);
#   gcc and ar run the real tools ($REALGCC, $REALAR); uname -m prints FAKE_UNAME_M when it is set, else the real uname.
name=${0##*/}
printf 'RUN %s %s\n' "$name" "$*" >> "$NFCXX_STUB_LOG"
case $name in
  clang)
    if [ "${1-}" = -print-resource-dir ]; then echo /RES; fi
    exit 0 ;;
  clang++)
    exit 0 ;;
  cpfe)
    out=
    for a in "$@"; do
      case $a in --gen_c_file_name=*) out=${a#--gen_c_file_name=} ;; esac
    done
    if [ -n "$out" ] && [ -z "${STUB_NOOUT-}" ]; then printf '/* stand-in cpfe output */\nint stand_in;\n' > "$out"; fi
    if [ -n "${STUB_RC_CPFE-}" ]; then echo "cpfe: stand-in failure" >&2; exit "$STUB_RC_CPFE"; fi
    exit 0 ;;
  gcc) exec "$REALGCC" "$@" ;;
  ar) exec "$REALAR" "$@" ;;
  uname)
    if [ -n "${FAKE_UNAME_M-}" ] && [ "${1-}" = -m ]; then echo "$FAKE_UNAME_M"; exit 0; fi
    exec "$REALUNAME" "$@" ;;
  *)
    echo "stub: no stub for $name" >&2; exit 99 ;;
esac

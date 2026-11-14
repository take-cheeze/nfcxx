#!/bin/bash
# Logging stub for the external commands of the compile-path scripts (tests/rb-compile-path/run.sh links it under each command
# name in the sandbox's bin directory and at the sandbox's scripts/mrb, scripts/pathb-cil and nfcxx). Every call is logged
# as "NAME ARGS" to NFCXX_STUB_LOG and nothing real runs, except awk, grep, head, tr, sed, cat, which are the real tools.
#   cc, gcc, g++   --version / -dumpfullversion answer from NFCXX_STUB_CXX_CLANG (clang) and NFCXX_STUB_NOVER (no version);
#                  -print-file-name prints NFCXX_STUB_LIBSTDCXX; -c -o OUT SRC copies SRC to OUT (exit NFCXX_STUB_CC_RC)
#   ar, llvm-ar    the archive (the first argument after rcs) is written with the member names
#   llvm-mc        the -o file is written from its input
#   mktemp         -d or a file: a fresh entry under NFCXX_STUB_TMP, printed (a counter, so both runs name the same entries)
#   uname          -s / -m answer NFCXX_STUB_UNAME_S / NFCXX_STUB_UNAME_M (default Linux, x86_64)
#   nm             prints the file NFCXX_STUB_NM
#   realpath       prints its argument
#   xcrun          prints NFCXX_STUB_SDK
#   pathb-cil      -c ... -o OUT SRC: writes OUT (exit NFCXX_STUB_PATHB_RC, default 0; else prints NFCXX_STUB_PATHB_ERR on stderr)
#   mrb            logs the call (ENV NFCXX_CIL too) and exits 0
#   nfcxx          --backend=gcc -c SRC -o OUT: writes OUT (exit NFCXX_STUB_RC, default 0; prints NFCXX_STUB_NFCXX_OUT)
name=$(basename "$0")
log() { printf '%s\n' "$*" >> "$NFCXX_STUB_LOG"; }
count() { local n=0; [ -f "$NFCXX_STUB_TMP/.n" ] && n=$(cat "$NFCXX_STUB_TMP/.n"); n=$((n + 1)); echo "$n" > "$NFCXX_STUB_TMP/.n"; echo "$n"; }
last_arg() { local a=""; for a in "$@"; do :; done; printf '%s' "$a"; }
out_of() { local prev="" a; for a in "$@"; do [ "$prev" = -o ] && { printf '%s' "$a"; return; }; prev=$a; done; }
log "$name $*"
case $name in
  cc|gcc|g++)
    case " $* " in
      *" --version "*)
        if [ "${NFCXX_STUB_CXX_CLANG:-0}" = 1 ]; then echo "clang version 21.0.0"; else echo "$name (GCC) 13.3.0"; fi
        exit 0 ;;
      *" -dumpfullversion "*)
        if [ "${NFCXX_STUB_NOVER:-0}" = 1 ]; then exit 1; fi
        echo 13.3.0; exit 0 ;;
    esac
    case $* in
      -print-file-name=*) printf '%s\n' "${NFCXX_STUB_LIBSTDCXX:-}"; exit 0 ;;
    esac
    rc=${NFCXX_STUB_CC_RC:-0}
    has_c=0; for a in "$@"; do [ "$a" = -c ] && has_c=1; done
    if [ "$rc" = 0 ] && [ $has_c = 1 ]; then
      o=$(out_of "$@"); src=$(last_arg "$@")
      [ -z "$o" ] || cp "$src" "$o"
    fi
    exit "$rc" ;;
  ar|llvm-ar)
    if [ "$1" = rcs ] && [ -n "${2:-}" ]; then
      { echo "AR"; for a in "${@:3}"; do echo "member $a"; done; } > "$2"
    fi
    exit 0 ;;
  llvm-mc)
    o=$(out_of "$@"); src=$(last_arg "$@")
    [ -z "$o" ] || cp "$src" "$o"
    exit 0 ;;
  mktemp)
    n=$(count)
    if [ "$1" = -d ]; then d="$NFCXX_STUB_TMP/t$n"; mkdir -p "$d"; echo "$d"
    else f="$NFCXX_STUB_TMP/t$n"; : > "$f"; echo "$f"; fi
    exit 0 ;;
  uname)
    case $1 in
      -s) echo "${NFCXX_STUB_UNAME_S:-Linux}" ;;
      -m) echo "${NFCXX_STUB_UNAME_M:-x86_64}" ;;
    esac
    exit 0 ;;
  nm) [ -z "${NFCXX_STUB_NM:-}" ] || cat "$NFCXX_STUB_NM"; exit 0 ;;
  realpath) last_arg "$@"; echo; exit 0 ;;
  xcrun) echo "${NFCXX_STUB_SDK:-}"; exit 0 ;;
  pathb-cil)
    rc=${NFCXX_STUB_PATHB_RC:-0}
    if [ "$rc" = 0 ]; then o=$(out_of "$@"); [ -z "$o" ] || echo '{' > "$o"; exit 0; fi
    printf '%b\n' "${NFCXX_STUB_PATHB_ERR:-}" >&2; exit "$rc" ;;
  mrb)
    log "ENV NFCXX_CIL=${NFCXX_CIL:-unset}"; exit 0 ;;
  nfcxx)
    rc=${NFCXX_STUB_RC:-0}
    if [ "$rc" = 0 ]; then o=$(out_of "$@"); [ -z "$o" ] || echo shim > "$o"; exit 0; fi
    printf '%s\n' "${NFCXX_STUB_NFCXX_OUT:-}"; exit "$rc" ;;
  *) echo "stub: no stub for $name" >&2; exit 99 ;;
esac

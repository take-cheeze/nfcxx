#!/bin/bash
# Stub for the commands the pre-pass runs (tests/nfcxx-prepass/run.sh links it under each name, and the sandbox's
# nfcxx-nested, cppfront and sycl-integration-header.sh):
#   gcc, cc, g++  the host probes (--version, -dumpfullversion, -dM, -v, -E) answer silently; any other call is logged (RUN)
#   mktemp -d     a fresh directory under $NFCXX_STUB_TMP, printed
#   mkdir, cat    logged (RUN, CAT for pass1.log), then run for real
#   cppfront      logged (RUN cwd=...), exit status from the facts (cppfront-rc)
#   sycl-integration-header.sh   logged (RUN) and its stdout's file (WRITE); exit status from the facts (sycl-header-rc)
#   nfcxx-nested  the driver's own nested runs, with the SYCL variables (EXEC). Pass 1 writes sycl-dump records to the dump
#                 file; pass 2 logs the wrapper it is given (WRITE, "| " lines) and exits with sycl-pass2-rc.
# Environment: NFCXX_FACTS, NFCXX_STUB_LOG, NFCXX_STUB_TMP, NFCXX_STUB_ROOT (the sandbox's repository).
name=$(basename "$0")
log() { printf '%s\n' "$*" >> "$NFCXX_STUB_LOG"; }
fact() { awk -v k="$1" '$1 == k { print $2; exit }' "$NFCXX_FACTS"; }
real() { env PATH=/usr/bin:/bin "$@"; }
case $name in
  gcc|cc|g++)
    for a in "$@"; do
      case $a in
        -dumpfullversion) echo 13.3.0; exit 0 ;;
        -dM) echo "#define __GNUC__ 13"; exit 0 ;;
        --version|-v|-E) exit 0 ;;
      esac
    done
    log "RUN $name $*"; exit 0 ;;
  mktemp)
    d=$NFCXX_STUB_TMP/d$$.$RANDOM.$RANDOM
    real mkdir -p "$d" && echo "$d"; exit 0 ;;
  mkdir) log "RUN mkdir $*"; real mkdir "$@"; exit $? ;;
  cat)
    for a in "$@"; do case $a in */pass1.log) log "CAT $a" ;; esac; done
    real cat "$@"; exit $? ;;
  cppfront)
    log "RUN cwd=$(pwd -P) $NFCXX_STUB_ROOT/build/cppfront $*"
    exit "$(fact cppfront-rc)" ;;
  sycl-integration-header.sh)
    log "RUN $NFCXX_STUB_ROOT/scripts/sycl-integration-header.sh $*"
    log "WRITE $(readlink /proc/$$/fd/1)"
    exit "$(fact sycl-header-rc)" ;;
  nfcxx-nested)
    pre=""
    [ -n "${NFCXX_SYCL_PASS:-}" ] && pre="NFCXX_SYCL_PASS=$NFCXX_SYCL_PASS"
    [ -n "${NFCXX_SYCL_DUMP:-}" ] && pre="${pre:+$pre }NFCXX_SYCL_DUMP=$NFCXX_SYCL_DUMP"
    if [ -n "${NFCXX_SYCL_DUMP:-}" ]; then
      n=$(fact sycl-dump); i=0
      while [ "$i" -lt "$n" ]; do printf 'k%d\t8\t1\t1\tf.cc\t0\n' "$i" >> "$NFCXX_SYCL_DUMP"; i=$((i + 1)); done
      log "EXEC ${pre:+$pre }$NFCXX_STUB_ROOT/nfcxx $*"
      exit 0
    fi
    for a in "$@"; do
      case $a in
        *wrapper.cpp) log "WRITE $a"; sed 's/^/| /' "$a" >> "$NFCXX_STUB_LOG" ;;
      esac
    done
    log "EXEC ${pre:+$pre }$NFCXX_STUB_ROOT/nfcxx $*"
    exit "$(fact sycl-pass2-rc)" ;;
  *) echo "stub: no stub for $name" >&2; exit 99 ;;
esac

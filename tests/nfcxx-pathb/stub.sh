#!/bin/bash
# Stub for the commands the Path B path of nfcxx runs. tests/nfcxx-pathb/run.sh links this file under each name.
#   cc                     the link: RUN cc ARGS, logged, not run
#   g++, gcc               probes (--version, -dumpfullversion, -v, -dM) answer; anything else is logged (RUN), not run
#   cp, ninja, eccp        logged (RUN), not run (not on the Path B path)
#   env                    the gcc fallback's exec: EXEC env ARGS, logged; exit 0 (the bash does not return from exec)
#   g++ -E                 the -E exec (exec g++ -E ...): EXEC g++ ARGS, logged; exit 0 (probes such as g++ -v stay silent)
#   mktemp                 -d: a fresh directory under $NFCXX_STUB_TMP, printed
#   pathb-cc               RUN $0 ARGS, logged; exits with the pathb-status fact of the first argument that has one
#   pathb-ldrt, ehshim, sret.sh, asan-vla, safeptr-rt
#                          print their facts (ROOT stands for the sandbox's repository); nothing when absent
#   ld.NAME                exists only, for command -v (-fuse-ld=NAME)
# Environment: NFCXX_FACTS (the facts file), NFCXX_STUB_LOG (the log), NFCXX_STUB_TMP, NFCXX_STUB_ROOT (the sandbox's repository).
name=$(basename "$0")
log() { printf '%s\n' "$*" >> "$NFCXX_STUB_LOG"; }
fact() { awk -v k="$1" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }' "$NFCXX_FACTS"; }
case $name in
  cc|g++|gcc)
    probe=""
    for a in "$@"; do
      case $a in --version|-dumpfullversion|-v|-dM) probe=$a ;; esac
    done
    case $probe in
      --version) echo "$name (GCC) 13.3.0"; exit 0 ;;
      -dumpfullversion) echo 13.3.0; exit 0 ;;
      -v|-dM) exit 0 ;;
    esac
    # g++ -E is the driver's -E exec (exec "$hostcxx" -E ...): the bash does not return from it
    if [ "$name" = g++ ] && [[ " $* " == *" -E "* ]]; then log "EXEC $name $*"; exit 0; fi
    log "RUN $name $*"; exit 0 ;;
  cp|ninja|eccp) log "RUN $name $*"; exit 0 ;;
  env) log "EXEC env $*"; exit 0 ;;
  mktemp)
    d=$NFCXX_STUB_TMP/d$$.$RANDOM.$RANDOM
    mkdir -p "$d" && echo "$d"; exit 0 ;;
  pathb-cc)
    log "RUN $0 $*"
    for a in "$@"; do
      v=$(awk -v n="$a" '$1 == "pathb-status" && $2 == n { print $3; exit }' "$NFCXX_FACTS")
      if [ -n "$v" ]; then exit "$v"; fi
    done
    exit 0 ;;
  pathb-ldrt|ehshim|asan-vla.rb|safeptr-rt.rb) v=$(fact "${name%.rb}")
    [ -z "$v" ] || printf '%s\n' "${v//ROOT/$NFCXX_STUB_ROOT}"
    [ "${name%.rb}" != asan-vla ] || [ -n "$v" ] || exit 1
    exit 0 ;;
  sret.sh) v=$(fact sret)
    [ -z "$v" ] || printf '%s\n' "${v//ROOT/$NFCXX_STUB_ROOT}"
    exit 0 ;;
  ld.*) exit 0 ;;
  *) echo "stub: no stub for $name" >&2; exit 99 ;;
esac

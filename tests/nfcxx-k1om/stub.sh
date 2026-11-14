#!/bin/bash
# Stub for the commands the --target gate of nfcxx can reach. tests/nfcxx-k1om/run.sh links this file under each name.
#   gcc, cc, g++  probes (--version, -dumpfullversion, -dM, and -v: the host include list, which is empty here) answer with
#                 a GCC 13 host; any other call is logged (RUN), not run
#   cp, ninja     logged (CP, RUN), not run
#   mktemp        -d: a fresh directory under $NFCXX_STUB_TMP, printed (not logged)
#   eccp          logged (RUN), not run (the EDG driver, at ROOT/build/edg/bin/eccp)
#   ld.NAME       exists only, for command -v (-fuse-ld=NAME)
# Environment: NFCXX_STUB_LOG (the log), NFCXX_STUB_TMP (the temporary directories).
name=$(basename "$0")
log() { printf '%s\n' "$*" >> "$NFCXX_STUB_LOG"; }
case $name in
  gcc|cc|g++)
    for a in "$@"; do
      case $a in
        --version) echo "$name (GCC) 13.3.0"; exit 0 ;;
        -dumpfullversion) echo 13.3.0; exit 0 ;;
        -dM) echo "#define __GNUC__ 13"; exit 0 ;;
        -v) { echo '#include <...> search starts here:'; echo 'End of search list.'; } >&2; exit 0 ;;
      esac
    done
    log "RUN $name $*"; exit 0 ;;
  cp) log "CP $*"; exit 0 ;;
  ninja) log "RUN ninja $*"; exit 0 ;;
  mktemp)
    d=$NFCXX_STUB_TMP/d$$.$RANDOM.$RANDOM
    mkdir -p "$d" && echo "$d"; exit 0 ;;
  eccp) log "RUN eccp $*"; exit 0 ;;
  ld.*) exit 0 ;;
  *) echo "stub: no stub for $name" >&2; exit 99 ;;
esac

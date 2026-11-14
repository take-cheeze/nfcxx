#!/bin/bash
# Stub for the commands the --emit-c and --emit-hip paths of nfcxx run. tests/nfcxx-freestanding/run.sh links this file
# under each name (see run.sh).
#   g++, gcc, cc  probes (--version, -dumpfullversion, -v) answer from facts.txt; any other call is not expected
#   cpfe          the EDG front end: logged (ENV first, when EDG_CPFE_DEFAULT_OPTIONS is set, then RUN); it writes a
#                 stand-in to its --gen_c_file_name
#   cuda-rewrite  the rewriter: logged (EXEC), as the bash execs it
#   cp, ninja     logged (CP, RUN), not run
#   mktemp        -d: a fresh directory under $NFCXX_STUB_TMP, printed
#   eccp          exists only (the driver checks -x)
# Environment: NFCXX_FACTS (the facts file), NFCXX_STUB_LOG (the log), NFCXX_STUB_TMP.
name=$(basename "$0")
log() { printf '%s\n' "$*" >> "$NFCXX_STUB_LOG"; }
fact() { awk -v k="$1" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }' "$NFCXX_FACTS"; }
case $name in
  g++|gcc|cc)
    probe=""
    for a in "$@"; do
      case $a in --version|-dumpfullversion|-v) probe=$a ;; esac
    done
    case $probe in
      --version)
        if [ "$(fact cxx-clang)" = 1 ]; then echo "clang version 21.0.0"; else echo "g++ (GCC) 13.3.0"; fi
        exit 0 ;;
      -dumpfullversion) fact gnu-dump; exit 0 ;;
      -v)
        { echo '#include <...> search starts here:'; awk '$1 == "host-sys" { print " " $2 }' "$NFCXX_FACTS"; echo 'End of search list.'; } >&2
        exit 0 ;;
    esac
    echo "stub: $name called without a probe" >&2; exit 99 ;;
  cpfe)
    [ -z "${EDG_CPFE_DEFAULT_OPTIONS+x}" ] || log "ENV EDG_CPFE_DEFAULT_OPTIONS=$EDG_CPFE_DEFAULT_OPTIONS"
    log "RUN $0 $*"
    for a in "$@"; do case $a in --gen_c_file_name=*) printf '/* stub */\n' > "${a#--gen_c_file_name=}" ;; esac; done
    exit 0 ;;
  cuda-rewrite) log "EXEC $0 $*"; exit 0 ;;
  cp) log "CP $*"; exit 0 ;;
  ninja) log "RUN ninja $*"; exit 0 ;;
  mktemp)
    d=$NFCXX_STUB_TMP/d$$.$RANDOM.$RANDOM
    mkdir -p "$d" && echo "$d"; exit 0 ;;
  eccp) exit 0 ;;
  *) echo "stub: no stub for $name" >&2; exit 99 ;;
esac

#!/bin/bash
# Stub for the commands the --cosmo C path of nfcxx runs. tests/nfcxx-cosmo/run.sh links this file under each name.
#   gcc, cc, g++  probes (--version, -dumpfullversion) answer silently; anything else is logged (RUN) and not run
#   cosmocc       a stand-in for the cosmocc binary: probes answer silently, any other call is logged (RUN) under the path it
#                 was invoked by (under the sandbox's ROOT), and not run
#   cp            logged (CP), not copied
#   mktemp        -d: a fresh directory under $NFCXX_STUB_TMP, printed
# Environment: NFCXX_STUB_LOG (the log), NFCXX_STUB_TMP (the temporary directories).
name=$(basename "$0")
log() { printf '%s\n' "$*" >> "$NFCXX_STUB_LOG"; }
case $name in
  gcc|cc|g++)
    for a in "$@"; do
      case $a in
        --version) echo "$name (GCC) 13.3.0"; exit 0 ;;
        -dumpfullversion) echo 13.3.0; exit 0 ;;
      esac
    done
    log "RUN $name $*"
    # the -dM probe prints predefined macros: one always, and two more with -mavx2 (the -m block's comm and sed read them)
    case " $* " in
      *" -dM "*) echo '#define __x86_64__ 1'
                 case " $* " in *" -mavx2 "*) echo '#define __AVX2__ 1'; echo '#define __AVX__ 1' ;; esac ;;
    esac
    exit 0 ;;
  cosmocc)
    for a in "$@"; do
      case $a in
        --version) echo "cosmocc (GCC) 14.1.0"; exit 0 ;;
        -dumpfullversion) echo 14.1.0; exit 0 ;;
      esac
    done
    log "RUN $0 $*"; exit 0 ;;
  cp) log "CP $*"; exit 0 ;;
  mktemp)
    d=$NFCXX_STUB_TMP/d$$.$RANDOM.$RANDOM
    mkdir -p "$d" && echo "$d"; exit 0 ;;
  *) echo "stub: no stub for $name" >&2; exit 99 ;;
esac

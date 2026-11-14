#!/bin/bash
# Stub for the commands the paths of nfcxx run. tests/nfcxx-freestanding/run.sh links this file under each name (see run.sh).
#   g++           probes (--version, -dumpfullversion, -v) answer from facts.txt; any other call is the -E exec: logged (EXEC)
#   gcc           probes answer from facts.txt; any other call is not expected (the -m probe: it fails, its output is unused)
#   cc            the link (or the C compile): logged (RUN cc)
#   cpfe          the EDG front end: logged (RUN); it writes a stand-in to its --gen_c_file_name
#   pathb-cc      the Path B compile of one source: logged (RUN)
#   pathb-ldrt    prints the archive path from facts.txt (pathb-ldrt), under the repository
#   uname         -s and -m answer from facts.txt; other calls run the real uname
#   cuda-rewrite  the rewriter: logged (EXEC), as the bash execs it
#   cp, ninja     logged (CP, RUN), not run
#   mktemp        -d: a fresh directory under $NFCXX_STUB_TMP, printed
#   eccp          exists only (the driver checks -x)
# The environment variable EDG_CPFE_DEFAULT_OPTIONS, when the driver exported it, is logged (ENV) before the RUN line of
# each program that inherits it (cpfe, pathb-cc, cc).
# Environment: NFCXX_FACTS (the facts file), NFCXX_STUB_LOG (the log), NFCXX_STUB_TMP.
name=$(basename "$0")
log() { printf '%s\n' "$*" >> "$NFCXX_STUB_LOG"; }
fact() { awk -v k="$1" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }' "$NFCXX_FACTS"; }
envlog() { [ -z "${EDG_CPFE_DEFAULT_OPTIONS+x}" ] || log "ENV EDG_CPFE_DEFAULT_OPTIONS=$EDG_CPFE_DEFAULT_OPTIONS"; }
case $name in
  g++|gcc)
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
    if [ "$name" = g++ ]; then log "EXEC g++ $*"; exit 0; fi
    echo "stub: $name called without a probe" >&2; exit 99 ;;
  cc) envlog; log "RUN cc $*"; exit 0 ;;
  cpfe)
    envlog
    log "RUN $0 $*"
    for a in "$@"; do case $a in --gen_c_file_name=*) printf '/* stub */\n' > "${a#--gen_c_file_name=}" ;; esac; done
    exit 0 ;;
  pathb-cc) envlog; log "RUN $0 $*"; exit 0 ;;
  pathb-ldrt.rb) echo "$(dirname "$(dirname "$0")")/$(fact pathb-ldrt)"; exit 0 ;;
  uname)
    case $1 in
      -s) fact uname ;;
      -m) fact machine ;;
      *) exec /usr/bin/uname "$@" ;;
    esac
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

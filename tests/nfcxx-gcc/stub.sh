#!/bin/bash
# Stub for the commands the gcc path of nfcxx runs. tests/nfcxx-gcc/run.sh links this file under each name (see run.sh).
#   gcc, cc, g++  probes (--version, -dumpfullversion, -dM, -v) answer from facts.txt; a -E with no probe option is
#                 nfcxx's exec of g++ -E (EXEC); any other call is a compile or a link (RUN), logged and not run
#   cp            logged (CP), not copied
#   ninja         logged (RUN), not run (the repository tools are built before the gcc path)
#   mktemp        -d: a fresh directory under $NFCXX_STUB_TMP, printed
#   eccp          logged (RUN), after ENV when EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS is set (the bash exports it for -shared)
#   ehshim.rb, sret.rb, asan-vla  print their facts (asan-vla fails when the fact is absent)
#   ld.NAME       exists only, for command -v (-fuse-ld=NAME)
#   uname -m      the fact machine (other uname calls run for real)
#   cuda-cub      prints the fact cuda-cub (absent: it fails, as the script does without a CUDA archive)
#   cuda-driver-shim  the fact cuda-shim-error (fails with its text), else the fact cuda-shim (its path)
# Environment: NFCXX_FACTS (the facts file), NFCXX_STUB_LOG (the log), NFCXX_STUB_TMP, NFCXX_STUB_ROOT (the sandbox's
# repository, which the facts' ROOT stands for).
name=$(basename "$0")
log() { printf '%s\n' "$*" >> "$NFCXX_STUB_LOG"; }
fact() { awk -v k="$1" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }' "$NFCXX_FACTS"; }
case $name in
  gcc|cc|g++)
    probe=""; pre=0
    for a in "$@"; do
      case $a in --version|-dumpfullversion|-dM|-v) probe=$a ;; -E) pre=1 ;; esac
    done
    case $probe in
      --version)
        if [ "$(fact "$name-clang")" = 1 ] || { [ "$name" = cc ] && [ "$(fact cc-clang)" = 1 ]; }; then echo "clang version 21.0.0"
        else echo "$name (GCC) 13.3.0"; fi
        exit 0 ;;
      -dumpfullversion) echo 13.3.0; exit 0 ;;
      -dM)
        echo "#define __GNUC__ 13"
        awk -v args=" $* " '$1 == "isa" && index(args, " " $2 " ") { print "#define " $3 " " $4 }' "$NFCXX_FACTS"
        exit 0 ;;
      -v)
        { echo '#include <...> search starts here:'; awk '$1 == "host-sys" { print " " $2 }' "$NFCXX_FACTS"; echo 'End of search list.'; } >&2
        exit 0 ;;
    esac
    if [ $pre = 1 ]; then log "EXEC $name $*"; else log "RUN $name $*"; fi
    exit 0 ;;
  cp) log "CP $*"; exit 0 ;;
  ninja) log "RUN ninja $*"; exit 0 ;;
  mktemp)
    d=$NFCXX_STUB_TMP/d$$.$RANDOM.$RANDOM
    mkdir -p "$d" && echo "$d"; exit 0 ;;
  eccp)
    [ -z "${EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS+x}" ] || log "ENV EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS=$EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS"
    log "RUN $0 $*"; exit 0 ;;
  ehshim.rb|sret.rb|asan-vla)
    key=${name%.rb}; [ "$name" = sret.rb ] && key=sret
    v=$(fact "$key")
    if [ "$name" = asan-vla ] && [ -z "$v" ]; then exit 1; fi
    [ -z "$v" ] || printf '%s\n' "${v//ROOT/$NFCXX_STUB_ROOT}"
    exit 0 ;;
  ld.*) exit 0 ;;
  uname)
    if [ "$1" = -m ]; then fact machine; else /usr/bin/uname "$@"; fi
    exit 0 ;;
  cuda-cub)
    v=$(fact cuda-cub); [ -n "$v" ] || exit 1
    printf '%s\n' "${v//ROOT/$NFCXX_STUB_ROOT}"; exit 0 ;;
  cuda-driver-shim)
    e=$(fact cuda-shim-error)
    if [ -n "$e" ]; then printf '%s\n' "$e"; exit 1; fi
    v=$(fact cuda-shim); [ -n "$v" ] || { echo "stub: no cuda-shim fact" >&2; exit 99; }
    printf '%s\n' "${v//ROOT/$NFCXX_STUB_ROOT}"; exit 0 ;;
  *) echo "stub: no stub for $name" >&2; exit 99 ;;
esac

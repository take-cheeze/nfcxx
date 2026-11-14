#!/bin/bash
# Stub for the commands the gcc path of nfcxx runs. tests/nfcxx-gcc/run.sh links this file under each name (see run.sh).
#   gcc, cc, g++  probes (--version, -dumpfullversion, -dM, -v) answer from facts.txt; a -E with no probe option is
#                 nfcxx's exec of g++ -E (EXEC); any other call is a compile or a link (RUN), logged and not run
#   cp            logged (CP), not copied
#   ninja         logged (RUN), not run (the repository tools are built before the gcc path)
#   mktemp        -d: a fresh directory under $NFCXX_STUB_TMP, printed
#   eccp          logged (RUN), after ENV when EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS is set (the bash exports it for -shared)
#   ehshim, sret.sh, asan-vla  print their facts (asan-vla fails when the fact is absent)
#   ld.NAME       exists only, for command -v (-fuse-ld=NAME)
#   pathb-cc, cc  logged (RUN), not run: Path B's compile and link (cc is also the gcc probes' name, and those are not logged)
#   qbe           exists; pathb-ldrt prints its fact (the archive's path)
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
  pathb-cc) log "RUN $0 $*"; exit 0 ;;
  qbe) exit 0 ;;   # build/qbe/qbe exists, so Path B's "QBE not built" refusal does not fire
  pathb-ldrt) v=$(fact pathb-ldrt); printf '%s\n' "${v//ROOT/$NFCXX_STUB_ROOT}"; exit 0 ;;
  mktemp)
    d=$NFCXX_STUB_TMP/d$$.$RANDOM.$RANDOM
    mkdir -p "$d" && echo "$d"; exit 0 ;;
  eccp)
    [ -z "${EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS+x}" ] || log "ENV EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS=$EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS"
    log "RUN $0 $*"; exit 0 ;;
  ehshim|sret.sh|asan-vla.rb)
    key=ehshim; [ "$name" = sret.sh ] && key=sret; [ "$name" = asan-vla.rb ] && key=asan-vla
    v=$(fact "$key")
    if [ "$name" = asan-vla.rb ] && [ -z "$v" ]; then exit 1; fi
    [ -z "$v" ] || printf '%s\n' "${v//ROOT/$NFCXX_STUB_ROOT}"
    exit 0 ;;
  ld.*) exit 0 ;;
  cc) log "RUN cc $*"; exit 0 ;;
  *) echo "stub: no stub for $name" >&2; exit 99 ;;
esac

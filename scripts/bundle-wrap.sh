# Sourced by nfcxx and nfcc: --bundle-libs and its companions (docs/notes/bundle.md).
#   --bundle-libs              after the link, copy the shared libraries the output needs (libstdc++, libgcc_s, the
#                              program's own; never glibc) into it with tools/bundle (build/nfcbundle)
#   --bundle-exclude=NAME,...  keep these libraries external (a soname, a file name, or a stem such as libfoo)
#   --bundle-only=NAME,...     bundle only these
# bundle_wrap DRIVER ARGS...: without --bundle-libs, the --bundle-* options are an error and nothing else happens
# (the caller goes on with ARGS). With it, DRIVER runs again on ARGS without the --bundle-* options and, when the command
# links (no -c, -E, -S, -M, -MM, -fsyntax-only, --emit-c), nfcbundle rewrites the output in place; then this exits. The
# -L directories of the command are searched too, so a library found only through -L needs no run-time path.
bundle_wrap() {
  local driver=$1; shift
  case " $* " in *" --bundle-"*) ;; *) return 0 ;; esac
  local on=0 link=1 out=a.out prev="" a x args=() opts=() list
  for a in "$@"; do
    if [ "$prev" = -o ]; then out=$a; fi
    if [ "$prev" = -L ]; then opts+=(-L "$a"); fi
    case $a in
      --bundle-libs) on=1 ;;
      --bundle-exclude=*|--bundle-only=*)
        IFS=, read -ra list <<<"${a#*=}"
        for x in ${list[@]+"${list[@]}"}; do
          case $a in --bundle-exclude=*) opts+=(--exclude "$x") ;; *) opts+=(--only "$x") ;; esac
        done ;;
      --bundle-*) echo "$(basename "$driver"): unknown option $a (--bundle-libs, --bundle-exclude=, --bundle-only=)" >&2; exit 2 ;;
      *)
        args+=("$a")
        case $a in
          -c|-E|-S|-M|-MM|-fsyntax-only|--emit-c) link=0 ;;
          -L?*) opts+=(-L "${a#-L}") ;;
        esac ;;
    esac
    prev=$a
  done
  if [ $on = 0 ]; then
    echo "$(basename "$driver"): --bundle-exclude and --bundle-only need --bundle-libs" >&2; exit 2
  fi
  "$driver" ${args[@]+"${args[@]}"} || exit $?
  [ $link = 1 ] || exit 0
  local tool=$root/build/nfcbundle
  if [ ! -x "$tool" ] || [ "$root/tools/bundle/nfcbundle.cpp" -nt "$tool" ]; then
    make -s -C "$root/tools/bundle" >&2 || { echo "$(basename "$driver"): cannot build $tool (tools/bundle)" >&2; exit 1; }
  fi
  exec "$tool" ${opts[@]+"${opts[@]}"} "$out" -o "$out"
}

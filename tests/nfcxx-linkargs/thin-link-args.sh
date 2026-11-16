# link_args as nfcxx had it before the link arguments moved into the eccp plan (verbatim): the reader of the CLI below
link_args() {  # link_args COMPILE_ONLY MOVES FILE...: sets eflist and userinc; a refused option ends nfcxx with status 2
  local rec done=0 group=
  eflist=(); userinc=()
  while IFS= read -r -d '' rec; do
    case $rec in
      k*) group=${rec:1} ;;
      v*) if [ "$group" = eflist ]; then eflist+=("${rec:1}"); elif [ "$group" = userinc ]; then userinc+=("${rec:1}"); fi ;;
      x*) printf '%s\n' "${rec:1}" >&2; exit 2 ;;
      z) done=1 ;;
    esac
  done < <("${RUBY:-ruby}" "$root/scripts/nfcxx-linkargs.rb" edg "$1" "$2" ${3+"${@:3}"})
  # the end marker z is written last by the port: without it the helper stopped early, so the arrays are incomplete
  [ $done = 1 ] || { echo "nfcxx: scripts/nfcxx-linkargs.rb stopped before its end (the link arguments are incomplete)" >&2; exit 1; }
  return 0
}

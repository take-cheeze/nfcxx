# The bash originals of nfcxx's ecp_arg and abs_path, verbatim (scripts/ecp-arg.rb is the port). Sourced by
# tests/nfcxx-ecp-arg/run.sh with moves=1: the case the port answers.
moves=1
abs_path() {
  local d b
  d=$(dirname "$1"); b=$(basename "$1")
  if (cd "$d" 2>/dev/null); then (cd "$d" && printf '%s/%s\n' "$(pwd -P)" "$b")
  else printf '%s\n' "$1"; fi
}
ecp_arg() {  # ecp_arg ARG: ARG as eccp receives it (its paths absolute when eccp runs in the temporary directory)
  if [ $moves = 0 ]; then printf '%s\n' "$1"; return 0; fi
  case $1 in
    -I?*) printf -- '-I%s\n' "$(abs_path "${1#-I}")" ;;
    -L?*) printf -- '-L%s\n' "$(abs_path "${1#-L}")" ;;
    -Wl,*)   # a file named in a link option (-Wl,--version-script=FILE, -Wl,-T,FILE) is made absolute when it exists here
      local res=-Wl p parts=() prevp=
      IFS=, read -r -a parts <<< "${1#-Wl,}"
      for p in ${parts[@]+"${parts[@]}"}; do
        # the operand of -soname (-h) is the name the library records, not a file, even when a file has that name here
        case $prevp in -soname|--soname|-h) res+=",$p"; prevp=$p; continue ;; esac
        prevp=$p
        case $p in
          -soname=*|--soname=*) ;;
          # Files the link writes (CMake 4 passes -Wl,--dependency-file=CMakeFiles/T.dir/link.d): absolute when their
          # directory exists here, since they do not exist yet.
          --dependency-file=*|-Map=*|--Map=*)
            if [ -e "${p#*=}" ] || [ -d "$(dirname -- "${p#*=}")" ]; then
              p="${p%%=*}=$(abs_path "$(dirname -- "${p#*=}")")/$(basename -- "${p#*=}")"
            fi ;;
          *=*) if [ -e "${p#*=}" ]; then p="${p%%=*}=$(abs_path "${p#*=}")"; fi ;;
          *) if [ -e "$p" ]; then p=$(abs_path "$p"); fi ;;
        esac
        res+=",$p"
      done
      printf '%s\n' "$res" ;;
    -*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$(abs_path "$1")" ;;
  esac
}

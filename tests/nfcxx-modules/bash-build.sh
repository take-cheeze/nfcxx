# The original bash mod_build_program (the function as it was before the Ruby build, scripts/nfcxx-modules.rb build).
# tests/nfcxx-modules/run.sh puts it in the bash oracle in place of the thin call, so the oracle is the bash build.
mod_build_program() {
  local mdir ifaces=() others=() ordered=() rest=() s d o n=0 ready progress all=" " done_names=" "
  local objs=() compile_args=() link_args=() a x is_src skip=0
  mtmp=$(mktemp -d); trap 'rm -rf "$mtmp"' EXIT
  mdir=${moddir:-$mtmp}
  for s in ${srcs[@]+"${srcs[@]}"}; do
    mod_check_src "$s"
    if [ -n "$(mod_decl_name "$s")" ]; then ifaces+=("$s"); all+="$(mod_decl_name "$s") "; else others+=("$s"); fi
  done
  while [ ${#ifaces[@]} -gt 0 ]; do
    progress=0; rest=()
    for s in "${ifaces[@]}"; do
      ready=1
      for d in $(mod_imports "$s"); do
        case $all in *" $d "*) case $done_names in *" $d "*) ;; *) ready=0 ;; esac ;; esac
      done
      if [ $ready = 1 ]; then ordered+=("$s"); done_names+="$(mod_decl_name "$s") "; progress=1; else rest+=("$s"); fi
    done
    [ $progress = 1 ] || { echo "nfcxx: cyclic module imports among: ${rest[*]}" >&2; exit 2; }
    ifaces=(${rest[@]+"${rest[@]}"})
  done
  ordered+=(${others[@]+"${others[@]}"})
  # The options of each step: the compile gets everything but the link-only ones, the link gets everything but the sources.
  for a in ${nfcxx_argv[@]+"${nfcxx_argv[@]}"}; do
    if [ $skip = 1 ]; then skip=0; continue; fi
    is_src=0; for x in ${srcs[@]+"${srcs[@]}"}; do [ "$x" = "$a" ] && is_src=1; done
    [ $is_src = 0 ] || continue
    case $a in
      -o) skip=1 ;;
      -c|--module-dir=*) ;;
      -l?*|-L?*|-Wl,*|*.o|*.a|*.so) link_args+=("$a") ;;
      *) compile_args+=("$a"); link_args+=("$a") ;;
    esac
  done
  for s in ${ordered[@]+"${ordered[@]}"}; do
    o=$mtmp/m$n.o; n=$((n + 1))
    "$root/nfcxx" -c "$s" -o "$o" --module-dir="$mdir" ${compile_args[@]+"${compile_args[@]}"}
    objs+=("$o")
  done
  "$root/nfcxx" ${objs[@]+"${objs[@]}"} ${link_args[@]+"${link_args[@]}"} -o "$out"
  exit 0
}

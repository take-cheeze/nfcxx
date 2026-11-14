# The bash response-file expansion of nfcc before it moved to scripts/nfcc-args.rb (frozen as the test oracle).
die() { echo "nfcc: error: $*" >&2; exit 1; }
expanded=()
add_arg() {   # add_arg ARG DEPTH: ARG, or the arguments in the response file it names
  local f=${1:1} text len j ch q="" have=0 cur="" parsed=() k
  if [ "${1:0:1}" != @ ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then expanded+=("$1"); return; fi
  [ "$2" -lt 32 ] || die "response files nested too deeply (a loop?): $f"
  text=$(cat -- "$f"; echo x); text=${text%x}; len=${#text}
  for ((j = 0; j < len; j++)); do
    ch=${text:j:1}
    if [ "$ch" = "\\" ]; then
      j=$((j + 1)); [ $j -lt $len ] || break
      cur+=${text:j:1}; have=1
    elif [ -n "$q" ]; then
      if [ "$ch" = "$q" ]; then q=""; else cur+=$ch; fi
    else
      case $ch in
        "'"|'"') q=$ch; have=1 ;;
        ' '|$'\t'|$'\n'|$'\r'|$'\f'|$'\v') if [ $have = 1 ]; then parsed+=("$cur"); fi; cur=""; have=0 ;;
        *) cur+=$ch; have=1 ;;
      esac
    fi
  done
  if [ $have = 1 ]; then parsed+=("$cur"); fi
  for k in "${parsed[@]+"${parsed[@]}"}"; do add_arg "$k" $(($2 + 1)); done
}

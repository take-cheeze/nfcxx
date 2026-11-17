# the bash helpers and apply loop of nfcxx, verbatim (before the --shell mode of scripts/nfcxx-loop.rb)
loop_set() {  # loop_set NAME=VALUE: the loop's scalar NAME
  printf -v "${1%%=*}" '%s' "${1#*=}"
}
loop_append() {  # loop_append NAME=VALUE: appends VALUE to the loop's array NAME
  case ${1%%=*} in
    files) files+=("${1#*=}") ;;
    cflags) cflags+=("${1#*=}") ;;
    cfiles) cfiles+=("${1#*=}") ;;
    cu_inputs) cu_inputs+=("${1#*=}") ;;
    cpp2_inputs) cpp2_inputs+=("${1#*=}") ;;
    srcs) srcs+=("${1#*=}") ;;
    ppflags) ppflags+=("${1#*=}") ;;
    pie_opts) pie_opts+=("${1#*=}") ;;
    preinc) preinc+=("${1#*=}") ;;
    sysdirs) sysdirs+=("${1#*=}") ;;
    isa) isa+=("${1#*=}") ;;
    diag_opts) diag_opts+=("${1#*=}") ;;
    asanopts) asanopts+=("${1#*=}") ;;
    *) echo "nfcxx: scripts/nfcxx-loop.rb sent an unknown array (${1%%=*})" >&2; exit 1 ;;
  esac
}
loop_no_value() { : "$2"; }   # a value option given last: $2 is unset here (set -u ends the driver)
# the apply (the driver's loop_recs block up to the record reads' end), with the records from RECORDS_FILE (the --records output)
apply_records() {
  loop_recs=(); loop_done=0; loop_refused=""; loop_missing=""
  while IFS= read -r -d '' loop_rec; do
    case $loop_rec in
      z) loop_done=1 ;;
      x*) loop_refused=${loop_rec:1} ;;
      u*) loop_missing=${loop_rec:1} ;;
      *) loop_recs+=("$loop_rec") ;;
    esac
  done < "$RECORDS_FILE"
  if [ -n "$loop_refused" ]; then printf '%s\n' "$loop_refused" >&2; exit 2; fi
  if [ -n "$loop_missing" ]; then loop_no_value "$loop_missing"; fi
  [ $loop_done = 1 ] || { echo "nfcxx: scripts/nfcxx-loop.rb stopped before its end (the argument state is incomplete)" >&2; exit 1; }
  for loop_rec in ${loop_recs[@]+"${loop_recs[@]}"}; do
    case $loop_rec in
      s*) loop_set "${loop_rec:1}" ;;
      a*) loop_append "${loop_rec:1}" ;;
    esac
  done
}

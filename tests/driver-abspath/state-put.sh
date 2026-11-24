state_put() {  # state_put NAME VALUE...: one group of the records scripts/driver-state.rb reads (k NAME, then v VALUE for each)
  local n=$1 v
  shift
  printf 'k%s\0' "$n"
  for v in ${1+"$@"}; do printf 'v%s\0' "$v"; done
}

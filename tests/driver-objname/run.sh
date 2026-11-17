#!/bin/bash
# Differential test of the -c object names: the bash expressions verbatim (the driver's ${b%.*}.o after basename, and
# basename NAME .c, .o) against scripts/nfcxx-objname.rb, which names all the objects of a call in one run. Each name is
# one case; the Ruby output is read back with while IFS= read, as the driver reads it, and must match byte for byte.
#   bash tests/driver-objname/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ruby_bin=$(command -v ruby)

# the names: plain names, dotfiles, no extension, several dots, trailing dots, directories, spaces, trailing slashes
names=(
  "m.cpp" "m.cc" "dir/m.cpp" "/abs/dir/m.cpp" "a/b/c/deep.name.cpp"
  ".bashrc" "dir/.hidden" ".hidden.cpp" "..cpp"
  "noext" "dir/noext" "a." "dir/a." "a.b.c" "x.tar.gz" "trail..." "a.."
  "." ".." "dir/." "dir/.." "dir/" "dir//m.cpp" "dir/sub/" "m.cpp/"
  "my file.cpp" "dir with space/x y.cc" " lead.cpp" "tab	x.c"
  "UPPER.CPP" "a.b/c" "a.b/noext"
)
# the --suffix form: basename NAME .c, then .o
suffix_names=(
  "m.c" "dir/m.c" ".c" "a.c.c" "noext" "m.cpp" "x.c/" "dir/.c" "my file.c" "c.c.cpp" "a.cc"
)

# bash_obj NAME: the driver's expression, verbatim
bash_obj() { local x=$1; local b; b=$(basename "$x"); printf '%s\n' "${b%.*}.o"; }
bash_obj_suffix() { local x=$1; printf '%s\n' "$(basename "$x" .c).o"; }

# compare LABEL SUFFIX_FLAG NAME...: the bash result of each name against the Ruby result (one call for the list)
compare() {
  local label=$1 flag=$2; shift 2
  local list=$work/list.$label exp=$work/exp.$label got=$work/got.$label
  printf '%s\n' "$@" > "$list"
  : > "$exp"
  local n
  for n in "$@"; do
    if [ "$flag" = suffix ]; then bash_obj_suffix "$n" >> "$exp"; else bash_obj "$n" >> "$exp"; fi
  done
  local args=()
  [ "$flag" = suffix ] && args+=(--suffix=.c)
  "$ruby_bin" "$repo/scripts/nfcxx-objname.rb" ${args[@]+"${args[@]}"} < "$list" > "$got"
  # read back as the driver does, then compare each name
  local -a ebn=() gbn=()
  local line
  while IFS= read -r line; do ebn+=("$line"); done < "$exp"
  while IFS= read -r line; do gbn+=("$line"); done < "$got"
  local i
  for i in "${!ebn[@]}"; do
    if [ "${ebn[$i]}" = "${gbn[$i]-}" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      printf 'FAIL %s: name=%q bash=%q ruby=%q\n' "$label" "$(sed -n "$((i + 1))p" "$list")" "${ebn[$i]}" "${gbn[$i]-}"
    fi
  done
  [ "${#ebn[@]}" = "${#gbn[@]}" ] || { fail=$((fail + 1)); echo "FAIL $label: ${#ebn[@]} bash names, ${#gbn[@]} ruby names"; }
}

compare basename "" "${names[@]}"
# the same names one at a time, so an error in the batch cannot hide behind the others
for n in "${names[@]}"; do compare "single" "" "$n"; done
compare suffix suffix "${suffix_names[@]}"
for n in "${suffix_names[@]}"; do compare "single-suffix" suffix "$n"; done

# the usage error
"$ruby_bin" "$repo/scripts/nfcxx-objname.rb" --bogus </dev/null >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL usage: status $rc, want 2"; fi

echo "driver-objname: $pass passed, $fail failed"
[ "$fail" = 0 ]

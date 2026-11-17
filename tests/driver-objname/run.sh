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
  "UPPER.CPP" "a.b/c" "a.b/noext" "new
line.cpp"
)
# the --suffix form: basename NAME .c, then .o
suffix_names=(
  "m.c" "dir/m.c" ".c" "a.c.c" "noext" "m.cpp" "x.c/" "dir/.c" "my file.c" "c.c.cpp" "a.cc"
)

# bash_obj NAME: the driver's expression, verbatim
bash_obj() { local x=$1; local b; b=$(basename "$x"); printf '%s\n' "${b%.*}.o"; }
bash_obj_suffix() { local x=$1; printf '%s\n' "$(basename "$x" .c).o"; }

# one_case SUFFIX_FLAG NAME: the bash result against the Ruby result for one name, as the driver calls it (one run per name,
# the name on standard input, read back with $(...) and checked with the status)
one_case() {
  local flag=$1 n=$2 want got rc=0
  if [ "$flag" = suffix ]; then want=$(bash_obj_suffix "$n"); else want=$(bash_obj "$n"); fi
  if [ "$flag" = suffix ]; then got=$(printf '%s' "$n" | "$ruby_bin" "$repo/scripts/nfcxx-objname.rb" --suffix=.c) || rc=$?
  else got=$(printf '%s' "$n" | "$ruby_bin" "$repo/scripts/nfcxx-objname.rb") || rc=$?; fi
  if [ "$rc" = 0 ] && [ "$want" = "$got" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); printf 'FAIL %s: name=%q bash=%q ruby=%q status=%s\n' "$flag" "$n" "$want" "$got" "$rc"; fi
}

for n in "${names[@]}"; do one_case basename "$n"; done
for n in "${suffix_names[@]}"; do one_case suffix "$n"; done

# the usage error
"$ruby_bin" "$repo/scripts/nfcxx-objname.rb" --bogus </dev/null >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL usage: status $rc, want 2"; fi

echo "driver-objname: $pass passed, $fail failed"
[ "$fail" = 0 ]

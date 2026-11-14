#!/usr/bin/env bash
# The Ruby driver (scripts/nfcc.rb) must do what ./nfcc does. Each command line of tests/nfcc/port-cases.txt is run twice, once as
# NFCC = ./nfcc and once as NFCC = ruby scripts/nfcc.rb, each in its own copy of the work directory (tests/nfcc/port/). The same:
# exit status, stdout and stderr (temporary directory names replaced by TMP), and every file the run left in the work directory
# (byte for byte). The bash driver is the reference.
#   bash tests/nfcc/port-driver.sh
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
base=$tmp/base
mkdir -p "$base/inc"
cp tests/nfcc/port/*.c tests/nfcc/port/*.cpp tests/nfcc/port/resp "$base/" 2>/dev/null
cp tests/nfcc/port/h.h "$base/inc/" 2>/dev/null
pass=0; fail=0
norm() { sed -e "s|$tmp/bash|W|g" -e "s|$tmp/ruby|W|g" -e "s|$tmp|TMP|g" -e "s|/tmp/[A-Za-z0-9._-]*|TMP|g" -e "s|$root|ROOT|g" "$1"; }
while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  for side in bash ruby; do
    w=$tmp/$side; rm -rf "$w"; cp -a "$base" "$w"
    if [ $side = bash ]; then impl="$root/nfcc"; else impl="ruby $root/scripts/nfcc.rb"; fi
    cmd=${line//NFCC/$impl}
    (cd "$w" && eval "$cmd") > "$tmp/$side.out" 2> "$tmp/$side.err" < "$base/a.c"; echo $? > "$tmp/$side.rc"
    norm "$tmp/$side.out" > "$tmp/$side.out.n"; norm "$tmp/$side.err" > "$tmp/$side.err.n"
  done
  ok=1; why=""
  cmp -s "$tmp/bash.rc" "$tmp/ruby.rc" || { ok=0; why="status $(cat "$tmp/bash.rc") vs $(cat "$tmp/ruby.rc")"; }
  cmp -s "$tmp/bash.out.n" "$tmp/ruby.out.n" || { ok=0; why="$why stdout differs"; }
  cmp -s "$tmp/bash.err.n" "$tmp/ruby.err.n" || { ok=0; why="$why stderr differs"; }
  if ! diff -r "$tmp/bash" "$tmp/ruby" >/dev/null 2>&1; then
    d=$(diff -rq "$tmp/bash" "$tmp/ruby" 2>/dev/null | grep -v -E '\.(out|err|rc)(\.n)?$' | head -3 | tr '\n' ' ')
    [ -z "$d" ] || { ok=0; why="$why files: $d"; }
  fi
  if [ $ok = 1 ]; then pass=$((pass + 1)); echo "ok   $line (status $(cat "$tmp/bash.rc"))"
  else fail=$((fail + 1)); echo "FAIL $line: $why"; echo "  bash: $(head -2 "$tmp/bash.err.n" | tr '\n' '|')"; echo "  ruby: $(head -2 "$tmp/ruby.err.n" | tr '\n' '|')"; fi
done < tests/nfcc/port-cases.txt
echo "$pass passed, $fail failed"
[ $fail = 0 ]

#!/bin/bash
# Differential test of nfcxx's abs_path, and of the forced includes (-include FILE) that were made absolute with it. The bash
# function and the loop that called it are taken verbatim from the frozen driver (tests/driver-body/nfcxx-bash); the Ruby side is
# scripts/ecp-arg.rb's EcpArg.abs (with EcpArg.substitution, the bash $(...)) and the --preinclude options that
# scripts/nfcxx-eccp-plan.rb plans from the preinc group. The planner's records come from nfcxx's own state_put, so the words of
# the group are split as the driver splits them. Each case runs in a sandbox with a directory, a symbolic link to it, a file, a
# symbolic link to a file, a directory name with a space, and a file where a directory is expected.
#   bash tests/driver-abspath/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
oracle=$repo/tests/driver-body/nfcxx-bash
sed -n '/^abs_path() {/,/^}/p' "$oracle" > "$work/fn.sh"
[ -s "$work/fn.sh" ] || { echo "driver-abspath: no abs_path in the frozen driver" >&2; exit 2; }
sed -n '/^pre_opts=(); for f in/,/^done$/p' "$oracle" > "$work/loop.sh"
[ -s "$work/loop.sh" ] || { echo "driver-abspath: no forced-include loop in the frozen driver" >&2; exit 2; }
sed -n '/^state_put() {/,/^}/p' "$repo/tests/driver-body/nfcxx-bash" > "$work/state.sh"
[ -s "$work/state.sh" ] || { echo "driver-abspath: no state_put in nfcxx" >&2; exit 2; }
ruby_bin=$(command -v ruby)

# the sandbox: sub/f.cpp, f.cpp, afile, my dir/a b.cpp, and the links link (to sub), link2 (to link), flink.cpp (to f.cpp)
mksb() {  # mksb DIR
  rm -rf "$1"; mkdir -p "$1/sub" "$1/my dir"
  printf 'x\n' > "$1/sub/f.cpp"; printf 'x\n' > "$1/f.cpp"; printf 'x\n' > "$1/afile"; printf 'x\n' > "$1/my dir/a b.cpp"
  ln -s sub "$1/link"; ln -s link "$1/link2"; ln -s f.cpp "$1/flink.cpp"
}

# planner_pairs SB MOVES FILE...: the --preinclude pairs (NUL-separated) that the planner plans for the forced includes, run in SB
planner_pairs() {
  local sb=$1 mv=$2; shift 2
  (
    cd "$sb" || exit 1
    source "$work/state.sh"
    moves=$mv; preinc=("$@")
    state_put eccp /x/eccp; state_put std --c++23; state_put dialect gcc; state_put out a.out
    state_put moves "$moves"; state_put preinc ${preinc[@]+"${preinc[@]}"}
  ) > "$work/planner.in"
  (cd "$sb" && "$ruby_bin" "$repo/scripts/nfcxx-eccp-plan.rb" "" 0 0 < "$work/planner.in") > "$work/planner.out" || return 1
  "$ruby_bin" -e '
    recs = STDIN.binmode.read.split("\0")
    a = recs.select { |r| r.start_with?("a") }.map { |r| r[1..] }
    a.each_cons(2) { |x, y| print "--preinclude\0#{y}\0" if x == "--preinclude" }' < "$work/planner.out"
}

check() {  # check NAME STATUS: STATUS 0 is a pass
  if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); echo "FAIL $1"; fi
}

# abs_path: the bash's $(abs_path ARG) against EcpArg.abs with substitution, in the sandbox
fn_case() {  # fn_case NAME ARG
  local name=$1 arg=$2 sb=$work/sb ok
  mksb "$sb"
  arg=${arg//@SB@/$sb}
  (cd "$sb" && source "$work/fn.sh" && v=$(abs_path "$arg") && printf '%s' "$v") > "$work/b.out"
  (cd "$sb" && "$ruby_bin" -I "$repo/scripts" -r ecp-arg -e 'print EcpArg.substitution(EcpArg.abs(ARGV[0]))' -- "$arg") > "$work/r.out"
  cmp -s "$work/b.out" "$work/r.out"; ok=$?
  check "abs_path: $name" "$ok"
  [ "$ok" = 0 ] || { echo "  bash: $(cat "$work/b.out")"; echo "  ruby: $(cat "$work/r.out")"; }
}

fn_case "relative file in a directory" "sub/f.cpp"
fn_case "absolute path" "@SB@/sub/f.cpp"
fn_case "missing directory" "nodir/f.cpp"
fn_case "absolute missing directory" "/nosuch/dir/x.h"
fn_case "symbolic-link directory" "link/f.cpp"
fn_case "symbolic link to a symbolic link" "link2/f.cpp"
fn_case "root-level path" "/x"
fn_case "root directory" "/"
fn_case "trailing slash" "sub/"
fn_case "bare file name in the current directory" "f.cpp"
fn_case "dot" "."
fn_case "dot-dot" ".."
fn_case "dot-dot in the middle" "sub/../sub/f.cpp"
fn_case "a file where a directory is expected" "afile/x"
fn_case "symbolic link to a file, as the base name" "flink.cpp"
fn_case "a directory name with a space" "my dir/a b.cpp"
fn_case "empty argument" ""

# forced_case NAME MOVES: the frozen loop's pre_opts (the bash's pairs) against the planner's --preinclude pairs
forced_case() {
  local name=$1 mv=$2 sb=$work/sb ok
  mksb "$sb"
  local files=("sub/f.cpp" "f.cpp" "nosuch.h" "link/f.cpp" "afile/x" "/x" "my dir/a b.cpp" "" "flink.cpp" "@SB@/sub/f.cpp")
  files=("${files[@]//@SB@/$sb}")
  (
    # the frozen loop reads preinc and moves, as the driver has them; it is run as it is
    cd "$sb" && source "$work/fn.sh" && moves=$mv && preinc=("${files[@]}") && source "$work/loop.sh"
    if [ ${#pre_opts[@]} -gt 0 ]; then printf '%s\0' "${pre_opts[@]}"; fi
  ) > "$work/b.out"
  planner_pairs "$sb" "$mv" "${files[@]}" > "$work/r.out" || { check "forced includes: $name" 1; return; }
  cmp -s "$work/b.out" "$work/r.out"; ok=$?
  check "forced includes: $name" "$ok"
  [ "$ok" = 0 ] || { echo "  bash: $(tr '\0' '|' < "$work/b.out")"; echo "  ruby: $(tr '\0' '|' < "$work/r.out")"; }
}

forced_case "moves=0: the names as given" 0
forced_case "moves=1: the existing files made absolute" 1

echo "driver-abspath: $pass passed, $fail failed"
[ "$fail" = 0 ]

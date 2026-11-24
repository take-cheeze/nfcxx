#!/bin/bash
# Test of the absolute paths the driver makes with abs_path: the forced includes (-include FILE) and the -I directories, and
# of abs_path itself. The driver calls scripts/host-sys.rb's abs_path (the bash function is retired):
#   "${RUBY:-ruby}" "$root/scripts/host-sys.rb" abs_path "$x"
# inside $(...), so trailing newlines go, as the bash did. The expected values of the abs_path cases are the bash function's
# results, recorded from the frozen driver before it was retired (run as a non-root user, for the case without search
# permission). Each case is checked against the driver's call and against scripts/ecp-arg.rb's EcpArg.abs. The forced-include
# loop is the driver's own, as pinned in forced-include-loop.sh and run as it is; the --preinclude options are checked against scripts/nfcxx-eccp-plan.rb, which
# plans them from the preinc group (its records come from nfcxx's own state_put). Each case runs in a sandbox with a directory,
# a symbolic link to it, a file, a symbolic link to a file, a directory name with a space, and a file where a directory is
# expected; the case without search permission is skipped as root, where that permission check cannot be reproduced.
#   bash tests/driver-abspath/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0; skip=0
# the two snippets of the driver are pinned copies, recorded from tests/driver-body/nfcxx-bash at origin/main with
#   sed -n '/^pre_opts=(); for f in/,/^done$/p' > forced-include-loop.sh
#   sed -n '/^state_put() {/,/^}/p' > state-put.sh
# so the frozen body can be deleted without changing what this suite checks
cp "$here/forced-include-loop.sh" "$work/loop.sh"
[ -s "$work/loop.sh" ] || { echo "driver-abspath: no forced-include loop in the pinned copy" >&2; exit 2; }
grep -q 'scripts/host-sys.rb" abs_path' "$work/loop.sh" || { echo "driver-abspath: the pinned loop does not call host-sys.rb abs_path" >&2; exit 2; }
cp "$here/state-put.sh" "$work/state.sh"
[ -s "$work/state.sh" ] || { echo "driver-abspath: no state_put in the pinned copy" >&2; exit 2; }
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

# abs_case NAME ARG WANT: in the sandbox $work/sb (already made), ARG (@SB@ is the sandbox) as the driver's call and EcpArg
# see it; WANT is the bash function's result, with the sandbox's real path written @SB@
abs_case() {
  local name=$1 arg=$2 want=$3 sb=$work/sb real got ecp ok
  arg=${arg//@SB@/$sb}
  real=$(cd "$sb" && pwd -P)
  got=$(cd "$sb" && "${RUBY:-ruby}" "$repo/scripts/host-sys.rb" abs_path "$arg"); got=${got//$real/@SB@}
  ecp=$(cd "$sb" && "$ruby_bin" -I "$repo/scripts" -r ecp-arg -e 'print EcpArg.substitution(EcpArg.abs(ARGV[0]))' -- "$arg")
  ecp=${ecp//$real/@SB@}
  ok=1; [ "$got" = "$want" ] && [ "$ecp" = "$want" ] && ok=0
  check "abs_path: $name" "$ok"
  [ "$ok" = 0 ] || { echo "  want:     $want"; echo "  host-sys: $got"; echo "  ecp-arg:  $ecp"; }
}

fn_case() {  # fn_case NAME ARG WANT
  mksb "$work/sb"
  abs_case "$@"
}

# a directory that exists but has no search permission: bash's cd fails there, so the argument is printed unchanged. The
# permission check cannot be reproduced as root (root searches every directory), so the case is skipped then.
perm_case() {
  local sb=$work/sb
  mksb "$sb"; mkdir "$sb/noexec"; printf 'x\n' > "$sb/noexec/f.cpp"; chmod 600 "$sb/noexec"
  if [ "$(id -u)" = 0 ]; then
    echo "skip abs_path: a directory without search permission (running as root: the permission check cannot be reproduced)"
    skip=$((skip + 1))
  else
    abs_case "a directory without search permission" "noexec/f.cpp" "noexec/f.cpp"
  fi
  chmod 700 "$sb/noexec"   # so the sandbox can be removed
}

fn_case "relative file in a directory" "sub/f.cpp" "@SB@/sub/f.cpp"
fn_case "absolute path" "@SB@/sub/f.cpp" "@SB@/sub/f.cpp"
fn_case "missing directory" "nodir/f.cpp" "nodir/f.cpp"
fn_case "absolute missing directory" "/nosuch/dir/x.h" "/nosuch/dir/x.h"
fn_case "symbolic-link directory" "link/f.cpp" "@SB@/sub/f.cpp"
fn_case "symbolic link to a symbolic link" "link2/f.cpp" "@SB@/sub/f.cpp"
fn_case "root-level path" "/x" "//x"
fn_case "root directory" "/" "///"
fn_case "trailing slash" "sub/" "@SB@/sub"
fn_case "bare file name in the current directory" "f.cpp" "@SB@/f.cpp"
fn_case "dot" "." "@SB@/."
fn_case "dot-dot" ".." "@SB@/.."
fn_case "dot-dot in the middle" "sub/../sub/f.cpp" "@SB@/sub/f.cpp"
fn_case "a file where a directory is expected" "afile/x" "afile/x"
fn_case "symbolic link to a file, as the base name" "flink.cpp" "@SB@/flink.cpp"
fn_case "a directory name with a space" "my dir/a b.cpp" "@SB@/my dir/a b.cpp"
fn_case "empty argument" "" "@SB@/"
perm_case

# forced_case NAME MOVES: the frozen loop's pre_opts (run as the driver runs it) against the planner's --preinclude pairs
forced_case() {
  local name=$1 mv=$2 sb=$work/sb ok
  mksb "$sb"
  local files=("sub/f.cpp" "f.cpp" "nosuch.h" "link/f.cpp" "afile/x" "/x" "my dir/a b.cpp" "" "flink.cpp" "@SB@/sub/f.cpp")
  files=("${files[@]//@SB@/$sb}")
  (
    # the frozen loop reads preinc, moves and root, as the driver has them; it is run as it is
    cd "$sb" && root=$repo && moves=$mv && preinc=("${files[@]}") && source "$work/loop.sh"
    if [ ${#pre_opts[@]} -gt 0 ]; then printf '%s\0' "${pre_opts[@]}"; fi
  ) > "$work/b.out"
  planner_pairs "$sb" "$mv" "${files[@]}" > "$work/r.out" || { check "forced includes: $name" 1; return; }
  cmp -s "$work/b.out" "$work/r.out"; ok=$?
  check "forced includes: $name" "$ok"
  [ "$ok" = 0 ] || { echo "  driver: $(tr '\0' '|' < "$work/b.out")"; echo "  planner: $(tr '\0' '|' < "$work/r.out")"; }
}

forced_case "moves=0: the names as given" 0
forced_case "moves=1: the existing files made absolute" 1

echo "driver-abspath: $pass passed, $fail failed${skip:+, $skip skipped}"
[ "$fail" = 0 ]

#!/bin/bash
# Differential test of nfcxx's dependency file command (the -MD/-MMD block of the driver): the bash block verbatim (pinned in
# pinned-bash-block.txt, copied from the frozen driver before its switch to the plan) against the block of the driver body
# (tests/driver-body/nfcxx-oracle.sh, pinned in pinned-depmode-block.txt), which calls scripts/nfcxx-depmode.rb plan and
# runs the command it prints. Both run with a stub compiler (NFCXX_CXX, or a g++ on PATH when NFCXX_CXX is unset) that logs its
# arguments NUL-separated and exits with STUB_RC. Each case compares the logs byte for byte and the status.
#   bash tests/driver-depmode/run.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0

block() { sed -n '/^if \[ -n "\$depmode" \]; then$/,/^fi$/p' "$1"; }
block "$here/pinned-bash-block.txt" > "$work/bash.sh"
block "$here/pinned-depmode-block.txt" > "$work/driver.sh"   # the plan block, pinned (see pinned-depmode-block.txt)
block "$repo/tests/driver-body/nfcxx-oracle.sh" > "$work/body.sh"
[ "$(wc -l < "$work/bash.sh")" = 7 ] || { echo "driver-depmode: the pinned bash block is not the seven lines of the frozen driver" >&2; exit 2; }
[ -s "$work/driver.sh" ] || { echo "driver-depmode: no depmode block in the pinned copy" >&2; exit 2; }
cmp -s "$work/driver.sh" "$work/body.sh" || { echo "driver-depmode: the driver body's depmode block is not the pinned plan block" >&2; exit 2; }

# the stub: logs its arguments, NUL-separated, to $NFCXX_STUB_LOG, then exits with $STUB_RC
bin=$work/bin; mkdir -p "$bin"
cat > "$bin/cxx-stub" <<'STUB'
#!/bin/bash
printf '%s\0' "$@" >> "$NFCXX_STUB_LOG"
exit "${STUB_RC:-0}"
STUB
cp "$bin/cxx-stub" "$bin/g++"
chmod +x "$bin/cxx-stub" "$bin/g++"

# run_one BLOCK LOG SETUP: runs BLOCK in a fresh shell (set -euo pipefail, as the driver) after SETUP, which sets the
# variables of the case; prints the block's status
run_one() {
  local block=$1 log=$2 setup=$3 st=0
  : > "$log"
  (
    set -euo pipefail
    export PATH="$bin:$PATH" NFCXX_STUB_LOG="$log" root="$repo"
    eval "$setup"
    . "$block"
  ) || st=$?
  echo "$st"
}

# case_ NAME SETUP: the same case through the bash block and the driver block; the logs and statuses must match
case_() {
  local name=$1 setup=$2 bst dst
  bst=$(run_one "$work/bash.sh" "$work/bash.log" "$setup")
  dst=$(run_one "$work/driver.sh" "$work/driver.log" "$setup")
  if [ -s "$work/bash.log" ] && cmp -s "$work/bash.log" "$work/driver.log" && [ "$bst" = "$dst" ]; then
    pass=$((pass + 1)); echo "ok   $name (status $bst)"
  else
    fail=$((fail + 1)); echo "FAIL $name (status bash $bst, driver $dst)"
    echo "  bash: $(tr '\0' ' ' < "$work/bash.log" 2>/dev/null)"
    echo "  port: $(tr '\0' ' ' < "$work/driver.log" 2>/dev/null)"
  fi
}

# the defaults of the cases (the variables the driver sets before the block); stub is the NFCXX_CXX of the case
export NFCXX_STUB_CXX=$bin/cxx-stub
base='depmode=-MD; dfile=; dtarget=; depphony=; out=m.o; std=--c++17; cflags=(); sysdirs=(); srcs=(m.cpp)'
stub='NFCXX_CXX="$NFCXX_STUB_CXX"'

case_ "default name: out with .d" "$stub; $base"
case_ "-MMD" "$stub; $base; depmode=-MMD"
case_ "out with a dot in the directory name" "$stub; $base; out=build.v2/m.o"
case_ "out without a suffix" "$stub; $base; out=obj"
case_ "out with a dot in its directory and no suffix" "$stub; $base; out=build.v2/m"
case_ "out with a trailing dot" "$stub; $base; out=a."
case_ "-MF and -MT given" "$stub; $base; dfile=deps/m.dep; dtarget=other.o"
case_ "-MF given, -MT not" "$stub; $base; dfile=deps/m.dep"
case_ "-MT given, -MF not" "$stub; $base; dtarget=lib.o; depmode=-MMD"
case_ "empty cflags and sysdirs" "$stub; $base; srcs=(a.cpp)"
case_ "several sources" "$stub; $base; srcs=(a.cpp b.cpp c.cpp)"
case_ "sysdirs present, cflags with spaces and an empty word" "$stub; $base; cflags=(-DX=1 '-DNAME=a b' ''); sysdirs=(/usr/include /opt/x y); srcs=(m.cpp)"
case_ "an empty sysdir gives -isystem alone" "$stub; $base; sysdirs=('' /x); srcs=(m.cpp)"
case_ "-std with a dash: --c++20" "$stub; $base; std=--c++20"
case_ "-std with a dash: --c++23 and -MMD" "$stub; $base; std=--c++23; depmode=-MMD"
case_ "depphony set (-MP)" "$stub; $base; depphony=-MP"
case_ "depphony -MP with -MMD, -MF and -MT" "$stub; $base; depphony=-MP; depmode=-MMD; dfile=x.d; dtarget=x.o; srcs=(a.cpp b.cpp)"
case_ "NFCXX_CXX unset: g++" "unset NFCXX_CXX; $base"
case_ "NFCXX_CXX empty: g++" "NFCXX_CXX=; $base"
case_ "the compiler fails: its status is the block's" "$stub; $base; export STUB_RC=3; cflags=(-O2)"

echo "driver-depmode: $pass passed, $fail failed"
[ "$fail" = 0 ]

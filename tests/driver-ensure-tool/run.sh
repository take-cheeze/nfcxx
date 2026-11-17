#!/bin/bash
# Differential test of nfcxx's ensure_tool: the bash function verbatim (from the frozen driver, tests/driver-body/nfcxx-bash)
# against scripts/nfcxx-ensure-tool.rb, in fresh sandboxes with a stub ninja on PATH. Each case compares the status, the
# ninja calls (arguments and CXX), and whether the lock directory is left behind. The stuck-lock error (3000 polls) is not
# run here: it takes 600 seconds.
#   bash tests/driver-ensure-tool/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
sed -n '/^ensure_tool() {/,/^}/p' "$repo/tests/driver-body/nfcxx-bash" > "$work/fn.sh"
[ -s "$work/fn.sh" ] || { echo "driver-ensure-tool: no ensure_tool in the frozen driver" >&2; exit 2; }
ruby_bin=$(command -v ruby)

# the sandbox: tools/t with a source from 1999, build/ for the output; the stub ninja logs its call and makes the output
mksb() {  # mksb DIR
  rm -rf "$1"; mkdir -p "$1/tools/t" "$1/build" "$1/bin"
  printf 'int main(){}\n' > "$1/tools/t/main.cpp"; touch -d 1999-01-01 "$1/tools/t/main.cpp"
  cat > "$1/bin/ninja" <<'STUB'
#!/bin/bash
echo "ninja $* CXX=${CXX-unset}" >> "$NFCXX_STUB_LOG"
[ "${STUB_RC:-0}" = 0 ] || { echo "ninja: build failed" >&2; exit "$STUB_RC"; }
: > "$STUB_OUT"; chmod +x "$STUB_OUT"
STUB
  chmod +x "$1/bin/ninja"
}

# run SIDE SB SETUP: SETUP is shell that runs in the sandbox before the call; prints the results
run() {
  local side=$1 sb=$2 setup=$3
  local log=$work/$side.log
  : > "$log"
  local dir=$sb/tools/t out=$sb/build/t
  (
    cd "$sb" || exit 1
    export PATH="$sb/bin:$PATH" NFCXX_STUB_LOG=$log STUB_OUT=$out
    mkout() { : > build/t; chmod +x build/t; }   # a built tool (shorthand for the setups)
    eval "$setup"
    if [ "$side" = bash ]; then
      source "$work/fn.sh"; ensure_tool "$dir" "$out"; rc=$?
    else
      "$ruby_bin" "$repo/scripts/nfcxx-ensure-tool.rb" "$dir" "$out"; rc=$?
    fi
    echo "rc $rc"
    echo "lock $( [ -d "$out.lock" ] && echo present || echo absent )"
    echo "out $( [ -x "$out" ] && echo executable || echo missing )"
    cat "$log"
  ) 2>&1 | sed -e "s#$sb#<sb>#g"
}

case_() {  # case_ NAME SETUP: the port and the bash must agree
  local name=$1 setup=$2 b t
  mksb "$work/sb"; b=$(run bash "$work/sb" "$setup")
  mksb "$work/sb"; t=$(run ruby "$work/sb" "$setup")
  if [ "$b" = "$t" ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name"; diff <(printf '%s\n' "$b") <(printf '%s\n' "$t") | head -12 | sed 's/^/  /'; fi
}

case_ "missing: built once" ""
case_ "fresh: no build" "mkout; touch -d 2001-01-01 build/t"
case_ "stale: a source is newer" "mkout; touch -d 2000-01-01 build/t; touch -d 2001-01-01 tools/t/main.cpp"
case_ "a header of the tool is newer too" "mkout; touch -d 2000-01-01 build/t; touch -d 2001-01-01 tools/t/x.h"
case_ "a file that is not a source is ignored" "mkout; touch -d 2001-01-01 build/t; touch -d 2002-01-01 tools/t/notes.txt"
case_ "ninja fails: its status, and the lock is removed" "export STUB_RC=3"
case_ "CXX from NFCXX_CXX" "export NFCXX_CXX=clang++"
case_ "an empty NFCXX_CXX is g++" "export NFCXX_CXX="
case_ "another run holds the lock and builds: wait, then find the tool" "mkdir build/t.lock; (sleep 0.5; mkout) &"

echo "driver-ensure-tool: $pass passed, $fail failed"
[ "$fail" = 0 ]

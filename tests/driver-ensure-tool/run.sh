#!/bin/bash
# Golden test of nfcxx's ensure_tool, the Ruby port scripts/nfcxx-ensure-tool.rb (the bash function it replaced is gone from
# the driver body). Each case runs the port in a fresh sandbox with a stub ninja on PATH and compares the result (the status,
# the ninja calls with their arguments and CXX, whether the lock directory is left behind, whether the output is executable)
# with goldens/<case>.txt, recorded from the bash function before it was removed. The stuck-lock error (3000 polls) is not
# run here: it takes 600 seconds.
#   bash tests/driver-ensure-tool/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ruby_bin=$(command -v ruby)

# the sandbox: tools/t with a source from 1999, build/ for the output; the stub ninja logs its call and makes the output
mksb() {  # mksb DIR
  rm -rf "$1"; mkdir -p "$1/tools/t" "$1/build" "$1/bin"
  printf 'int main(){}\n' > "$1/tools/t/main.cpp"; touch -d 1999-01-01 "$1/tools/t/main.cpp"
  cat > "$1/bin/ninja" <<'STUB'
#!/bin/bash
echo "ninja $* CXX=${CXX-unset}" >> "$NFCXX_STUB_LOG"
[ -z "${STUB_SIG:-}" ] || kill -"$STUB_SIG" $$
[ "${STUB_RC:-0}" = 0 ] || { echo "ninja: build failed" >&2; exit "$STUB_RC"; }
: > "$STUB_OUT"; chmod +x "$STUB_OUT"
STUB
  chmod +x "$1/bin/ninja"
}

# run SB SETUP: SETUP is shell that runs in the sandbox before the call; prints the results
run() {
  local sb=$1 setup=$2
  local log=$work/port.log
  : > "$log"
  local dir=$sb/tools/t out=$sb/build/t
  (
    cd "$sb" || exit 1
    export PATH="$sb/bin:$PATH" NFCXX_STUB_LOG=$log STUB_OUT=$out
    mkout() { : > build/t; chmod +x build/t; }   # a built tool (shorthand for the setups)
    eval "$setup"
    "$ruby_bin" "$repo/scripts/nfcxx-ensure-tool.rb" "$dir" "$out"; rc=$?
    echo "rc $rc"
    echo "lock $( [ -d "$out.lock" ] && echo present || echo absent )"
    echo "out $( [ -x "$out" ] && echo executable || echo missing )"
    cat "$log"
  ) 2>&1 | sed -e "s#$sb#<sb>#g"
}

case_() {  # case_ NAME SETUP: the port's result is the golden of the case
  local name=$1 setup=$2 slug gold t
  slug=$(printf '%s' "$name" | tr -cs 'a-zA-Z0-9' '-' | sed 's/-$//')
  gold=$here/goldens/$slug.txt
  [ -f "$gold" ] || { fail=$((fail + 1)); echo "FAIL $name (no golden $gold)"; return; }
  mksb "$work/sb"; t=$(run "$work/sb" "$setup")
  if [ "$t" = "$(cat "$gold")" ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name"; diff "$gold" <(printf '%s\n' "$t") | head -12 | sed 's/^/  /'; fi
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
# ninja not on PATH: the port's status is 127 (bash's stderr line "command not found" is not reproduced: the port prints nothing)
case_ "ninja not on PATH: status 127" 'mkdir -p "$sb/nobin"; ln -s "$(command -v cat)" "$sb/nobin/cat"; PATH=$sb/nobin'
# ninja killed by a signal: the port's status is 1 (bash would give 128+N)
case_ "ninja killed by a signal: status 1" "export STUB_SIG=TERM"

echo "driver-ensure-tool: $pass passed, $fail failed"
[ "$fail" = 0 ]

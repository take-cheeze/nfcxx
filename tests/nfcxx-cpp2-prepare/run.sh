#!/bin/bash
# The pinned copy (pinned-nfcxx.txt) was taken from the driver at commit 1aa750d8b52163609481ea3cb4ad631389529a7b, before the B8 switch.
# Differential test of nfcxx's cpp2_prepare: the port (the thin bash function of nfcxx, which runs scripts/nfcxx-cpp2.rb)
# against tests/nfcxx-cpp2-prepare/oracle.sh (the bash before the port, verbatim). cppfront is a stub that logs its arguments
# and writes its -o file, or fails for an input whose name has "fail". Each case runs in its own sandbox, once per side. The
# arrays, the translations, the stub's log, the status and the standard error must be the same (paths normalized).
#   bash tests/nfcxx-cpp2-prepare/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ruby_bin=$(command -v ruby)
sed -n '/^state_put() {/,/^}/p' "$here/pinned-nfcxx.txt" > "$work/thin.sh"
sed -n '/^cpp2_prepare() {/,/^}/p' "$here/pinned-nfcxx.txt" >> "$work/thin.sh"
[ -s "$work/thin.sh" ] || { echo "nfcxx-cpp2-prepare: no cpp2_prepare in nfcxx" >&2; exit 2; }

# the sandbox: a root with a stub cppfront and the header, the repository's scripts, and the source files
mksb() {  # mksb DIR
  local sb=$1
  rm -rf "$sb"; mkdir -p "$sb/build/cppfront-src/include" "$sb/src" "$sb/sub" "$sb/obj" "$sb/tmp"
  ln -s "$repo/scripts" "$sb/scripts"
  : > "$sb/build/cppfront-src/include/cpp2util.h"
  cat > "$sb/build/cppfront" <<'STUB'
#!/bin/bash
echo "CALL $* (cwd $(basename "$PWD"))" >> "$NFCXX_STUB_LOG"
last=${!#}; out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
case $last in *fail*) echo "cppfront: stub failure for $last" >&2; exit 3 ;; esac
printf '// translated from %s\n' "$last" > "$out"
STUB
  chmod +x "$sb/build/cppfront"
  : > "$sb/src/a.cpp2"; : > "$sb/sub/b.cpp2"; : > "$sb/z.cpp2"; : > "$sb/src/fail.cpp2"
}

# run SIDE SB SETUP: runs cpp2_prepare on the side's copy of the function in sandbox SB, then prints the state
run() {
  local side=$1 sb=$2 setup=$3 src
  src=$here/oracle.sh; [ "$side" = thin ] && src=$work/thin.sh
  local log=$work/$side.stublog; : > "$log"
  local prelude="set -euo pipefail; root=$sb; RUBY=$ruby_bin; NFCXX_STUB_LOG=$log; export NFCXX_CU_CACHE=$sb/cache; source $src"
  local err rc
  err=$( cd "$sb" && bash -c "$prelude; cudatmp=$sb/tmp; $setup; cpp2_prepare; echo \"srcs \${srcs[*]:-}\"; echo \"files \${files[*]:-}\"; echo \"cflags \${cflags[*]:-}\"; for f in \${cpp2_copies_seen[@]:-}; do :; done" 2>&1 >"$work/$side.out"); rc=$?
  { printf 'status %s\n' "$rc"; cat "$work/$side.out"; printf 'stderr %s\n' "$err"; echo "stub:"; cat "$log"; } \
    | sed -e "s#$sb#<sb>#g" -e 's#/tmp/tmp\.[A-Za-z0-9]*#<tmp>#g' -e 's#tmp\.[A-Za-z0-9]\{6,\}#<tmp>#g'
  ( cd "$sb" && find . -path ./build -prune -o -path ./scripts -prune -o -path ./tmp -prune -o -mindepth 1 -type f -print0 | sort -z | xargs -0 -I{} sh -c 'echo "{}: $(cat "{}")"' ) 2>/dev/null | sed -e 's#/tmp/tmp\.[A-Za-z0-9]*#<tmp>#g'
}

pass=0; fail=0
case_() {  # case_ NAME SETUP: the port and the bash must agree
  local name=$1 setup=$2 b t
  mksb "$work/sb"; b=$(run oracle "$work/sb" "$setup")
  mksb "$work/sb"; t=$(run thin "$work/sb" "$setup")
  if [ "$b" = "$t" ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name"; diff <(printf '%s\n' "$b") <(printf '%s\n' "$t") | sed 's/^/  /' | head -20; fi
}

case_ "one input, no -c" 'cpp2_inputs=(src/a.cpp2); srcs=(src/a.cpp2); files=(src/a.cpp2); cflags=(-DX); compile_only=0; out=a.out; outset=0; ncpp=1'
case_ "two inputs in two directories, and a C++ source" 'cpp2_inputs=(src/a.cpp2 sub/b.cpp2); srcs=(src/a.cpp2 sub/b.cpp2 c.cc); files=(src/a.cpp2 sub/b.cpp2 c.cc); cflags=(); compile_only=0; out=a.out; outset=0; ncpp=2'
case_ "-c with -o: the translations go to the cache" 'cpp2_inputs=(src/a.cpp2); srcs=(src/a.cpp2); files=(src/a.cpp2); cflags=(); compile_only=1; out=obj/prog.o; outset=1; ncpp=1'
case_ "-c without -o: the object is named after the input" 'cpp2_inputs=(src/a.cpp2); srcs=(src/a.cpp2); files=(); cflags=(); compile_only=1; out=a.out; outset=0; ncpp=1'
case_ "cppfront fails: the driver stops with its status, the later inputs are not run" 'cpp2_inputs=(src/fail.cpp2 z.cpp2); srcs=(src/fail.cpp2 z.cpp2); files=(); cflags=(); compile_only=0; out=a.out; outset=0; ncpp=2'
case_ "a source directory that does not exist" 'cpp2_inputs=(nodir/a.cpp2); srcs=(nodir/a.cpp2); files=(); cflags=(); compile_only=0; out=a.out; outset=0; ncpp=1'
case_ "a bare file name (its directory is the root)" 'cpp2_inputs=(z.cpp2); srcs=(z.cpp2); files=(); cflags=(); compile_only=0; out=a.out; outset=0; ncpp=1'

# the cache directory of a -c compile (the bash's key was the SHA-1 of realpath -m OBJ, through sha1sum): the port's directory
# must equal the bash's for objects that exist, do not exist, sit under a symbolic link and have a relative name
ln -s "$work" "$work/link"
keys_ok=1
for obj in "$work/sb/obj/prog.o" "$work/no/such/dir/x.o" "$work/link/sb/obj/prog.o" "rel/x.o" "./a.o"; do
  want=$(NFCXX_CU_CACHE=$work/cache sh -c 'realpath -m "$1" | sha1sum | cut -c1-16' sh "$obj")
  got=$(NFCXX_CU_CACHE=$work/cache ruby "$repo/scripts/nfcxx-cpp2.rb" --cpp2-dir="$obj")
  [ "$got" = "$work/cache/cpp2/$want" ] || { keys_ok=0; echo "  cpp2-dir: $obj: got $got, want $work/cache/cpp2/$want"; }
done
if [ "$keys_ok" = 1 ]; then pass=$((pass + 1)); echo "ok   cpp2-dir key matches realpath -m | sha1sum"
else fail=$((fail + 1)); echo "FAIL cpp2-dir key matches realpath -m | sha1sum"; fi
# the default cache (no NFCXX_CU_CACHE): XDG_CACHE_HOME, then HOME/.cache
a=$(env -u NFCXX_CU_CACHE XDG_CACHE_HOME=/x/c ruby "$repo/scripts/nfcxx-cpp2.rb" --cpp2-dir=o.o)
b=$(env -u NFCXX_CU_CACHE -u XDG_CACHE_HOME HOME=/x/h ruby "$repo/scripts/nfcxx-cpp2.rb" --cpp2-dir=o.o)
if [ "$a" = "/x/c/nfcxx/cpp2/${a##*/}" ] && [ "$b" = "/x/h/.cache/nfcxx/cpp2/${b##*/}" ]; then pass=$((pass + 1)); echo "ok   cpp2-dir default cache"
else fail=$((fail + 1)); echo "FAIL cpp2-dir default cache: $a $b"; fi

echo "cpp2-prepare: $pass passed, $fail failed"
[ "$fail" = 0 ]

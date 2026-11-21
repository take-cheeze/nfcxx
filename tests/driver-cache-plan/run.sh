#!/bin/bash
# The compile cache's lookup arguments, planned by scripts/nfcxx-cache-plan.rb (cache_plan in tests/driver-body/nfcxx-bash). The
# bash cache_check before the change (pinned-old-cache-check.txt, verbatim) and the cache_check of the frozen body now are run on
# the same state. A stub ruby records the arguments of the lookup call (the planner is the real one), so the two must pass the
# same arguments, byte for byte, and the same stderr. Also checked: the planner's own record kinds.
#   bash tests/driver-cache-plan/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
ruby_bin=$(command -v ruby)

# the stub: the planner runs for real; the lookup call records its arguments (NUL-separated) and exits 1 (no decision)
cat > "$work/ruby-stub" <<EOF
#!/bin/bash
case "\$1" in *nfcxx-cache-plan.rb) exec "$ruby_bin" "\$@";; esac
printf '%s\0' "\$@" > "\$CAPTURE"
exit 1
EOF
chmod +x "$work/ruby-stub"

# the two functions: the pinned old cache_check, and cache_plan and cache_check of the frozen body
sed -n '/^cache_plan() {/,/^}/p; /^cache_check() {/,/^}/p' "$repo/tests/driver-body/nfcxx-bash" > "$work/new.sh"
cp "$here/pinned-old-cache-check.txt" "$work/old.sh"

# run_case NAME FILE: the state of the case (set by the caller), then cache_check of FILE; the lookup's arguments go to $work/NAME.bin
run_case() {  # run_case NAME FILE
  local name=$1 file=$2
  (
    cd "$work" || exit 1
    root=$repo; out=$OUT; cache_dir=$CACHE_DIR; cache_log_file=$CACHE_LOG
    backend=$BACKEND; compile_only=1; ncpp=$NCPP; outset=1; nobj=1; modules=0; preprocess=0; stdin_src=0; depmode=none
    srcs=(${SRCS[@]+"${SRCS[@]}"}); nfcxx_argv=(${ARGV[@]+"${ARGV[@]}"}); std=$STD
    cflags=(${CFLAGS[@]+"${CFLAGS[@]}"}); preinc=(${PREINC[@]+"${PREINC[@]}"}); sysdirs=(${SYSDIRS[@]+"${SYSDIRS[@]}"})
    cfiles=(); cu_inputs=(); cpp2_inputs=()
    export CAPTURE="$work/$name.bin"
    RUBY="$work/ruby-stub"
    . "$file"
    cache_check
  ) 2> "$work/$name.err"
}

# same NAME: the arguments of the old and the new cache_check are equal (and the stderr)
check_same() {  # check_same NAME
  local name=$1
  rm -f "$work/$name.bin"; run_case "$name" "$work/old.sh"; mv -f "$work/$name.bin" "$work/$name.old" 2>/dev/null
  mv -f "$work/$name.err" "$work/$name.errold"
  rm -f "$work/$name.bin"; run_case "$name" "$work/new.sh"; mv -f "$work/$name.bin" "$work/$name.new" 2>/dev/null
  if [ -f "$work/$name.old" ] && cmp -s "$work/$name.old" "$work/$name.new" && [ -f "$work/$name.new" ] \
     && cmp -s "$work/$name.errold" "$work/$name.err"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name"
    echo "  old: $(tr '\0' '|' < "$work/$name.old" 2>/dev/null)"
    echo "  new: $(tr '\0' '|' < "$work/$name.new" 2>/dev/null)"
  fi
}

# the planner on its own: the records (| stands for NUL) give the options (| stands for NUL), and status 0
expect_plan() {  # expect_plan WANT RECORDS
  local got st
  got=$(set -o pipefail; printf '%s' "$2" | tr '|' '\0' | "$ruby_bin" "$repo/scripts/nfcxx-cache-plan.rb" | tr '\0' '|'); st=$?
  if [ "$got" = "$1" ] && [ "$st" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL plan $2: got '$got' status $st, want '$1'"; fi
}

# 1: a full compile (the flags, the forced include, a sysdir, the cache options left out of the key)
OUT=m.o CACHE_DIR=$work/cache CACHE_LOG=$work/log BACKEND=gcc NCPP=1 SRCS=(m.cpp) STD=--c++17
ARGV=(-c m.cpp -o m.o --cache=x --cache-log=y --time-log=z --trace=w -DA=b\ c)
CFLAGS=(-DX=1 "-DNAME=a b") PREINC=(pre.h) SYSDIRS=(/usr/include)
check_same full

# 2: nothing but the defaults: no arguments, no sources, no flags, an empty cache log
OUT=a.o CACHE_DIR=$work/cache2 CACHE_LOG= BACKEND=pathb NCPP=0 SRCS=() STD=--c++11
ARGV=() CFLAGS=() PREINC=() SYSDIRS=()
check_same bare

# 3: a cache option only (dropped), two forced includes and two sysdirs, a Path B backend
OUT=b.o CACHE_DIR=$work/cache3 CACHE_LOG=$work/log3 BACKEND=pathb NCPP=2 SRCS=(a.cpp b.cpp) STD=--c++14
ARGV=(--cache-log=q -c a.cpp) CFLAGS=(-O2) PREINC=(p1.h p2.h) SYSDIRS=(/a /b)
check_same multi

# the planner's records, one case per kind
expect_plan '--file=x|' 'ofile=x|'
expect_plan '--cache-dir=d|--out=o|' 'ocache-dir=d|oout=o|'
expect_plan '--var=n=1|' 'vn=1|'
expect_plan '--arg=-c|' 'a-c|'
expect_plan '' 'a--cache=x|'
expect_plan '--cpp=-std=c++17|' 's--c++17|'
expect_plan '--cpp=-O2|' 'f-O2|'
expect_plan '--cpp=-include|--cpp=p.h|' 'pp.h|'
expect_plan '--cpp=-isystem/x|' 'd/x|'
expect_plan '' ''
# an unknown record kind is a usage error: status 2, nothing printed
got=$(printf 'x1\0' | "$ruby_bin" "$repo/scripts/nfcxx-cache-plan.rb" 2>/dev/null); st=$?
if [ -z "$got" ] && [ "$st" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL plan: unknown kind status $st"; fi

echo "driver-cache-plan: $pass passed, $fail failed"
[ "$fail" = 0 ]

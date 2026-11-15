#!/bin/bash
# Differential test of the launcher ports (scripts/nfcxx-cpp.rb, nfcxx-ast-dump.rb, libclang-cursors.rb,
# build-libclang-edg.rb) against their bash originals (tests/launch/oracle/*.sh). Each case runs both with the same
# arguments and environment in one scratch tree, so the root and every path are the same for both: scripts/ holds
# symlinks to the bash original (under its own name) and to the Ruby port, build/ holds a fake front end (cpfe) and
# the fake compilers stand in for cc, c++ and the host C++ compiler. Each side's stdout, stderr, exit status and the
# files it left under build/ and work/ must match. Lines of the table: tool|name|mode|env|args
#   mode "=": all four must match; "~": the status, stdout and the files must match, and stderr must be non-empty on
#   both sides or on neither (bash's own messages for a failing `cd` or an unset $2 are not reproduced).
# Test-control variables in env (T_*) are not passed to the tools: T_NOCPFE (no fake front end), T_ARCHIVE (the
# front-end archive), T_PRE (run the tool once first), T_SO (the library's mtime, e.g. 2100-01-01), T_PRE_TI (a
# .ti file already there), T_NOLIB (no lib/ sources). @ROOT@ and @BIN@ are the scratch tree and the fake compilers.
#
#   bash tests/launch/run.sh
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
root=$work/root
bin=$work/bin
rubydir=$(dirname "$(command -v ruby)")
path=$bin:/usr/bin:/bin:$rubydir
tools=(nfcxx-cpp nfcxx-ast-dump libclang-cursors build-libclang-edg)
mkdir -p "$bin" "$work/fake" "$work/o"

# the host compiler: --version, -dumpfullversion and the search list of "-E -x LANG -v -" (GCC 13.3)
cat > "$bin/gnu" <<'EOF'
#!/bin/bash
case " $* " in
  *" --version "*) echo "g++ (GCC) 13.3.0"; echo "Copyright (C) 2023" ;;
  *" -dumpfullversion "*) echo 13.3.0 ;;
  *" -E "*) { echo '#include <...> search starts here:'; echo ' /fake/c++/13'; echo ' /fake/include';
              echo ' /fake/framework (framework directory)'; echo 'End of search list.'; } >&2 ;;
esac
EOF
# a clang with no -dumpfullversion (Apple's): no GNU version
cat > "$bin/clang21" <<'EOF'
#!/bin/bash
case " $* " in
  *" --version "*) echo "Apple clang version 21.0.0 (clang-2100.0.123.5)" ;;
  *" -dumpfullversion "*) echo "clang: error: no input files" >&2; exit 1 ;;
  *" -E "*) { echo '#include <...> search starts here:'; echo ' /fake/libcxx'; echo 'End of search list.'; } >&2 ;;
esac
EOF
# the C and C++ compilers of build-libclang-edg: log the call, fail on a missing C source, create the -o file
cat > "$bin/cc" <<'EOF'
#!/bin/bash
echo "$(basename "$0") $*" >> "$CALLS"
[ -n "${FAKE_CC_FAIL:-}" ] && exit 1
out=""; prev=""
for a in "$@"; do
  [ "$prev" = -o ] && out=$a
  case $a in *.c) [ -e "$a" ] || { echo "$(basename "$0"): $a: No such file" >&2; exit 1; } ;; esac
  prev=$a
done
[ -n "$out" ] && : > "$out"
exit 0
EOF
cp "$bin/cc" "$bin/cxx"
# the fake front end: echoes its environment and arguments; rejects an input that contains REJECT; a missing C-family
# input is an error; -M prints make's header lines; FAKE_EXIT sets its status; FAKE_TI writes stem.ti in its directory
cat > "$work/fake/cpfe" <<'EOF'
#!/bin/bash
for a in "$@"; do
  case $a in *.c|*.cpp|*.cc|*.h) [ -e "$a" ] || { echo "fake cpfe: $a: no such file" >&2; exit 1; } ;; esac
  if [ -f "$a" ] && grep -q REJECT "$a"; then echo "fake cpfe: $a: rejected" >&2; exit 1; fi
done
echo "cwd=$(pwd -P)"
echo "NFCXX_DECL_AST=${NFCXX_DECL_AST-unset}"
echo "EDG_BASE=${EDG_BASE-unset}"
if [[ " $* " == *" -M "* ]]; then
  echo "junk.o: /fake/one.h"; echo "junk.o: rel.h"; echo "junk.o: /fake/two space.h"
  exit "${FAKE_EXIT:-0}"
fi
for a in "$@"; do echo "arg=$a"; done
echo '# 1 "fake.h"'; echo 'int fake_decl;'; echo '# not a marker'
if [ -n "${FAKE_TI:-}" ]; then s=$(basename "${@: -1}"); s=${s%.*}; : > "$s.ti"; fi
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$bin"/* "$work/fake/cpfe"

# the scratch tree of one run: the tools, the fake front ends, the inputs
fresh_root() {
  rm -rf "$root"
  mkdir -p "$root/scripts" "$root/work/inc" "$root/build/edg/bin" "$root/build/edg-base" \
    "$root/build/libclang-edg/cmake/bin" "$root/build/libclang-edg/edg-base"
  for f in launch.rb host-sys.rb nfcxx-cpp.rb nfcxx-ast-dump.rb libclang-cursors.rb build-libclang-edg.rb; do
    ln -s "$repo/scripts/$f" "$root/scripts/$f"
  done
  for t in "${tools[@]}"; do ln -s "$repo/tests/launch/oracle/$t.sh" "$root/scripts/$t"; done
  [ -n "${T_NOLIB:-}" ] || ln -s "$repo/lib" "$root/lib"
  if [ -z "${T_NOCPFE:-}" ]; then
    cp "$work/fake/cpfe" "$root/build/edg/bin/cpfe"
    cp "$work/fake/cpfe" "$root/build/libclang-edg/cmake/bin/cpfe"
  fi
  if [ -n "${T_ARCHIVE:-}" ]; then
    mkdir -p "$root/build/libclang-edg/cmake/src/nfcxx-so"
    : > "$root/build/libclang-edg/cmake/src/nfcxx-so/libedgfe-pic.a"
  fi
  [ -n "${T_PRE_TI:-}" ] && : > "$root/build/libclang-edg/edg-base/$T_PRE_TI"
  printf 'int x;\n' > "$root/work/x.c"
  printf 'int x;\n' > "$root/work/x.cpp"
  printf 'int y;\n' > "$root/work/y.cpp"
  printf 'REJECT\n' > "$root/work/REJECT.c"
  printf 'REJECT\n' > "$root/work/REJECT.cpp"
  printf 'int pre;\n' > "$root/work/pre.h"
  : > "$root/work/inc/h.h"
}

# run one tool once, on one side (bash or ruby), in the scratch tree's work/ directory
invoke() { # side tool
  local cmd
  if [ "$1" = bash ]; then cmd=("$root/scripts/$2"); else cmd=(ruby "$root/scripts/$2.rb"); fi
  (cd "$root/work" && env -i PATH="$path" HOME="$work" "${BASE_ENV[@]}" ${ENVS[@]+"${ENVS[@]}"} \
    "${cmd[@]}" ${ARGS[@]+"${ARGS[@]}"} </dev/null)
}

# run one side of a case into $work/o/<side>: stdout, stderr, status and the files left under build/ and work/
run_side() { # side tool
  local od=$work/o/$1
  rm -rf "$od"; mkdir -p "$od"
  fresh_root
  [ -n "${T_PRE:-}" ] && invoke "$1" "$2" >/dev/null 2>&1
  if [ -n "${T_SO:-}" ]; then
    local so=$root/build/libclang-edg/libclang-edg.so
    [ -e "$so" ] || : > "$so"
    touch -d "$T_SO" "$so"
  fi
  invoke "$1" "$2" >"$od/stdout" 2>"$od/stderr"
  echo $? > "$od/status"
  { cat "$root/calls.log" 2>/dev/null
    (cd "$root" && find build work | LC_ALL=C sort | while IFS= read -r p; do
       echo "== $p"; [ -f "$p" ] && cat "$p"; done); } > "$od/state"
  # the Ruby port's runner and script names are the bash ones with .rb: map them back for comparison
  if [ "$1" = ruby ]; then
    sed -i 's/libclang-cursors\.rb/libclang-cursors/g; s/build-libclang-edg\.rb/build-libclang-edg.sh/g' "$od"/*
  fi
}

pass=0; fail=0; line_no=0
cases=$(cat <<'TABLE'
# nfcxx-cpp: the fake front end under build/edg; EDG_BASE and the host probes as the tool sets them
nfcxx-cpp|c-P|=|-|-P x.c
nfcxx-cpp|c-markers|=|-|x.c
nfcxx-cpp|cpp-std17-I-D|=|-|-std=c++17 -I inc -DFOO=1 -D BAR=2 -P y.cpp
nfcxx-cpp|cpp-gnu20-x|=|-|-x c++ -std=gnu++20 x.c
nfcxx-cpp|c-x-cpp-std-ignored|=|-|-x c -std=c++17 y.cpp
nfcxx-cpp|cpp-std-unknown|=|-|-std=c++2b y.cpp
nfcxx-cpp|xc-attached|=|-|-xc x.cpp
nfcxx-cpp|c-std11|=|-|-std=c11 x.c
nfcxx-cpp|passthrough-opts|=|-|-Wall -O2 -P y.cpp
nfcxx-cpp|include-opt|=|-|-include pre.h -P y.cpp
nfcxx-cpp|no-file|=|-|-P
nfcxx-cpp|missing-input|=|-|-P nope.c
nfcxx-cpp|reject|=|-|REJECT.c
nfcxx-cpp|reject-P|=|-|-P REJECT.c
nfcxx-cpp|cpfe-status-P|=|FAKE_EXIT=3|-P x.c
nfcxx-cpp|cpfe-status-raw|=|FAKE_EXIT=4|x.c
nfcxx-cpp|edg-base-env|=|EDG_BASE=/custom/base|-P x.c
nfcxx-cpp|edg-base-empty|=|EDG_BASE=|x.c
nfcxx-cpp|sys-override|=|NFCXX_SYS_INCLUDES=/x/one:/x/two:|x.cpp
nfcxx-cpp|no-gnu-clang|=|NFCXX_CXX=@BIN@/clang21|y.cpp
nfcxx-cpp|cpfe-env-missing|=|CPFE=/no/such/cpfe|x.c
nfcxx-cpp|cpfe-default-missing|=|T_NOCPFE=1|x.c
nfcxx-cpp|missing-arg-I|~|-|x.c -I
nfcxx-cpp|missing-arg-x|~|-|x.c -x
# nfcxx-ast-dump: the fake front end under build/libclang-edg (base build/libclang-edg/edg-base)
nfcxx-ast-dump|c-default|=|-|x.c
nfcxx-ast-dump|c-gnu99|=|-|-std=gnu99 x.c
nfcxx-ast-dump|c-c17|=|-|-std=c17 x.c
nfcxx-ast-dump|c-c23|=|-|-std=c2x x.c
nfcxx-ast-dump|c-gnu89|=|-|-std=gnu89 x.c
nfcxx-ast-dump|cpp-default|=|-|x.cpp
nfcxx-ast-dump|cpp-gnu20-x|=|-|-std=gnu++20 -x c++ x.c
nfcxx-ast-dump|cpp-opts|=|-|-std=c++14 -I inc -isystem inc -DA=1 -UB -include pre.h -Wall -O2 -fno-rtti x.cpp
nfcxx-ast-dump|opts-attached|=|-|-Iinc -isysteminc -DC=2 -UD -Wno-x x.cpp
nfcxx-ast-dump|deps|=|-|-MD -MF dep.d -MT t -o out.o x.cpp
nfcxx-ast-dump|no-input|=|-|-std=c++17
nfcxx-ast-dump|missing-input|=|-|nope.cpp
nfcxx-ast-dump|reject|=|-|REJECT.cpp
nfcxx-ast-dump|reject-first|=|-|REJECT.c x.cpp
nfcxx-ast-dump|multi|=|-|x.c y.cpp
nfcxx-ast-dump|ti-cleanup|=|FAKE_TI=1|x.cpp
nfcxx-ast-dump|ti-kept|=|FAKE_TI=1 T_PRE_TI=x.ti|x.cpp
nfcxx-ast-dump|status|=|FAKE_EXIT=5|x.c
nfcxx-ast-dump|o-at-end|=|-|x.cpp -o
nfcxx-ast-dump|cpfe-env-missing|=|LIBCLANG_EDG_CPFE=/no/such/cpfe|x.c
nfcxx-ast-dump|cpfe-default-missing|=|T_NOCPFE=1|x.c
nfcxx-ast-dump|base-missing|~|LIBCLANG_EDG_BASE=/no/such/base|x.c
nfcxx-ast-dump|missing-arg-x|~|-|-x
nfcxx-ast-dump|missing-arg-MF|~|-|x.cpp -MF
# libclang-cursors: the same front end as nfcxx-ast-dump, with the library's options
libclang-cursors|cpp-default|=|-|x.cpp
libclang-cursors|c-mode|=|-|--c x.c
libclang-cursors|std-I-D|=|-|-std=c++20 -I inc -DA=1 -UB -Wall x.cpp
libclang-cursors|I-attached-twice|=|-|-Iinc -I inc x.cpp
libclang-cursors|multi|=|-|x.cpp y.cpp
libclang-cursors|no-input|=|-|-std=c++17
libclang-cursors|missing-input|=|-|nope.cpp
libclang-cursors|reject-first|=|-|REJECT.cpp x.cpp
libclang-cursors|status|=|FAKE_EXIT=6|x.cpp
libclang-cursors|I-alone-is-a-file|=|-|-I
libclang-cursors|std-c-is-a-file|=|-|-std=c17 x.cpp
libclang-cursors|ti-cleanup|=|FAKE_TI=1|x.cpp
libclang-cursors|sys-override|=|NFCXX_SYS_INCLUDES=/s/a:|x.cpp
libclang-cursors|cpfe-env-missing|=|LIBCLANG_EDG_CPFE=/no/such/cpfe|x.cpp
libclang-cursors|cpfe-default-missing|=|T_NOCPFE=1|x.cpp
libclang-cursors|base-missing|~|LIBCLANG_EDG_BASE=/no/such/base|x.cpp
# build-libclang-edg: the compile and link commands are logged by fake cc and c++ (CALLS); state is the outputs
build-libclang-edg|in-process-fresh|=|T_ARCHIVE=1|
build-libclang-edg|in-process-up-to-date|=|T_ARCHIVE=1 T_PRE=1 T_SO=2100-01-01|
build-libclang-edg|in-process-stale|=|T_ARCHIVE=1 T_PRE=1 T_SO=2000-01-01|
build-libclang-edg|in-process-no-gnu|=|T_ARCHIVE=1 NFCXX_CXX=@BIN@/clang21|
build-libclang-edg|in-process-sys-override|=|T_ARCHIVE=1 NFCXX_SYS_INCLUDES=/s/a:/s/b|
build-libclang-edg|in-process-off|=|T_ARCHIVE=1 LIBCLANG_EDG_IN_PROCESS=0|
build-libclang-edg|no-archive|=|-|
build-libclang-edg|ldflags|=|T_ARCHIVE=1 LIBCLANG_EDG_LDFLAGS=-O1|
build-libclang-edg|out-and-base-custom|=|T_ARCHIVE=1 LIBCLANG_EDG_OUT=@ROOT@/build/custom LIBCLANG_EDG_BASE=@ROOT@/base2|
build-libclang-edg|cc-fails|=|T_ARCHIVE=1 FAKE_CC_FAIL=1|
build-libclang-edg|cc-fails-no-archive|=|FAKE_CC_FAIL=1|
build-libclang-edg|source-missing|=|T_ARCHIVE=1 T_NOLIB=1|
build-libclang-edg|cc-missing|~|CC=/no/such/cc|
TABLE
)

while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  IFS='|' read -r tool name mode envs args <<< "$line"
  ENVS=(); ARGS=()
  for v in $(compgen -v T_); do unset "$v"; done
  for tok in $envs; do
    case $tok in
      -) ;;
      T_*) eval "$tok" ;;
      *) ENVS+=("${tok//@ROOT@/$root}") ;;
    esac
  done
  for tok in $args; do ARGS+=("${tok//@ROOT@/$root}"); done
  # the fake compilers and the probes' compilers; the tree's ENVS may override them
  BASE_ENV=("NFCXX_CXX=$bin/gnu" "NFCXX_CC=$bin/gnu" "CC=$bin/cc" "CXX=$bin/cxx" "CALLS=$root/calls.log")
  ENVS=("${ENVS[@]//@BIN@/$bin}")
  ENVS=("${ENVS[@]//@ROOT@/$root}")
  [ "$mode" = "=" ] || mode="~"

  run_side bash "$tool"
  run_side ruby "$tool"
  ok=1; why=""
  for f in stdout status state; do
    cmp -s "$work/o/bash/$f" "$work/o/ruby/$f" || { ok=0; why="$why $f"; }
  done
  if [ "$mode" = "=" ]; then
    cmp -s "$work/o/bash/stderr" "$work/o/ruby/stderr" || { ok=0; why="$why stderr"; }
  else
    if [ -s "$work/o/bash/stderr" ] && [ ! -s "$work/o/ruby/stderr" ]; then ok=0; why="$why stderr-empty"; fi
    if [ ! -s "$work/o/bash/stderr" ] && [ -s "$work/o/ruby/stderr" ]; then ok=0; why="$why stderr-extra"; fi
  fi
  if [ $ok = 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $tool $name ($mode):$why"
    for f in stdout stderr status state; do
      diff "$work/o/bash/$f" "$work/o/ruby/$f" | sed "s/^/    $f /" | head -20
    done
  fi
done <<< "$cases"

echo "launch: $pass passed, $fail failed"
[ $fail = 0 ]

#!/bin/bash
# Differential test of the cross tools ported to Ruby: macos-stub-tbd, cross-macos-cxx, gen-c-target and cuda-driver-shim
# (scripts/NAME.rb). Each case runs the bash original (tests/cross/oracle/NAME.sh, placed as scripts/NAME.sh and run
# through its own shebang) and the port (scripts/NAME.rb) in two identical sandboxes with the same arguments and
# environment. The external commands are logging stubs (stub.sh) on PATH, so the logs hold the commands each run
# executes with their arguments. The two runs must agree on stdout, stderr (after normalization), exit status, the logged
# commands and the files they leave (scripts/ excluded; an archive is compared by its symbols). The normalization: the
# sandbox is ROOT, its temporary directories TMP, a script's name .EXT, a line number N, the cache directory's hash KEY.
#
# A case is one line "ENVS | ARGS" of the NAME's list below. ENVS: NAME=VALUE assignments and directives: !PATH=DIR runs
# with only the sandbox's bin-DIR (and ruby) on PATH, !TWICE runs the command a second time, !NOSRC removes the C source.
# ARGS are shell words; @SB@ is the sandbox. Standard input is work/stdin.txt in every run.
#
#   bash tests/cross/run.sh [NAME...]
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
realgcc=$(command -v gcc)
realar=$(command -v ar)
realuname=$(command -v uname)
rubypath=$(command -v ruby)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
names=("$@")
[ ${#names[@]} -gt 0 ] || names=(macos-stub-tbd cross-macos-cxx gen-c-target cuda-driver-shim)
pass=0; fail=0

# cases NAME: the case lines of NAME
cases() {
  case $1 in
    macos-stub-tbd) cat <<'EOF'
 | libX.dylib a.tbd names.txt
 | libX.dylib a.tbd empty.txt
 | libX.dylib a.tbd -
 | "lib X.dylib" "a b.tbd" names.txt
 | libX.dylib a.tbd nope.txt
 | libX.dylib a.tbd dir
 | libX.dylib nope/a.tbd names.txt
 | libX.dylib sub names.txt
 | libX.dylib
 | libX.dylib a.tbd
 |
EOF
      ;;
    cross-macos-cxx) cat <<'EOF'
 | -c a.cpp -o a.o
 | -c a.cpp -o a.o -fwrapv -fPIC -I inc
 | "-DX=a b" 'x$y' -I "inc dir"
 |
!PATH=none | -c a.cpp
!PATH=clang | -c a.cpp
!PATH=cxx | -c a.cpp
!PATH=cxx |
EOF
      ;;
    gen-c-target) cat <<'EOF'
 | -t linux_riscv32 -o out.c a.cpp
 | a.cpp
 | --target=win32 -std=c++17 a.cpp
 | -std=c++20 -t linux_riscv32 a.cpp -o nope/x.c
 | -o sub a.cpp
 | -o
 | -t
 | --bogus a.cpp
 | -
 | -std=gnu++17 a.cpp
 | -std=c++ a.cpp
 | -t nosuch a.cpp
 | -t win32 -o out.c nope/a.cpp
 | nope/a.cpp
 | missing.cpp
 |
 | ""
EDG_BUILD=@SB@/build/nocpfe | a.cpp
EDG_BASE=@SB@/build/edg-base2 | a.cpp
STUB_NOOUT=1 | -o out.c a.cpp
STUB_NOOUT=1 | a.cpp
STUB_RC_CPFE=7 | a.cpp
STUB_RC_CPFE=7 | -o out.c missing.cpp
EOF
      ;;
    cuda-driver-shim) cat <<'EOF'
!TWICE | @SB@/cuda/include
 | @SB@/cuda/include
!TWICE CUDA_HOME=@SB@/cuda |
CUDA_HOME=@SB@/cuda |
 | @SB@/cuda/bad
 | @SB@/cuda/small
 | @SB@/cuda/notypes
FAKE_UNAME_M=aarch64 | @SB@/cuda/include
NFCXX_GCC=nosuchgcc | @SB@/cuda/include
NFCXX_GCC=false | @SB@/cuda/include
!NOSRC | @SB@/cuda/include
 |
EOF
      ;;
  esac
}

# make_cuda DIR NFUNCS: a fake CUDA header pair (cuda.h, cudaTypedefs.h) with NFUNCS driver functions. Some names have a
# _v2 twin, some a per-thread variant (the macro), some have no typedef, and some typedefs share a type (two versions).
make_cuda() {
  local dir=$1 n=$2 i
  mkdir -p "$dir"
  {
    printf '#ifndef FAKE_CUDA_H\n#define FAKE_CUDA_H\n#define CUDA_VERSION 12090\ntypedef int CUresult;\n'
    printf 'CUresult cuGetErrorString(int *a);\nCUresult cuGetErrorName(int *a);\n'
    for ((i = 1; i <= n; i++)); do
      if ((i % 5 == 0)); then
        printf '#ifdef CUDA_API_PER_THREAD_DEFAULT_STREAM\n#define cuFake%d cuFake%d_ptds\n#endif\n' "$i" "$i"
      fi
      printf 'CUresult cuFake%d(int *a);\n' "$i"
      if ((i % 4 == 0)); then printf 'CUresult cuFake%d_v2(int *a);\n' "$i"; fi
    done
    printf '#endif\n'
  } > "$dir/cuda.h"
  {
    printf '#ifndef FAKE_CUDA_TYPEDEFS_H\n#define FAKE_CUDA_TYPEDEFS_H\n'
    printf 'typedef CUresult (*PFN_cuGetErrorString_v1000)(int *a);\ntypedef CUresult (*PFN_cuGetErrorName_v1000)(int *a);\n'
    for ((i = 1; i <= n; i++)); do
      if ((i % 7 == 3)); then continue; fi
      printf 'typedef CUresult (*PFN_cuFake%d_v1000)(int *a);\n' "$i"
      if ((i % 4 == 0)); then printf 'typedef CUresult (*PFN_cuFake%d_v2000)(int *a);\n' "$i"; fi
      if ((i % 5 == 0)); then printf 'typedef CUresult (*PFN_cuFake%d_v1000_ptds)(int *a);\n' "$i"; fi
    done
    printf '#endif\n'
  } > "$dir/cudaTypedefs.h"
}

# setup NAME SB: the sandbox's stubs and fixtures (the same for both implementations)
setup() {
  local name=$1 sb=$2 c
  mkdir -p "$sb"/scripts "$sb"/bin "$sb"/bin-clang "$sb"/bin-cxx "$sb"/bin-none "$sb"/rubybin "$sb"/work "$sb"/tmp \
    "$sb"/lib/cuda/driver
  for c in clang clang++ gcc ar uname; do ln -s "$here/stub.sh" "$sb/bin/$c"; done
  ln -s "$here/stub.sh" "$sb/bin-clang/clang"
  ln -s "$here/stub.sh" "$sb/bin-cxx/clang++"
  ln -s "$rubypath" "$sb/rubybin/ruby"
  cp "$repo/lib/cuda/driver/nfcxx_cudrv.c" "$sb/lib/cuda/driver/nfcxx_cudrv.c"
  printf 'stdin line\n' > "$sb/work/stdin.txt"
  case $name in
    macos-stub-tbd)
      printf '_zeta\n_alpha,beta\n_alpha,beta\n\n_b\n' > "$sb/work/names.txt"
      : > "$sb/work/empty.txt"
      mkdir -p "$sb/work/dir" "$sb/work/sub" ;;
    gen-c-target)
      mkdir -p "$sb/build/edg/bin" "$sb/build/nocpfe/bin" "$sb/build/edg-base/lib_linux_riscv32" \
        "$sb/build/edg-base/lib_win32" "$sb/build/edg-base/include" "$sb/build/edg-base2/lib_linux_riscv32" \
        "$sb/3rd/edg/include_c++" "$sb/work/sub"
      ln -s "$here/stub.sh" "$sb/build/edg/bin/cpfe"
      : > "$sb/build/edg-base/include/exception.h"
      printf 'int x;\n' > "$sb/work/a.cpp" ;;
    cuda-driver-shim)
      make_cuda "$sb/cuda/include" 120
      make_cuda "$sb/cuda/small" 20
      make_cuda "$sb/cuda/notypes" 120
      printf '#ifndef NO_TYPEDEFS\n#define NO_TYPEDEFS\n#endif\n' > "$sb/cuda/notypes/cudaTypedefs.h"
      mkdir -p "$sb/cuda/bad" ;;
  esac
}

# place NAME SB IMPL: the implementation under test, executable, in the sandbox's scripts/
place() {
  local name=$1 sb=$2 impl=$3
  if [ "$impl" = oracle ]; then
    cp "$here/oracle/$name.sh" "$sb/scripts/$name.sh"
    chmod +x "$sb/scripts/$name.sh"
  else
    cp "$repo/scripts/$name.rb" "$sb/scripts/$name.rb"
    chmod +x "$sb/scripts/$name.rb"
  fi
}

# norm FILE SB: the file with the sandbox, its temporary directories, script names, line numbers and cache hash normalized
norm() {
  sed -E -e "s#$2/tmp/[^/ \"']*#TMP#g" -e "s#$2#ROOT#g" -e 's/\.(sh|rb)\b/.EXT/g' \
      -e 's/: (line )?[0-9]+: /: N: /g' -e 's#build/cuda-driver/[0-9a-f]{16}#build/cuda-driver/KEY#g' "$1"
}

# snapshot SB: the files the run left (scripts, stubs, logs and temporary directories excluded) with their contents; an
# archive or an object is listed by its symbols
snapshot() {
  (cd "$1" && find . \( -path ./scripts -o -path ./bin -o -path ./bin-clang -o -path ./bin-cxx -o -path ./bin-none \
        -o -path ./rubybin -o -path ./log -o -path ./tmp -o -path ./out -o -path ./err -o -path ./status \
        -o -path ./files \) -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    echo "== $f"
    case $f in
      *.a|*.o) nm -a -- "$f" 2>&1 ;;
      *) cat -- "$f" ;;
    esac
  done)
}

# run_one IMPL NAME SB ENVS ARGS: runs the implementation in the sandbox SB; its results are SB/{out,err,status,log,files}
run_one() {
  local impl=$1 name=$2 sb=$3 envs=$4 args=$5 tok path pathdir="" prog st twice=0
  local -a envlist=() progargs=()
  envs=${envs//@SB@/$sb}
  args=${args//@SB@/$sb}
  for tok in $envs; do
    case $tok in
      !PATH=*) pathdir=${tok#!PATH=} ;;
      !TWICE) twice=1 ;;
      !NOSRC) rm -f "$sb/lib/cuda/driver/nfcxx_cudrv.c" ;;
      *) envlist+=("$tok") ;;
    esac
  done
  if [ "$name" = gen-c-target ]; then envlist=("EDG_BUILD=$sb/build/edg" ${envlist[@]+"${envlist[@]}"}); fi
  if [ -n "$pathdir" ]; then path="$sb/bin-$pathdir:$sb/rubybin"; else path="$sb/bin:$sb/rubybin:/usr/bin:/bin"; fi
  eval "progargs=($args)" || { echo "bad case: $args" >&2; return 1; }
  if [ "$impl" = oracle ]; then prog=$sb/scripts/$name.sh; else prog=$sb/scripts/$name.rb; fi
  : > "$sb/log"
  (cd "$sb/work" && env -i PATH="$path" HOME="$sb" TMPDIR="$sb/tmp" LC_ALL=C NFCXX_STUB_LOG="$sb/log" \
     REALGCC="$realgcc" REALAR="$realar" REALUNAME="$realuname" ${envlist[@]+"${envlist[@]}"} \
     "$prog" ${progargs[@]+"${progargs[@]}"} < "$sb/work/stdin.txt" > "$sb/out" 2> "$sb/err")
  st=$?
  if [ $twice = 1 ]; then
    (cd "$sb/work" && env -i PATH="$path" HOME="$sb" TMPDIR="$sb/tmp" LC_ALL=C NFCXX_STUB_LOG="$sb/log" \
       REALGCC="$realgcc" REALAR="$realar" REALUNAME="$realuname" ${envlist[@]+"${envlist[@]}"} \
       "$prog" ${progargs[@]+"${progargs[@]}"} < "$sb/work/stdin.txt" >> "$sb/out" 2>> "$sb/err")
    st=$?
  fi
  echo "$st" > "$sb/status"
  snapshot "$sb" > "$sb/files" 2>&1
}

for name in "${names[@]}"; do
  [ -f "$here/oracle/$name.sh" ] || { echo "$name: no oracle"; fail=$((fail + 1)); continue; }
  while IFS= read -r line; do
    envs=${line%%|*}; args=${line#*|}
    [ "$envs" != "$line" ] || continue
    envs=${envs#"${envs%%[![:space:]]*}"}; envs=${envs%"${envs##*[![:space:]]}"}
    args=${args#"${args%%[![:space:]]*}"}
    sbo=$(mktemp -d "$work/o.XXXXXX"); sbr=$(mktemp -d "$work/r.XXXXXX")
    setup "$name" "$sbo"; place "$name" "$sbo" oracle
    setup "$name" "$sbr"; place "$name" "$sbr" port
    if ! run_one oracle "$name" "$sbo" "$envs" "$args" || ! run_one port "$name" "$sbr" "$envs" "$args"; then
      fail=$((fail + 1)); echo "FAIL $name [$envs] $args: the case did not parse"; rm -rf "$sbo" "$sbr"; continue
    fi
    if [ -n "${CROSS_SHOW:-}" ]; then
      echo "--- $name [$envs] $args (status $(cat "$sbo/status"))"
      norm "$sbo/log" "$sbo" | sed 's/^/  log: /' | head -12
      norm "$sbo/out" "$sbo" | sed 's/^/  out: /' | head -8
      norm "$sbo/err" "$sbo" | sed 's/^/  err: /' | head -6
    fi
    ok=1; bad=""
    for f in out err status log files; do
      norm "$sbo/$f" "$sbo" > "$sbo/$f.n"; norm "$sbr/$f" "$sbr" > "$sbr/$f.n"
      cmp -s "$sbo/$f.n" "$sbr/$f.n" || { ok=0; bad="$bad $f"; }
    done
    if [ $ok = 1 ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "FAIL $name [$envs] $args:$bad"
      for f in out err status log files; do
        [ -s "$sbo/$f.n" ] || [ -s "$sbr/$f.n" ] || continue
        diff "$sbo/$f.n" "$sbr/$f.n" > "$sbo/diff.$f" 2>&1 && continue
        echo "  $f (oracle < port):"; sed 's/^/    /' "$sbo/diff.$f" | head -20
      done
    fi
    rm -rf "$sbo" "$sbr"
  done < <(cases "$name")
done
echo "cross: $pass passed, $fail failed"
[ $fail = 0 ]

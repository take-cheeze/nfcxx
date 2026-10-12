#!/usr/bin/env bash
# Test beds: real CUDA programs through the nfcxx driver, one line per program in cases.txt (see there for the fields).
# Sources are not vendored. CUDA_SAMPLES is the cuda-samples checkout (default build/targets/cuda-samples), RODINIA is
# the Rodinia CUDA tree (default build/targets/rodinia/cuda). Fetch them with, for example:
#   git clone --depth 1 https://github.com/NVIDIA/cuda-samples build/targets/cuda-samples
#   git clone --depth 1 https://github.com/yuhc/gpu-rodinia build/targets/rodinia
# A missing tree or toolkit is reported as SKIP with its reason; it is never silent.
# Needs the CUDA toolkit (CUDA_HOME, default /usr/local/cuda) and an NVIDIA GPU to run the programs.
# NFCXX_BACKEND defaults to gcc here: the qbe backend (cproc) rejects libcu++ headers (__builtin_fabsf).
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
samples=${CUDA_SAMPLES:-$root/build/targets/cuda-samples}
rodinia=${RODINIA:-$root/build/targets/rodinia/cuda}
export NFCXX_BACKEND=${NFCXX_BACKEND:-gcc}
nfcxx=$root/nfcxx
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP all: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME=$cuda)"; exit 0
fi

fail=0
while IFS='|' read -r name tree dir srcs expect marker known; do
  case "$name" in ''|\#*) continue ;; esac
  name=$(echo "$name" | tr -d ' '); tree=$(echo "$tree" | tr -d ' '); dir=$(echo "$dir" | tr -d ' ')
  expect=$(echo "$expect" | tr -d ' '); marker=$(echo "$marker" | sed 's/^ *//;s/ *$//'); known=$(echo "$known" | sed 's/^ *//;s/ *$//')
  if [ "$tree" = cpp ]; then base=$samples/cpp; else base=$rodinia; fi
  src_dir=$base/$dir
  if [ ! -d "$src_dir" ]; then echo "SKIP $name: source tree not found at $src_dir"; continue; fi
  w=$work/$name; mkdir -p "$w"
  cd "$w" || exit 1
  objs=""; cerr=""
  for f in $srcs; do
    b=$(basename "$f"); b=${b%.*}
    if ! TMPDIR=$w "$nfcxx" -c -I"$cuda/include" -I"$cuda/include/cccl" -I"$samples/Common" -I"$rodinia/../common" -I"$src_dir" \
         "$src_dir/$f" -o "$w/$b.o" > "$w/$b.log" 2>&1; then
      cerr=$(grep -v 'pragma\|warning: unrecognized\|NV_SILENCE\|^ *\^\|^ *$' "$w/$b.log" | grep -m1 -A1 'error\|refused\|catastrophic' | tr '\n' ' ' | tr -s ' ')
      break
    fi
    objs="$objs $w/$b.o"
  done
  cd "$OLDPWD" || exit 1
  if [ -n "$cerr" ]; then
    if [ "$expect" = fail-compile ]; then
      if echo "$cerr" | grep -qF "$known"; then echo "known-fail $name: $known"
      else echo "FAIL $name: compile error changed: $cerr"; fail=1; fi
    else
      echo "FAIL $name: does not compile: $cerr"; fail=1
    fi
    continue
  fi
  if [ "$expect" = fail-compile ]; then echo "NOW BUILDS $name: update cases.txt (it was recorded as $known)"; fi
  if ! TMPDIR=$w "$nfcxx" $objs -L"$cuda/lib64" -lcudart -o "$w/$name" > "$w/link.log" 2>&1; then
    lerr=$(grep -m1 -i 'undefined\|error\|multiple definition' "$w/link.log" | cut -c1-160)
    if [ "$expect" = fail-link ]; then
      if grep -qF "$known" "$w/link.log"; then echo "known-fail $name (link): $known"
      else echo "FAIL $name: link error changed: $lerr"; fail=1; fi
    else
      echo "FAIL $name: link: $lerr"; fail=1
    fi
    continue
  fi
  if [ "$expect" = fail-link ]; then echo "NOW LINKS $name: update cases.txt (it was recorded as $known)"; fi
  # builds: compiles and links, but the program needs input arguments to run, so it is not run here.
  if [ "$expect" = builds ]; then echo "builds $name: links; not run ($known)"; continue; fi
  out=$(cd "$w" && LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" timeout 300 "./$name" 2>&1); rc=$?
  if [ "$rc" != 0 ]; then echo "FAIL $name: run exit $rc"; fail=1; continue; fi
  if [ "$expect" = pass ]; then
    if echo "$out" | grep -qF "$marker"; then echo "pass $name"
    else echo "FAIL $name: marker not printed: $marker"; fail=1; fi
  else
    echo "runs $name: exit 0, no result check printed (not verified)"
  fi
done < cases.txt
exit $fail

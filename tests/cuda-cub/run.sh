#!/bin/bash
# scripts/cuda-cub.rb (the Ruby port) must do what scripts/cuda-cub (bash, tests/cuda-cub/oracle.sh) does. The device compile
# needs a CUDA toolkit, which this machine may not have, so the test covers the paths that need none: the disabled
# archive (NFCXX_CUDA_CUB=0), and a device compile that fails because the toolkit's headers are missing (the warning on
# stderr, nothing on stdout, status 0). The temporary directories in the output are normalized.
#   bash tests/cuda-cub/run.sh
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
sb=$work/sb; mkdir -p "$sb/scripts"
for f in "$repo"/scripts/*; do ln -s "$f" "$sb/scripts/"; done
rm -f "$sb/scripts/cuda-cub.rb"; cp "$repo/tests/cuda-cub/oracle.sh" "$sb/scripts/cuda-cub"; chmod +x "$sb/scripts/cuda-cub"
ln -s "$repo/build" "$sb/build"; ln -s "$repo/lib" "$sb/lib"; ln -s "$repo/3rd" "$sb/3rd"; ln -s "$repo/tools" "$sb/tools"
ln -s "$repo/nfcxx" "$sb/nfcxx"
pass=0; fail=0
# the first stderr line, with the sandbox's and the repository's roots as ROOT (the build's own messages name its tree)
norm() { head -1 "$1" | sed -e "s|$sb|ROOT|g" -e "s|$repo|ROOT|g" -e 's|\.build\.[A-Za-z0-9]*|.build.X|g'; }
check() {  # check NAME ENV... -- the same stdout, stderr and status from both
  local name=$1; shift
  local bo be bs ro re rs
  bo=$(env -i RUBY="$(command -v ruby)" PATH="$PATH" HOME="$HOME" "$@" NFCXX_CUDA_CUB_DIR=$work/bash-$name bash "$sb/scripts/cuda-cub" 2> "$work/$name.bash.err"); bs=$?
  ro=$(env -i RUBY="$(command -v ruby)" PATH="$PATH" HOME="$HOME" "$@" NFCXX_CUDA_CUB_DIR=$work/ruby-$name ruby "$repo/scripts/cuda-cub.rb" 2> "$work/$name.ruby.err"); rs=$?
  bo=${bo//$work/WORK}; ro=${ro//$work/WORK}
  if [ "$bs" = "$rs" ] && [ "$bo" = "$ro" ] && [ "$(norm "$work/$name.bash.err")" = "$(norm "$work/$name.ruby.err")" ]; then
    # the warning itself is the contract (the build's own lines follow it and name the tree they were built in)
    pass=$((pass + 1)); echo "pass $name (status $bs)"
  else
    fail=$((fail + 1)); echo "FAIL $name: status bash=$bs ruby=$rs"; echo "  bash stdout [$bo] ruby stdout [$ro]"
    diff <(norm "$work/$name.bash.err") <(norm "$work/$name.ruby.err") | head -5
  fi
}
check disabled NFCXX_CUDA_CUB=0
check no-toolkit CUDA_HOME="$work/no-such-toolkit"
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]

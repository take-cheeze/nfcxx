#!/bin/bash
# Differential test of scripts/wrap.rb against the bash wrappers it replaces (tests/wrap/bundle-wrap.sh and
# tests/wrap/cuda-driver-wrap.sh). Each case runs one wrapper both ways with the same environment and a fake driver (named
# nfcxx, which prints its arguments and exits with FAKE_STATUS). A wrapper that goes on prints CONTINUE (the bash returns
# from the function, the Ruby exits 254); for the CUDA wrapper the arguments it keeps are printed after that. Compared:
# stdout, stderr and the exit status. A link the bundle wrapper would bundle is not run here (it needs a real object for
# build/nfcbundle). Lines of the form "CASE | ENVIRONMENT | bundle|cuda ARGUMENTS".
#
#   bash tests/wrap/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
ruby_cli=$repo/scripts/wrap.rb
ruby_bin=$(command -v ruby)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/partial/include" "$work/full/include"
printf '#!/bin/bash\necho "driver: $*"\nexit "${FAKE_STATUS:-0}"\n' > "$work/bin/nfcxx"; chmod +x "$work/bin/nfcxx"
touch "$work/partial/include/cuda.h" "$work/partial/include/cudaTypedefs.h"

cases=(
  "bundle-compile | | bundle -c --bundle-libs x.c"
  "bundle-none | | bundle -c x.c"
  "bundle-no-libs | | bundle -c --bundle-exclude=foo x.c"
  "bundle-unknown | | bundle -c --bundle-bogus --bundle-libs x.c"
  "bundle-driver-fails | FAKE_STATUS=3 | bundle -c --bundle-libs x.c"
  "bundle-options | | bundle -c --bundle-libs --bundle-stubs=/s --bundle-add=a,b x.c"
  "cuda-none | | cuda -o a.out x.o"
  "cuda-bad-mode | | cuda --cuda-driver=bogus -lcuda x.o"
  "cuda-auto-no-toolkit | CUDA_HOME=@W@/none | cuda -lcuda x.o"
  "cuda-cudart-no-toolkit | CUDA_HOME=@W@/none NFCXX_CUDA_DRIVER=cudart | cuda -lcuda x.o"
  "cuda-libcuda-mode | | cuda --cuda-driver=libcuda -lcuda x.o"
  "cuda-env-libcuda | NFCXX_CUDA_DRIVER=libcuda | cuda -lcuda -o out x.o"
  "cuda-partial-toolkit | CUDA_HOME=@W@/partial | cuda -lcuda x.o"
  "cuda-cudart-partial | CUDA_HOME=@W@/partial | cuda --cuda-driver=cudart -lcuda x.o"
)

# bash_run KIND ENVS ARGS...: the wrapper as nfcxx calls it, sourced with the repository as root
bash_run() {
  local kind=$1 envs=$2; shift 2
  local w fn
  if [ "$kind" = bundle ]; then w=$repo/tests/wrap/bundle-wrap.sh; fn=bundle_wrap
  else w=$repo/tests/wrap/cuda-driver-wrap.sh; fn=cuda_driver_wrap; fi
  # shellcheck disable=SC2086
  (cd "$work" && env -i HOME="$work" PATH="$work/bin:$(dirname "$ruby_bin"):/usr/bin:/bin" $envs bash -c '
     root=$1; source "$2"; fn=$3; drv=$4; shift 4
     "$fn" "$drv" "$@" || exit $?
     echo CONTINUE
     for a in ${cuda_driver_args[@]+"${cuda_driver_args[@]}"}; do printf "[%s]\n" "$a"; done
     exit 0' bash "$repo" "$w" "$fn" "$work/bin/nfcxx" "$@")
}

# ruby_run KIND ENVS ARGS...: the same through scripts/wrap.rb (254 is "go on": CONTINUE, and the kept list)
ruby_run() {
  local kind=$1 envs=$2; shift 2
  local lst=$work/kept.$$ st=0
  # shellcheck disable=SC2086
  if [ "$kind" = bundle ]; then
    (cd "$work" && env -i HOME="$work" PATH="$work/bin:$(dirname "$ruby_bin"):/usr/bin:/bin" $envs \
       "$ruby_bin" "$ruby_cli" bundle "$work/bin/nfcxx" "$@") || st=$?
  else
    (cd "$work" && env -i HOME="$work" PATH="$work/bin:$(dirname "$ruby_bin"):/usr/bin:/bin" $envs \
       "$ruby_bin" "$ruby_cli" cuda-driver "$lst" "$work/bin/nfcxx" "$@") || st=$?
  fi
  [ "$st" = 254 ] || return "$st"
  echo CONTINUE
  if [ "$kind" = cuda ]; then
    while IFS= read -r -d '' a; do printf '[%s]\n' "$a"; done < "$lst"
    rm -f "$lst"
  fi
  return 0
}

pass=0; fail=0
for c in "${cases[@]}"; do
  IFS='|' read -r name envs rest <<< "$c"
  name=${name// /}; envs=${envs# }; envs=${envs% }; envs=${envs//@W@/$work}
  rest=${rest# }; kind=${rest%% *}; args=${rest#"$kind"}
  # shellcheck disable=SC2206
  words=($args)
  bash_run "$kind" "$envs" "${words[@]}" > "$work/$name.bash.out" 2> "$work/$name.bash.err"; sa=$?
  ruby_run "$kind" "$envs" "${words[@]}" > "$work/$name.ruby.out" 2> "$work/$name.ruby.err"; sb=$?
  ok=1
  diff "$work/$name.bash.out" "$work/$name.ruby.out" > "$work/$name.d.out" 2>&1 || ok=0
  diff <(sed "s#$work#W#g" "$work/$name.bash.err") <(sed "s#$work#W#g" "$work/$name.ruby.err") > "$work/$name.d.err" 2>&1 || ok=0
  [ "$sa" = "$sb" ] || ok=0
  if [ $ok = 1 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL $name (status bash=$sa ruby=$sb)"
    sed 's/^/  stdout: /' "$work/$name.d.out" | head -8; sed 's/^/  stderr: /' "$work/$name.d.err" | head -8
  fi
done
echo "wrap: $pass passed, $fail failed"
[ $fail = 0 ]

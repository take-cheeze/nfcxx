#!/bin/bash
# Differential test of the scripts ported to Ruby. For each NAME with a tests/rb-migration/NAME/cases.txt, every case runs
# twice in identical sandboxes: the bash original (NAME/oracle.sh, as scripts/NAME.sh) and the port (scripts/NAME.rb).
# The external commands are logging stubs (stub.sh) on PATH and in the sandbox, so the logs hold the commands the script
# runs, with their arguments and the environment it passes on. The sandbox's commands that are not stubbed (ln, mv, cut,
# sed, realpath, ...) run for real. Per case the two runs must print the same stdout, exit with the same status and log
# the same commands. The stderr text is not compared.
#
# A case is one line of cases.txt: "ENV=VALUE ... | ARGUMENTS", the arguments as shell words; @SB@ is the sandbox.
# Lines starting with # and blank lines are skipped. The sandbox's work directory is the working directory of the run.
# In the output the sandbox is ROOT, its temporary directories TMP, the .sh and .rb names of the scripts .EXT, and a
# timing "(Ns)" is N.
#
#   bash tests/rb-migration/run.sh [NAME...]
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
rubydir=$(dirname "$(command -v ruby)")
names=("$@")
[ ${#names[@]} -gt 0 ] || names=(cross-macos-cc cross-macos-link macos-cxx-link nfcc-pathb-measure mcu-qemu selfhost-cpfe sycl-build ggml-sycl-lib)
pass=0; fail=0

# stubs NAME... : links of stub.sh in the directory DIR
stubs_in() {
  local dir=$1; shift
  local n
  for n in "$@"; do ln -sf "$here/stub.sh" "$dir/$n"; done
}

# setup NAME SB: the sandbox's files and directories that do not depend on the implementation
setup() {
  local name=$1 sb=$2
  mkdir -p "$sb/scripts" "$sb/bin" "$sb/work" "$sb/tmp" "$sb/build" "$sb/tests/sycl" "$sb/lib/sycl/include" \
    "$sb/lib/sycl-ggml/stubs" "$sb/3rd/edg/src" "$sb/build/edg-base" "$sb/build/edg/bin" "$sb/build/qbe"
  stubs_in "$sb/bin" clang file mktemp cp git ninja ld64.lld spirv-val fakeruby fakecxx
  stubs_in "$sb" nfcxx nfcc
  stubs_in "$sb/scripts" pathb-dump pathb-ir-opt.rb pathb-ssa.rb pathb-egraph.rb pathb-ssa-structurize.rb \
    spirv-emit mrb pathb-wgsl-emit.rb pathb-ldrt.rb sycl-build.sh sycl-build.rb
  rm -f "$sb/scripts/oneapi-env.sh"; cp "$repo/scripts/oneapi-env.sh" "$sb/scripts/oneapi-env.sh"
  stubs_in "$sb/build/edg/bin" cpfe
  : > "$sb/tests/sycl/server.cjs"
  rm -f "$sb/build/edg/environment.sh" "$sb/build/edg/bin/eccp"
  printf 'CPFE=%s\n' "$sb/build/edg/bin/cpfe" > "$sb/build/edg/environment.sh"
  printf 'source %s\n' "$sb/build/edg/environment.sh" > "$sb/build/edg/bin/eccp"
  chmod +x "$sb/build/edg/bin/eccp"   # text: selfhost-cpfe rewrites it with sed; sycl-build only tests it executable
  case $name in
    macos-cxx-link)
      mkdir -p "$sb/build"
      printf 'NFCXX_MACOS_CLEANROOM=/cr\nNFCXX_LIBCXX=/lcxx\nNFCXX_MACOS_SYSROOT=/sys\n' > "$sb/build/cross-macos.env"
      : > "$sb/work/src.cpp" ;;
    nfcc-pathb-measure)
      : > "$sb/work/a.c"; : > "$sb/work/b.c" ;;
    mcu-qemu)
      mkdir -p "$sb/work/q/build"
      stubs_in "$sb/work/q" configure
      stubs_in "$sb/work/q/build" qemu-system-riscv32 ;;
    selfhost-cpfe)
      stubs_in "$sb/build/qbe" qbe ;;
    cross-macos-link)
      mkdir -p "$sb/build/macos-rt"
      : > "$sb/build/macos-rt/libnfcxx-darwin-rt.a"; : > "$sb/build/macos-rt/libC-darwin.a"
      : > "$sb/build/macos-rt/libc++-darwin.a"
      printf '\177ELF' > "$sb/work/host.o"; : > "$sb/work/m.o" ;;
    sycl-build)
      mkdir -p "$sb/oneapi/compiler/2024.2/lib" "$sb/oneapi/compiler/2025.1/lib" "$sb/oneapi/compiler/2025.1/include/sycl" \
        "$sb/oneapi/mkl/latest/lib"
      : > "$sb/work/prog.cpp" ;;
    ggml-sycl-lib)
      mkdir -p "$sb/ggml/src/ggml-sycl/template-instances" "$sb/ggmlbin"
      : > "$sb/ggml/src/ggml-sycl/a.cpp"; : > "$sb/ggml/src/ggml-sycl/b.cpp"; : > "$sb/ggml/src/ggml-sycl/c.cpp"
      : > "$sb/ggml/src/ggml-sycl/template-instances/fattn-tile1.cpp"
      : > "$sb/ggml/src/ggml-sycl/template-instances/fattn-vec1.cpp"
      : > "$sb/lib/sycl/x.hpp"
      : > "$sb/lib/sycl-ggml/stubs/b.cpp" ;;
  esac
  # the qemu and configure stubs of mcu-qemu are executed by the script; the tree is ready for the case
  chmod +x "$sb"/bin/* "$sb"/scripts/* "$sb/build/edg/bin/cpfe" "$sb/build/qbe/qbe" 2>/dev/null
  [ "$name" != mcu-qemu ] || chmod +x "$sb/work/q/configure" "$sb/work/q/build/qemu-system-riscv32"
  # the stub's directory tree for the Ruby run: the port's scripts directory holds the port
  :
}

# place NAME SB IMPL: the implementation under test (oracle: NAME.sh, port: NAME.rb)
place() {
  local name=$1 sb=$2 impl=$3
  # the stubs of the same name are links to stub.sh: a copy must replace the link, never write through it
  if [ "$impl" = oracle ]; then
    rm -f "$sb/scripts/$name.sh"
    cp "$here/$name/oracle.sh" "$sb/scripts/$name.sh"
  else
    rm -f "$sb/scripts/$name.rb"
    cp "$repo/scripts/$name.rb" "$sb/scripts/$name.rb"
    chmod +x "$sb/scripts/$name.rb"
  fi
}

# normalize FILE SB: the output with the sandbox, temporary and script-name differences removed
normalize() {
  sed -e "s#$2#ROOT#g" -e 's#ROOT/tmp/d[0-9]*#TMP#g' -e 's/\.sh\b/.EXT/g' -e 's/\.rb\b/.EXT/g' \
      -e 's/ ([0-9][0-9]*s)/ (Ns)/g' "$1"
}

# run_one NAME IMPL ENVS ARGS: prints the run's result files into SB (returned in RUN_SB)
run_one() {
  local name=$1 impl=$2 envs=$3 args=$4 sb prog st
  sb=$(mktemp -d)
  setup "$name" "$sb"
  place "$name" "$sb" "$impl"
  envs=${envs//@SB@/$sb}
  eval "set -- $args"
  if [ "$impl" = oracle ]; then prog=(bash "$sb/scripts/$name.sh"); else prog=("$sb/scripts/$name.rb"); fi
  : > "$sb/log"
  (cd "$sb/work" && env -i PATH="$sb/bin:$rubydir:/usr/bin:/bin" HOME="$sb" NFCXX_STUB_LOG="$sb/log" \
     NFCXX_STUB_TMP="$sb/tmp" $envs "${prog[@]}" "$@" > "$sb/out" 2> "$sb/err")
  st=$?
  echo "$st" > "$sb/status"
  RUN_SB=$sb
}

for name in "${names[@]}"; do
  cases=$here/$name/cases.txt
  [ -f "$cases" ] || { echo "$name: no cases"; continue; }
  while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    envs=${line%%|*}; args=${line#*|}
    envs=${envs#"${envs%%[![:space:]]*}"}; envs=${envs%"${envs##*[![:space:]]}"}
    args=${args#"${args%%[![:space:]]*}"}
    run_one "$name" oracle "$envs" "$args"; a=$RUN_SB
    run_one "$name" rb "$envs" "$args"; b=$RUN_SB
    ok=1
    for f in out status log; do
      if ! diff <(normalize "$a/$f" "$a") <(normalize "$b/$f" "$b") > "$a/diff.$f" 2>&1; then ok=0; fi
    done
    if [ -n "${RB_SHOW:-}" ]; then
      echo "--- $name [$envs] $args (status $(cat "$a/status"))"
      normalize "$a/log" "$a" | sed 's/^/  log: /' | head -40
      normalize "$a/out" "$a" | sed 's/^/  out: /' | head -10
      sed "s/^/  err: /" "$a/err" | head -5
    fi
    if [ $ok = 1 ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "FAIL $name [$envs] $args"
      for f in out status log; do
        [ -s "$a/diff.$f" ] && { echo "  $f:"; sed 's/^/    /' "$a/diff.$f" | head -20; }
      done
      echo "  bash stderr: $(head -c 300 "$a/err" | tr '\n' ' ')"
      echo "  ruby stderr: $(head -c 300 "$b/err" | tr '\n' ' ')"
    fi
    rm -rf "$a" "$b"
  done < "$cases"
done
echo "rb-migration: $pass passed, $fail failed"
[ $fail = 0 ]

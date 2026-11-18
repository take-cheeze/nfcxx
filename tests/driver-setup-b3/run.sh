#!/bin/bash
# The setup steps called in-process (scripts/nfcxx-setup.rb) print what the planners' own command lines print, for the same
# options: the same stdout, and for a refusal the same message and status. Each case runs the command line and the in-process
# step on the same words and compares them; asanopts is passed joined by ASCII 31 in-process (the form the driver's lists use)
# and as repeated asanopts= words on the command line.
#   bash tests/driver-setup-b3/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
root_arg="root=$repo"

# cli STEP WORDS...: the planner's own command line for STEP, on stdout (stderr and status are kept in $work)
cli() {
  local step=$1; shift
  case $step in
    default)      ruby "$repo/scripts/nfcxx-backend.rb" default "$@" ;;
    asan)         ruby "$repo/scripts/nfcxx-asan-c.rb" plan "$@" ;;
    instantiate)  ruby "$repo/scripts/nfcxx-instantiate.rb" plan "$@" ;;
    cosmo)        ruby "$repo/scripts/nfcxx-cosmo-setup.rb" setup "$@" ;;
    freestanding) ruby "$repo/scripts/nfcxx-freestanding-setup.rb" plan "$@" ;;
    host_cflags)  ruby "$repo/scripts/nfcxx-host-cflags.rb" plan "$@" ;;
    gnu_opts)     ruby "$repo/scripts/nfcxx-gnu-opts.rb" plan "$@" ;;
    k1om)         ruby "$repo/scripts/nfcxx-k1om-env.rb" plan "$@" ;;
    target)       ruby "$repo/scripts/nfcxx-target.rb" plan "$@" ;;
    backend_env)  ruby "$repo/scripts/nfcxx-backend-env.rb" plan "$@" ;;
  esac
}

# inproc STEP WORDS...: the same step called in-process
inproc() { ruby "$repo/scripts/nfcxx-setup.rb" "$@"; }

# check NAME STEP WORDS...: the command line and the in-process step print the same and exit alike; asanopts words are
# converted for the in-process form
check() {
  local name=$1 step=$2; shift 2
  local cli_words=("$@") inproc_words=()
  if [ "$step" = asan ]; then
    local joined=""
    for w in "$@"; do
      case $w in asanopts=*) joined+="${joined:+$'\x1f'}${w#asanopts=}" ;; *) inproc_words+=("$w") ;; esac
    done
    [ -n "$joined" ] && inproc_words+=("asanopts=$joined")
  else
    inproc_words=("$@")
  fi
  cli "$step" "${cli_words[@]}" >"$work/cli.out" 2>"$work/cli.err"; cst=$?
  inproc "$step" "${inproc_words[@]}" >"$work/in.out" 2>"$work/in.err"; ist=$?
  if [ "$cst" = "$ist" ] && cmp -s "$work/cli.out" "$work/in.out" && cmp -s "$work/cli.err" "$work/in.err"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name (status cli=$cst in-process=$ist)"
    diff "$work/cli.out" "$work/in.out" | head -4; diff "$work/cli.err" "$work/in.err" | head -4
  fi
}

# the cases: each step on the request kinds the suites use
check "default: hosted" default backend= host="Linux x86_64" freestanding=0 cosmo=0 emit_c=0 target= preprocess=0 depmode= shared=0 backend_explicit=0 path_b=0
check "default: freestanding on arm64 macOS" default backend= host="Darwin arm64" freestanding=1 cosmo=0 emit_c=0 target= preprocess=0 depmode= shared=0 backend_explicit=0 path_b=0
check "default: cosmo stays gcc" default backend= host="Linux x86_64" freestanding=0 cosmo=1 emit_c=0 target= preprocess=0 depmode= shared=0 backend_explicit=0 path_b=0
check "default: explicit gcc" default backend=gcc host="Linux x86_64" freestanding=0 cosmo=0 emit_c=0 target= preprocess=0 depmode= shared=0 backend_explicit=1 path_b=0
check "asan: gcc, on" asan asan=1 backend=gcc
check "asan: pathb, off, options" asan asan=0 backend=pathb asanopts=-fsanitize-recover=all asanopts=-fno-omit-frame-pointer
check "instantiate: used" instantiate instantiate=used sys=Linux
check "instantiate: refused" instantiate instantiate=bogus sys=Linux
check "cosmo: setup, gcc" cosmo backend=gcc backend_explicit=0 path_b=0 gnu= "$root_arg"
check "cosmo: setup, pathb" cosmo backend=pathb backend_explicit=1 path_b=1 gnu= "$root_arg"
check "freestanding: hosted" freestanding freestanding=0 gnu= sys=Linux "$root_arg"
check "freestanding: freestanding" freestanding freestanding=1 gnu= sys=Linux "$root_arg"
check "host cflags: pathb linux" host_cflags backend=pathb freestanding=0 sys=Linux mach=x86_64 "$root_arg"
check "host cflags: aarch64 hosted" host_cflags backend=gcc freestanding=0 sys=Linux mach=aarch64 "$root_arg"
check "gnu opts: g++" gnu_opts dialect=g++ gnu= "$root_arg"
check "gnu opts: clang" gnu_opts dialect=clang gnu= "$root_arg"
check "k1om: not asked" k1om target= freestanding=0 backend_explicit=0 backend=gcc "$root_arg"
check "backend env: gcc" backend_env backend=gcc freestanding=0 pb_fs_host=0 "$root_arg"
check "backend env: pathb" backend_env backend=pathb freestanding=0 pb_fs_host=1 "$root_arg"
check "target: none" target target= freestanding=0 emit_c=0 gnu_opts= "$root_arg"

echo "driver-setup-b3: $pass passed, $fail failed"
[ $fail = 0 ]

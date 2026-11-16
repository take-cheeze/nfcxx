#!/bin/bash
# Differential test of the link argument loop: nfcxx's link_args and ecp_args (thin bash, calling scripts/nfcxx-linkargs.rb
# and scripts/ecp-arg.rb --batch) against tests/nfcxx-linkargs/oracle.sh (the bash loop and ecp_arg, verbatim from before the
# port). Each case runs the same arguments in the same sandbox (rebuilt before each run) with the same environment, once per
# side. The stdout (the eflist and userinc values, declared), the standard error, the status and the files left must be the
# same.
#
#   bash tests/nfcxx-linkargs/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
ruby_bin=$(command -v ruby)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
sb=$work/sb
# the functions as nfcxx has them now
sed -n '/^ecp_args() {/,/^}/p' "$repo/nfcxx" > "$work/thin.sh"; cat "$here/thin-link-args.sh" >> "$work/thin.sh"
[ -s "$work/thin.sh" ] || { echo "nfcxx-linkargs: no link functions in nfcxx" >&2; exit 2; }

# the CUDA home and the CUB archive a case may name (cuda-cub prints the archive when it is newer than its inputs)
mkdir -p "$work/cuda/lib64" "$work/cuda-nolib" "$work/cubdir/pathb/sm75"
: > "$work/cubdir/pathb/sm75/libnfcxx_cub.a"

# a sandbox with files, directories and dangling links
make_sb() {
  rm -rf "$sb"; mkdir -p "$sb/sub" "$sb/inc" "$sb/inc dir" "$sb/dir with space" "$sb/lib"
  : > "$sb/a.o"; : > "$sb/b.o"; : > "$sb/my obj.o"; : > "$sb/sub/libx.so"; : > "$sb/libfoo.a"; : > "$sb/sub/d.d"
  : > "$sb/dir with space/q.o"; : > "$sb/lib/libbar.a"; : > "$sb/x.map"
  ln -s nowhere "$sb/dangling.o"
}

# the environment of both sides: nothing from the caller, the case's own settings only
base_env=(env -i PATH="$PATH" HOME="$HOME" NFCXX_CUDA_CUB=0)

# one side of a link case: prints the outcome. kind is thin (the port) or oracle (the bash loop)
link_side() {  # link_side KIND COMPILE_ONLY MOVES EXTRA_ENV FILE...
  local kind=$1 co=$2 mv=$3 extra=$4; shift 4
  make_sb
  local out err rc
  out=$(cd "$sb" && "${base_env[@]}" $extra bash -c '
    set -euo pipefail
    root=$1; RUBY=$2; src=$3; compile_only=$4; moves=$5; kind=$6; shift 6; files=("$@")
    source "$src"
    if [ "$kind" = thin ]; then link_args "$compile_only" "$moves" ${files[@]+"${files[@]}"}; else oracle_link_loop; fi
    declare -p eflist userinc' bash "$repo" "$ruby_bin" "$([ "$kind" = thin ] && echo "$work/thin.sh" || echo "$here/oracle.sh")" "$co" "$mv" "$kind" "$@" 2>"$work/err"); rc=$?
  err=$(cat "$work/err"); err=${err//$sb/<sb>}
  printf 'status %s\nstdout %s\nstderr %s\n' "$rc" "$out" "$err"
  ( cd "$sb" && find . -mindepth 1 -printf '%y %p %l\n' | sort )
}

pass=0; fail=0
link_case() {  # link_case NAME COMPILE_ONLY MOVES EXTRA_ENV FILE...: the port and the bash loop must agree
  local name=$1 co=$2 mv=$3 extra=$4; shift 4
  local t o
  t=$(link_side thin "$co" "$mv" "$extra" "$@")
  o=$(link_side oracle "$co" "$mv" "$extra" "$@")
  if [ "$t" = "$o" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name"; echo "--- oracle"; echo "$o"; echo "--- port"; echo "$t"
  fi
}

# the same for the batched ecp_args: each answer is the bash ecp_arg's, in order (moves 0 and 1)
ecp_case() {  # ecp_case NAME MOVES ARG...
  local name=$1 mv=$2; shift 2
  local t o
  make_sb
  t=$(cd "$sb" && "${base_env[@]}" bash -c '
    set -euo pipefail
    root=$1; RUBY=$2; src=$3; moves=$4; kind=$5; shift 5
    source "$src"
    if [ "$kind" = thin ]; then ecp_args "$@"; for v in ${ecp_list[@]+"${ecp_list[@]}"}; do printf "[%s]\n" "$v"; done
    else for a in "$@"; do printf "[%s]\n" "$(ecp_arg "$a")"; done; fi' bash "$repo" "$ruby_bin" "$work/thin.sh" "$mv" thin "$@" 2>&1)
  o=$(cd "$sb" && "${base_env[@]}" bash -c '
    set -euo pipefail
    root=$1; RUBY=$2; src=$3; moves=$4; kind=$5; shift 5
    source "$src"
    for a in "$@"; do printf "[%s]\n" "$(ecp_arg "$a")"; done' bash "$repo" "$ruby_bin" "$here/oracle.sh" "$mv" oracle "$@" 2>&1)
  if [ "$t" = "$o" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "FAIL $name"; echo "--- oracle"; echo "$o"; echo "--- port"; echo "$t"; fi
}

# -I, -l and -L
link_case "include dirs and a directory with a space" 0 1 "" -Iinc "-Iinc dir" -I -Inope/x "-Iinc dir/none" a.o
link_case "libraries as -l, a bare -l and a bare -I" 0 1 "" -lm -lpthread -l -I a.o -lfoo
link_case "libraries given as paths" 0 1 "" libfoo.a sub/libx.so ./lib/libbar.a a.o
link_case "dangling and missing paths" 0 1 "" dangling.o nothere.o libgone.a a.o
link_case "files with spaces" 0 1 "" "my obj.o" "dir with space/q.o" "-Wl,my lib.so" a.o
link_case "-L and other options passed through" 0 1 "" -Llib -L -O2 -fPIC --foo=bar - -x a.o
link_case "a link with no files" 0 1 ""

# -lcudart: the CUDA home's run path, the CUB archive (links only), libcudart
link_case "lcudart without CUDA_HOME" 0 1 "" a.o -lcudart
link_case "lcudart with a CUDA_HOME that has lib64" 0 1 "CUDA_HOME=$work/cuda" a.o -lcudart -lm
link_case "lcudart with a CUDA_HOME that has no lib64" 0 1 "CUDA_HOME=$work/cuda-nolib" a.o -lcudart
link_case "lcudart with an empty CUDA_HOME" 0 1 "CUDA_HOME=" a.o -lcudart
link_case "lcudart in a compile (no CUB archive)" 1 0 "CUDA_HOME=$work/cuda" a.o -lcudart
link_case "lcudart with the CUB archive" 0 1 "NFCXX_CUDA_CUB= NFCXX_CUDA_CUB_DIR=$work/cubdir NFCXX_BACKEND=pathb NFCXX_SM=75" a.o -lcudart

# --as-needed and --no-as-needed: one for the whole link, and the items of a span
link_case "no-as-needed alone" 0 1 "" a.o -Wl,--no-as-needed -lm
link_case "as-needed alone" 0 1 "" a.o -Wl,--as-needed -lm
link_case "as-needed then no-as-needed (no-as-needed wins)" 0 1 "" -Wl,--as-needed a.o -Wl,--no-as-needed
link_case "no-as-needed span with libraries and a path" 0 1 "" -Wl,--no-as-needed,-lm,libfoo.a,-lpthread,-Wl,-rpath,sub -Wl,--as-needed a.o
link_case "no-as-needed span with a trailing comma" 0 1 "" -Wl,--no-as-needed,-lm, a.o
link_case "no-as-needed empty span" 0 1 "" -Wl,--no-as-needed, a.o
link_case "no-as-needed span with empty items" 0 1 "" -Wl,--no-as-needed,,x,,-lm a.o
link_case "no-as-needed span of commas only" 0 1 "" -Wl,--no-as-needed,,, a.o
link_case "no-as-needed span with -l alone" 0 1 "" -Wl,--no-as-needed,-l,-lm a.o
link_case "no-as-needed span with a missing path" 0 1 "" -Wl,--no-as-needed,nothere.so,dangling.o a.o
link_case "no-as-needed span with a dangling -Wl option" 0 1 "" -Wl,--no-as-needed,-Wl,-rpath,sub a.o
link_case "no-as-needed in a compile" 1 0 "" -Wl,--no-as-needed,-lm a.o

# -Wl options with commas: files named in them, -soname operands, the files a link writes
link_case "Wl with rpath and a -E" 0 1 "" -Wl,-rpath,sub -Wl,-E a.o
link_case "Wl with a version script that exists and one that does not" 0 1 "" -Wl,--version-script=x.map -Wl,--version-script=nothere.map a.o
link_case "Wl with -T and a path" 0 1 "" -Wl,-T,x.map a.o
link_case "Wl with soname operands that name files here" 0 1 "" -Wl,-soname,a.o -Wl,-h,b.o -Wl,-soname=a.o -Wl,--soname=libx.so a.o
link_case "Wl with a dependency file and a map" 0 1 "" -Wl,--dependency-file=sub/d.d -Wl,--dependency-file=nodir/x.d -Wl,-Map=out.map -Wl,--Map=sub/out.map a.o
link_case "Wl with empty fields" 0 1 "" -Wl, -Wl,,a.o -Wl,a,,b,, a.o
link_case "Wl with a lone comma and a file" 0 1 "" -Wl,, -Wl,,x.map a.o
link_case "Wl with a name=path file" 0 1 "" -Wl,x=sub/d.d -Wl,x=nothere a.o
link_case "Wl in a compile" 1 0 "" -Wl,-rpath,sub a.o

# order-dependent link options: refused with the bash's message and status 2
link_case "refused whole-archive" 0 1 "" a.o -Wl,--whole-archive libfoo.a -Wl,--no-whole-archive
link_case "refused as-needed with a list" 0 1 "" a.o -Wl,--as-needed,-lm
link_case "refused -Bstatic in a span" 0 1 "" -Wl,-Bstatic,-lm a.o
link_case "refused start-group" 0 1 "" -Wl,--start-group libfoo.a -Wl,--end-group
link_case "not refused: a longer option name" 0 1 "" -Wl,--whole-archivex a.o -Wl,--as-neededx

# ecp_args: one batch for the arguments, the same answers as ecp_arg one at a time
ecp_case "batch: paths and options, moves 1" 1 a.o "my obj.o" sub -Iinc -Lsub "-Wl,-rpath,sub" -O2 "" nothere.o dangling.o
ecp_case "batch: link options with files, moves 1" 1 "-Wl,--version-script=x.map" "-Wl,-soname,a.o" "-Wl,--dependency-file=sub/d.d" "-Wl,a,,b," "-Wl,x=sub/d.d"
ecp_case "batch: no answers" 1
ecp_case "batch: moves 0 keeps the arguments" 0 a.o "my obj.o" "-Wl,-rpath,sub" "" -Iinc
ecp_case "batch: the same argument twice" 1 a.o a.o sub
ecp_case "batch: a single argument" 1 "dir with space/q.o"

# a forced crash of the helper: the wrapper runs the real ruby, then cuts its output (partway, and it fails) or drops the
# final end marker (and exits 0). The driver's function must stop the driver with status 1 and the message, before the
# next statement runs.
mk_crash_ruby() {  # mk_crash_ruby MODE FILE: MODE partial (60 bytes, status 3) or nomarker (the last record dropped, status 0)
  {
    printf '#!/bin/bash\n"%s" "$@" > "%s/crash.out"\n' "$ruby_bin" "$work"
    case $1 in
      partial) printf 'head -c 60 "%s/crash.out"; exit 3\n' "$work" ;;
      nomarker) printf 'head -c -2 "%s/crash.out"\n' "$work" ;;
    esac
  } > "$2"
  chmod +x "$2"
}
crash_case() {  # crash_case NAME MODE KIND ARG...: KIND link (link_args, the files) or ecp (ecp_args, the arguments)
  local name=$1 mode=$2 kind=$3; shift 3
  local w=$work/crash-ruby-$mode out err rc call
  mk_crash_ruby "$mode" "$w"
  [ "$kind" = link ] && call='link_args 0 1 "$@"' || call='ecp_args "$@"'
  make_sb
  out=$(cd "$sb" && "${base_env[@]}" bash -c '
    set -euo pipefail
    root=$1; RUBY=$2; source "$3"; shift 3
    '"$call"'
    echo reached' bash "$repo" "$w" "$work/thin.sh" "$@" 2>"$work/err"); rc=$?
  err=$(cat "$work/err")
  if [ "$rc" = 1 ] && [ "$out" = "" ] && [[ "$err" == *"stopped before its end"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name"; echo "  status $rc"; echo "  stdout [$out]"; echo "  stderr [$err]"
  fi
}
crash_case "link: the helper cut partway exits the driver with status 1" partial link -lm -lpthread -lz -lfoo -lbar -lbaz -lqux a.o
crash_case "link: the helper's final end marker missing exits the driver with status 1" nomarker link -lm -lpthread -lz -lfoo a.o
crash_case "ecp: the helper cut partway exits the driver with status 1" partial ecp /home/user/some/long/path/one /home/user/some/long/path/two /home/user/some/long/path/three /home/user/some/long/path/four
crash_case "ecp: the helper's final end marker missing exits the driver with status 1" nomarker ecp a.o sub

echo "nfcxx-linkargs: $pass passed, $fail failed"
[ "$fail" = 0 ]

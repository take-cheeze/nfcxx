#!/bin/bash
# Compares scripts/nfcxx-gcc-plan.rb (the port) with nfcxx's bash on the gcc backend, for each argument list of the case sets.
#
# The oracle is the bash: a copy of nfcxx in a sandbox, run to its end. The sandbox has the repository's scripts, except
# ehshim.rb, asan-vla, cuda-cub and cuda-driver-shim.rb, which are stubs. Commands on the gcc path are stubs (stub.sh,
# linked under the command names in the sandbox's bin directory and at build/edg/bin/eccp):
#   gcc, cc, g++  probes answer from facts.txt; the compiles and links, and nfcxx's exec of g++ -E, are logged, not run
#   cp            logged (CP), not copied
#   mktemp -d     a directory under the sandbox's tmp, printed as TMP (plain mktemp: a file there, as the cache lookup's statements)
#   eccp          logged (RUN), with ENV for EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS
#   ehshim.rb, asan-vla, cuda-cub, cuda-driver-shim.rb: the facts' values; uname -m: the fact machine
#   ninja         logged (RUN); a repository tool is built on first use, and the sandbox's copy counts as built
# Everything else (rm, sed, awk, grep, cuda-driver-wrap.sh, ...) runs for real. The bash runs under env -i (no NFCXX_*
# variables; CUDA_HOME only when the facts have a cuda-home line) in the sandbox's work directory, whose files and
# directories are the "exists" and "dir" facts. In the output the sandbox's repository is ROOT, its work directory WORK,
# its temporary directories TMP.
#
# The case sets: cases.txt with facts.txt; cases-cuda-home.txt with facts.txt and CUDA_HOME (cuda); cases-shim-error.txt
# with facts.txt and a failing cuda-driver-shim. With an argument, only that cases file runs, with facts.txt.
#
# The port gets the same facts (the facts file) and the same arguments. A case the port refuses (exit 3) is listed as
# unported with its reason and not compared; every other case must print the same lines and exit status as the bash (the
# stderr text is not compared).
#
#   bash tests/nfcxx-gcc/run.sh [CASES]
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0; unp=0; unported_list=""; failed_list=""

# run_set CASES EXTRA: the cases of CASES, with facts.txt and the lines EXTRA (a string; may be empty)
run_set() {
  local cases=$1 extra=$2 sb root work bin tmp f s c line args port_out orc oracle_out cuda_home x k p n
  sb=$(mktemp -d)
  root=$sb/root; work=$sb/work; bin=$sb/bin; tmp=$sb/tmp
  mkdir -p "$root/build/edg/bin" "$root/build/edg/lib" "$bin" "$work" "$tmp" "$root/build/asan"
  cp -r "$repo/scripts" "$root/scripts"
  # the copy of nfcxx, unchanged: the commands after the eccp call (the cache store, the second CUDA pass, the depmode step)
  # run as they do; with the cache off and no CUDA input they print nothing, except the depmode step, which is ported
  cp "$repo/nfcxx" "$root/nfcxx"
  chmod +x "$root/nfcxx"
  for s in ehshim.rb asan-vla.rb cuda-cub.rb cuda-driver-shim.rb; do ln -sf "$here/stub.sh" "$root/scripts/$s"; done
  for c in gcc cc g++ cp mktemp ninja uname; do ln -s "$here/stub.sh" "$bin/$c"; done
  # the repository's tools are built (ensure_tool finds them fresh: no ninja run); the sandbox has no tool sources
  : > "$root/build/cuda-rewrite"; chmod +x "$root/build/cuda-rewrite"
  ln -s "$here/stub.sh" "$root/build/edg/bin/eccp"
  # the work directory: the sources and objects the cases name, a module source, and the directories
  mkdir -p "$work/inc" "$work/sub" "$work/libs"
  for f in a.cc b.cc c.c d.c x.o y.o libq.a pre.h; do : > "$work/$f"; done
  printf 'export module m;\n' > "$work/mod.cc"
  { cat "$here/facts.txt"; [ -z "$extra" ] || printf '%s\n' "$extra"; } > "$sb/facts"
  # the CUDA toolkits the facts name (files, headers with a CUDART_VERSION, directories), then the exists and dir lines
  while read -r k p n; do
    case $k in
      cuda-file) mkdir -p "$work/$(dirname "$p")"; : > "$work/$p" ;;
      cuda-rtv) mkdir -p "$work/$(dirname "$p")"; printf '#define CUDART_VERSION %s\n' "$n" > "$work/$p" ;;
      cuda-dir) mkdir -p "$work/$p" ;;
    esac
  done < "$sb/facts"
  (cd "$work" && find . -mindepth 1 -printf '%y %P\n' | sort -k2) \
    | awk '{ print "exists " $2; if ($1 == "d") print "dir " $2 }' >> "$sb/facts"
  cuda_home=$(awk '$1 == "cuda-home" { print $2; exit }' "$sb/facts")
  # the ld.NAME stubs (-fuse-ld=NAME): the facts' ld lines
  awk '$1 == "ld" { print $2 }' "$sb/facts" | while read -r x; do ln -s "$here/stub.sh" "$bin/ld.$x"; done

  # the NFCXX_* variables of the facts' env lines, for the bash (the port reads the same lines)
  mapfile -t envs < <(awk '$1 == "env" { print $2 "=" $3 }' "$sb/facts")
  while IFS= read -r line; do
    case $line in ""|"#"*) continue ;; esac
    read -r -a args <<< "$line"
    port_out=$(ruby "$repo/scripts/nfcxx-gcc-plan.rb" --facts="$sb/facts" "${args[@]}" 2>"$sb/perr"); rc=$?
    # the --shell form of the same plan: its round trip (eval, then the lines in the default form) must be the plan's lines
    shell_out=$(ruby "$repo/scripts/nfcxx-gcc-plan.rb" --shell --facts="$sb/facts" "${args[@]}" 2>/dev/null); src=$?
    if [ $rc = 3 ]; then
      unp=$((unp + 1)); unported_list+="  $line
      $(head -1 "$sb/perr")
"
      # the marker alone, with status 3: the driver goes on by itself
      if [ "$src" != 3 ] || [ "$shell_out" != "nfcxx_plan_state=UNPORTED" ]; then
        fail=$((fail + 1)); failed_list+="== $line (shell form: unported marker)
--- shell
$shell_out
status $src
"
      fi
      continue
    fi
    shell_rt=$(shell_lines "$shell_out")
    : > "$sb/stublog"
    (cd "$work" && env -i RUBY="$(command -v ruby)" PATH="$bin:/usr/bin:/bin" NFCXX_FACTS="$sb/facts" NFCXX_STUB_LOG="$sb/stublog" \
       NFCXX_STUB_TMP="$tmp" NFCXX_STUB_ROOT="$root" ${cuda_home:+CUDA_HOME=$cuda_home} ${envs[@]+"${envs[@]}"} \
       bash "$root/nfcxx" "${args[@]}" >/dev/null 2>"$sb/oerr"); orc=$?
    oracle_out=$(sed -e "s#$tmp/[^/]*#TMP#g" -e "s#$work#WORK#g" -e "s#$root#ROOT#g" "$sb/stublog"; echo "STATUS $orc")
    if [ "$port_out" = "$oracle_out" ] && [ "$shell_rt" = "$port_out" ] && [ "$src" = "$rc" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1)); failed_list+="== $line
--- port
$port_out
--- shell form (round trip)
$shell_rt
--- bash
$oracle_out
--- bash stderr
$(head -3 "$sb/oerr")
"
    fi
  done < "$cases"
  rm -rf "$sb"
}

# shell_lines TEXT: the plan's lines in the default form (kind, then the words; then STATUS), from the --shell statements TEXT
# (evaluated here, in a subshell: the variables are the nfcxx_plan_* ones). An UNPORTED plan is its state, alone.
shell_lines() {
  (
    eval "$1" || { echo "not shell"; exit 0; }
    [ "$nfcxx_plan_state" = PLAN ] || { echo "state $nfcxx_plan_state"; exit 0; }
    pos=0
    for i in "${!nfcxx_plan_kinds[@]}"; do
      n=${nfcxx_plan_nwords[i]}; line=${nfcxx_plan_kinds[i]}
      for ((k = 0; k < n; k++)); do line+=" ${nfcxx_plan_words[pos + k]}"; done
      pos=$((pos + n))
      echo "$line"
    done
    echo "STATUS $nfcxx_plan_status"
  )
}

# shell_units: the --shell form checked against its exact text (the port with the facts file, no bash)
shell_units() {
  local f=$here/facts.txt p=$repo/scripts/nfcxx-gcc-plan.rb out st want want_st name
  check_unit() {  # check_unit NAME WANT-STATUS WANT-TEXT ARGS...: the --shell output of ARGS is WANT-TEXT, status WANT-STATUS
    local name=$1 want_st=$2 want=$3; shift 3
    out=$(ruby "$p" --shell --facts="$f" "$@" 2>/dev/null); st=$?
    if [ "$st" = "$want_st" ] && [ "$out" = "$want" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1)); failed_list+="== shell unit: $name
--- want (status $want_st)
$want
--- got (status $st)
$out
"
    fi
  }
  check_unit "unported marker" 3 "nfcxx_plan_state=UNPORTED" a.cc -o prog
  check_unit "unported marker for a Path B link" 3 "nfcxx_plan_state=UNPORTED" --backend=pathb a.cc -o prog
  check_unit "refusal keeps status" 2 "nfcxx_plan_state=PLAN
nfcxx_plan_status=2
nfcxx_plan_kinds=()
nfcxx_plan_nwords=()
nfcxx_plan_words=()" --backend=gcc
  check_unit "escaped word" 0 "nfcxx_plan_state=PLAN
nfcxx_plan_status=0
nfcxx_plan_kinds=(RUN)
nfcxx_plan_nwords=(31)
nfcxx_plan_words=(ROOT/build/edg/bin/eccp --c++23 --g++ --wdir / --no_auto_instantiation -tused --c_to_obj_option -ffunction-sections --c_to_obj_option -fdata-sections --c_to_obj_option -Wl,--gc-sections --sys_include\\=/fx/include/c++/13 --sys_include\\=/fx/include/x86_64-linux-gnu/c++/13 --sys_include\\=/fx/include --c_to_obj_lib\\=m --c_to_obj_option -O2 --c_to_obj_option -fwrapv --c_to_obj_option -fno-strict-aliasing --c_to_obj_option -fkeep-static-functions --c_to_obj_option -fgnu89-inline -c a.cc -o a.o)" --backend=gcc -c a.cc -o a.o
  # a word with a space is one word after the eval: the planner's -include argument is pre h.h, as the bash passes it
  out=$(ruby "$p" --shell --facts="$f" --backend=gcc -include 'pre h.h' -c a.cc -o a.o 2>/dev/null)
  if (eval "$out" && printf '%s\n' "${nfcxx_plan_words[@]}" | grep -Fxq 'pre h.h'); then pass=$((pass + 1))
  else fail=$((fail + 1)); failed_list+="== shell unit: one word with a space (eval gives pre h.h as one word)
$out
"
  fi
}

# live_units: the NFCXX_BACKEND rule of the live facts, on a fake repository (an eccp and libC.a that exist, no toolkit): the
# environment is cleared, so only the variables the check sets are read
live_units() {
  local sb root work out st
  sb=$(mktemp -d); root=$sb/root; work=$sb/work
  mkdir -p "$root/build/edg/bin" "$root/build/edg/lib" "$work"
  printf '#!/bin/sh\nexit 0\n' > "$root/build/edg/bin/eccp"; chmod +x "$root/build/edg/bin/eccp"
  : > "$root/build/edg/lib/libC.a"; : > "$work/a.cc"
  # live BACKEND-OR-EMPTY [--shell] ARGS...: the planner in the work directory, with NFCXX_BACKEND as given (or unset)
  live() {
    local be=$1 mode=""; shift
    if [ "${1:-}" = --shell ]; then mode=--shell; shift; fi
    (cd "$work" && env -i PATH="$PATH" ${be:+NFCXX_BACKEND=$be} ruby "$repo/scripts/nfcxx-gcc-plan.rb" $mode --live="$root" "$@")
  }
  # check_live NAME WANT-STATUS WANT-PATTERN ACTUAL-STATUS OUTPUT-FILE: the status, and the output matches WANT-PATTERN (grep -E;
  # "EMPTY": the output is empty)
  check_live() {
    local ok=0
    if [ "$3" = EMPTY ]; then [ -s "$5" ] || ok=1; else grep -Eq -- "$3" "$5" && ok=1; fi
    if [ "$4" = "$2" ] && [ $ok = 1 ]; then pass=$((pass + 1))
    else fail=$((fail + 1)); failed_list+="== live unit: $1
--- want status $2, output $3
--- got status $4
$(cat "$5")
"
    fi
  }
  live gcc -c a.cc -o a.o > "$sb/o1"; st=$?
  check_live "NFCXX_BACKEND=gcc plans the compile" 0 "^RUN ROOT/build/edg/bin/eccp " $st "$sb/o1"
  live gcc --shell -c a.cc -o a.o > "$sb/o2"; st=$?
  check_live "NFCXX_BACKEND=gcc, shell form" 0 "^nfcxx_plan_state=PLAN$" $st "$sb/o2"
  live pathb -c a.cc -o a.o > "$sb/o3" 2>"$sb/lerr"; st=$?
  check_live "NFCXX_BACKEND=pathb is unported" 3 EMPTY $st "$sb/o3"
  grep -q "environment NFCXX_BACKEND" "$sb/lerr" || { fail=$((fail + 1)); failed_list+="== live unit: NFCXX_BACKEND=pathb reason
$(cat "$sb/lerr")
"; }
  live "" -c a.cc -o a.o > "$sb/o4" 2>/dev/null; st=$?
  check_live "no NFCXX_BACKEND: the default is Path B, unported" 3 EMPTY $st "$sb/o4"
  rm -f "$root/build/edg/bin/eccp"
  live gcc --shell -c a.cc -o a.o > "$sb/o5" 2>/dev/null; st=$?
  check_live "no eccp: unported marker" 3 "^nfcxx_plan_state=UNPORTED$" $st "$sb/o5"
  rm -rf "$sb"
}

if [ -n "${1:-}" ]; then
  run_set "$1" ""
else
  run_set "$here/cases.txt" ""
  run_set "$here/cases-cuda-home.txt" "cuda-home cuda"
  run_set "$here/cases-shim-error.txt" "cuda-shim-error scripts/cuda-driver-shim.rb: the shim does not build here"
  run_set "$here/cases-env-backend.txt" "env NFCXX_BACKEND gcc"
  shell_units
  live_units
fi

[ -z "$failed_list" ] || printf '%s' "$failed_list"
echo "passed $pass, failed $fail, unported $unp"
[ -z "$unported_list" ] || { echo "unported (reason from the port):"; printf '%s' "$unported_list"; }
[ "$fail" = 0 ]

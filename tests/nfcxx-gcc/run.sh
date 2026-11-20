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
# The helper calls the plan covers run through a RUBY wrapper that logs them (RUN, CHECK, STORE: scripts/nfcxx-link.rb and
# scripts/nfcxx-cache-check.rb, by subcommand) and then runs ruby. The statement and entry paths of a cache lookup are
# normalized (STATE, ENTRY); a STORE the bash does not run (no cache entry) is dropped from the port's lines.
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
  # the RUBY the bash runs (${RUBY:-ruby}): logs the helper calls the plan covers, then runs the real ruby
  cat > "$sb/ruby-log" <<'RUBYLOG'
#!/bin/bash
case $1 in
  *nfcxx-link.rb)
    case $2 in cleanup) k=EXIT ;; *) k=RUN ;; esac
    printf '%s ruby %s\n' "$k" "$*" >> "$NFCXX_STUB_LOG" ;;
  *nfcxx-cache-check.rb)
    case $2 in check) k=CHECK ;; store) k=STORE ;; *) k=RUN ;; esac
    printf '%s ruby %s\n' "$k" "$*" >> "$NFCXX_STUB_LOG" ;;
esac
exec "$NFCXX_REAL_RUBY" "$@"
RUBYLOG
  chmod +x "$sb/ruby-log"
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
    port_cmp=$(norm_plan "$port_out")
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
    (cd "$work" && env -i RUBY="$sb/ruby-log" NFCXX_REAL_RUBY="$(command -v ruby)" PATH="$bin:/usr/bin:/bin" NFCXX_FACTS="$sb/facts" NFCXX_STUB_LOG="$sb/stublog" \
       NFCXX_STUB_TMP="$tmp" NFCXX_STUB_ROOT="$root" ${cuda_home:+CUDA_HOME=$cuda_home} ${envs[@]+"${envs[@]}"} \
       bash "$root/nfcxx" "${args[@]}" >/dev/null 2>"$sb/oerr"); orc=$?
    oracle_out=$(sed -e "s#$tmp/[^/ ]*#TMP#g" -e "s#$work#WORK#g" -e "s#$root#ROOT#g" "$sb/stublog" | norm_plan_stdin; echo "STATUS $orc")
    # the STORE runs only when the lookup set a cache entry: a port line the bash did not run is not compared
    if ! grep -q '^STORE ' <<<"$oracle_out"; then port_cmp=$(grep -v '^STORE ' <<<"$port_cmp"); shell_rt=$(grep -v '^STORE ' <<<"$shell_rt"); fi
    # the note of a kept directory: the port's NOTE line is the bash's stderr line (the directory is TMP in both)
    note_port=$(sed -n 's/^NOTE //p' <<<"$port_out")
    note_bash=$(grep -F 'intermediates kept in' "$sb/oerr" | sed -e "s#$tmp/[^/ ]*#TMP#g")
    port_cmp=$(grep -v '^NOTE ' <<<"$port_cmp"); shell_rt=$(grep -v '^NOTE ' <<<"$shell_rt")
    oracle_out=$(grep -v '^NOTE ' <<<"$oracle_out")
    if [ "$port_cmp" = "$oracle_out" ] && [ "$shell_rt" = "$port_cmp" ] && [ "$src" = "$rc" ] && [ "$note_port" = "$note_bash" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1)); failed_list+="== $line
--- port
$port_cmp
--- shell form (round trip)
$shell_rt
--- bash
$oracle_out
--- note: port [$note_port] bash [$note_bash]
--- bash stderr
$(head -3 "$sb/oerr")
"
    fi
  done < "$cases"
  rm -rf "$sb"
}

# norm_plan TEXT / norm_plan_stdin: the cache statement and entry paths, which differ between runs (STATE, ENTRY); the
# placeholders of --shell words are shown as their names
norm_plan() { printf '%s\n' "$1" | norm_plan_stdin; }
norm_plan_stdin() { sed -e 's#--statements=[^ ]*#--statements=STATE#' -e 's#--entry=[^ ]*#--entry=ENTRY#'; }

# shell_lines TEXT: the plan's lines in the default form (kind, then the words; then STATUS), from the --shell statements TEXT
# (evaluated here, in a subshell: the variables are the nfcxx_plan_* ones). An UNPORTED plan is its state, alone.
shell_lines() {
  (
    eval "$1" || { echo "not shell"; exit 0; }
    [ "$nfcxx_plan_state" = PLAN ] || { echo "state $nfcxx_plan_state"; exit 0; }
    pos=0
    for i in "${!nfcxx_plan_kinds[@]}"; do
      n=${nfcxx_plan_nwords[i]}; line=${nfcxx_plan_kinds[i]}
      for ((k = 0; k < n; k++)); do
        w=${nfcxx_plan_words[pos + k]}
        # the placeholders, as the driver substitutes them (ROOT, WORK, TMP, ECCP, RUBY, ENTRY: the default form's names)
        w=${w//@@NFCXX_ROOT@@/ROOT}; w=${w//@@NFCXX_WORK@@/WORK}; w=${w//@@NFCXX_TMP@@/TMP}
        w=${w//@@NFCXX_ECCP@@/TMP}; w=${w//@@NFCXX_RUBY@@/ruby}; w=${w//@@NFCXX_ENTRY@@/ENTRY}
        line+=" $w"
      done
      pos=$((pos + n))
      echo "$(norm_plan_stdin <<<"$line")"
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
nfcxx_plan_keep=0
nfcxx_plan_uses=()
nfcxx_plan_kinds=()
nfcxx_plan_nwords=()
nfcxx_plan_words=()" --backend=gcc
  check_unit "escaped word" 0 "nfcxx_plan_state=PLAN
nfcxx_plan_status=0
nfcxx_plan_keep=0
nfcxx_plan_uses=()
nfcxx_plan_kinds=(RUN RUN RUN RUN)
nfcxx_plan_nwords=(5 6 31 6)
nfcxx_plan_words=(@@NFCXX_RUBY@@ @@NFCXX_ROOT@@/scripts/nfcxx-link.rb compile-clean a.o a.cc @@NFCXX_RUBY@@ @@NFCXX_ROOT@@/scripts/nfcxx-link.rb records-rm -- -c a.cc @@NFCXX_ROOT@@/build/edg/bin/eccp --c++23 --g++ --wdir / --no_auto_instantiation -tused --c_to_obj_option -ffunction-sections --c_to_obj_option -fdata-sections --c_to_obj_option -Wl,--gc-sections --sys_include\\=/fx/include/c++/13 --sys_include\\=/fx/include/x86_64-linux-gnu/c++/13 --sys_include\\=/fx/include --c_to_obj_lib\\=m --c_to_obj_option -O2 --c_to_obj_option -fwrapv --c_to_obj_option -fno-strict-aliasing --c_to_obj_option -fkeep-static-functions --c_to_obj_option -fgnu89-inline -c a.cc -o a.o @@NFCXX_RUBY@@ @@NFCXX_ROOT@@/scripts/nfcxx-link.rb records-rm -- -c a.cc)" --backend=gcc -c a.cc -o a.o
  # a word with a space is one word after the eval: the planner's -include argument is pre h.h, as the bash passes it
  out=$(ruby "$p" --shell --facts="$f" --backend=gcc -include 'pre h.h' -c a.cc -o a.o 2>/dev/null)
  if (eval "$out" && printf '%s\n' "${nfcxx_plan_words[@]}" | grep -Fxq 'pre h.h'); then pass=$((pass + 1))
  else fail=$((fail + 1)); failed_list+="== shell unit: one word with a space (eval gives pre h.h as one word)
$out
"
  fi
}

# contract_units: the --shell statements of the plan's order and placeholders (the driver's contract, nfcxx-gcc-plan.rb's header).
# Each case: the kinds in order (gaps 1 to 4 and 6: the records steps, the cache lookup and store, the note, the eccp directory,
# the exit cleanup, the dependency file), the directories the driver makes (nfcxx_plan_uses), and the keep flag. Every
# placeholder in the words is one of the contract's names.
contract_units() {
  local out kinds uses keep w bad
  shell_plan() { ruby "$repo/scripts/nfcxx-gcc-plan.rb" --shell --facts="$here/facts.txt" "$@" 2>/dev/null; }
  check_contract() {  # check_contract NAME WANT-KINDS WANT-USES WANT-KEEP ARGS...
    local name=$1 want_kinds=$2 want_uses=$3 want_keep=$4; shift 4
    out=$(shell_plan "$@")
    ( eval "$out" || exit 1
      [ "${nfcxx_plan_kinds[*]}" = "$want_kinds" ] || { echo "kinds: ${nfcxx_plan_kinds[*]}"; exit 1; }
      [ "${nfcxx_plan_uses[*]-}" = "$want_uses" ] || { echo "uses: ${nfcxx_plan_uses[*]-}"; exit 1; }
      [ "$nfcxx_plan_keep" = "$want_keep" ] || { echo "keep: $nfcxx_plan_keep"; exit 1; }
      for w in "${nfcxx_plan_words[@]}"; do
        printf '%s\n' "$w" | grep -o '@@NFCXX_[A-Z]*@@' | while read -r t; do
          case $t in @@NFCXX_ROOT@@|@@NFCXX_WORK@@|@@NFCXX_TMP@@|@@NFCXX_ECCP@@|@@NFCXX_RUBY@@|@@NFCXX_ENTRY@@) ;; *) echo "unknown placeholder $t"; exit 1 ;; esac
        done
      done ) > "$sb_contract" 2>&1
    if [ $? = 0 ] && [ ! -s "$sb_contract" ]; then pass=$((pass + 1))
    else fail=$((fail + 1)); failed_list+="== contract unit: $name
$(cat "$sb_contract")
"; fi
  }
  sb_contract=$(mktemp)
  # a link: the records, the eccp call in its directory (CD), the exit cleanup last; the directory is the eccp one (ECCP)
  check_contract "link: records, CD before eccp, EXIT last" "RUN CD RUN RUN EXIT" "ECCP" 0 --backend=gcc a.cc -o prog
  # gap 4: the note of a kept directory comes first, and the cleanup keeps the directory (keep flag 1)
  check_contract "link with --keep-intermediates: NOTE first, keep 1" "NOTE RUN CD RUN RUN EXIT" "ECCP" 1 --backend=gcc --keep-intermediates a.cc -o prog
  # gap 1: a -c with a cache: the lookup before the eccp call, the store after it; the statements file is in the TMP directory
  check_contract "-c with --cache: CHECK before eccp, STORE after" "RUN RUN CHECK RUN RUN STORE" "TMP" 0 --backend=gcc --cache=cachedir -c a.cc -o a.o
  # gap 2: a -c compiles with the records steps around it; no temporary directory, no cleanup
  check_contract "-c: compile-clean, records, eccp, records" "RUN RUN RUN RUN" "" 0 --backend=gcc -c a.cc -o a.o
  # gap 6: -MD on a -c without -o: the object is a.o and the file a.d (the dependency command is the last line)
  check_contract "-c -MD without -o: dependency command last" "RUN RUN RUN RUN RUN" "" 0 --backend=gcc -c -MD a.cc
  rm -f "$sb_contract"
  # gap 6: the dependency file of a dotted directory is the text before the object's last dot, as the bash names it
  out=$(shell_plan --backend=gcc -c -MD a.cc -o x.y/out.o)
  if (eval "$out"; last=$((nfcxx_plan_nwords[${#nfcxx_plan_kinds[@]} - 1])); words=("${nfcxx_plan_words[@]: -$last}"); [ "${words[*]}" = "g++ -M -MT x.y/out.o -MF x.y/out.d -std=c++23 a.cc" ]); then
    pass=$((pass + 1))
  else fail=$((fail + 1)); failed_list+="== contract unit: -MD dependency file of x.y/out.o
$out
"; fi
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
  rm -f "$root/build/edg/bin/eccp"; printf '#!/bin/sh\nexit 0\n' > "$root/build/edg/bin/eccp"; chmod +x "$root/build/edg/bin/eccp"
  # the driver exports NFCXX_TRACE_UNIT itself (its name only: with NFCXX_TRACE unset, nothing is traced): planned
  (cd "$work" && env -i PATH="$PATH" NFCXX_BACKEND=gcc NFCXX_TRACE_UNIT=a.o ruby "$repo/scripts/nfcxx-gcc-plan.rb" --shell --live="$root" -c a.cc -o a.o) > "$sb/o6" 2>/dev/null; st=$?
  check_live "NFCXX_TRACE_UNIT (the driver's export) is planned" 0 "^nfcxx_plan_state=PLAN$" $st "$sb/o6"
  (cd "$work" && env -i PATH="$PATH" NFCXX_BACKEND=gcc NFCXX_TRACE=1 ruby "$repo/scripts/nfcxx-gcc-plan.rb" --shell --live="$root" -c a.cc -o a.o) > "$sb/o7" 2>/dev/null; st=$?
  check_live "NFCXX_TRACE is unported" 3 "^nfcxx_plan_state=UNPORTED$" $st "$sb/o7"
  # the include directories of a link are named as the bash's abs_path names them: the real path of the directory, then the base
  # name (so a root-level name is //NAME), and a symbolic link is resolved
  mkdir -p "$work/real/x"; ln -sfn "$work/real" "$work/linkdir"
  phys=$(cd "$work/real" && pwd -P)
  (cd "$work" && env -i PATH="$PATH" NFCXX_BACKEND=gcc ruby "$repo/scripts/nfcxx-gcc-plan.rb" --shell --live="$root" a.cc -I/usr -Ilinkdir/x -o prog) > "$sb/o9" 2>/dev/null; st=$?
  if [ "$st" = 0 ] && (eval "$(cat "$sb/o9")"; printf '%s\n' "${nfcxx_plan_words[@]}" | grep -Fxq -- "-I//usr" && printf '%s\n' "${nfcxx_plan_words[@]}" | grep -Fxq -- "-I$phys/x"); then
    pass=$((pass + 1))
  else fail=$((fail + 1)); failed_list+="== live unit: -I names (abs_path: //usr, the real path of a symbolic link)
$(cat "$sb/o9")
"; fi
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
  contract_units
  live_units
fi

[ -z "$failed_list" ] || printf '%s' "$failed_list"
echo "passed $pass, failed $fail, unported $unp"
[ -z "$unported_list" ] || { echo "unported (reason from the port):"; printf '%s' "$unported_list"; }
[ "$fail" = 0 ]

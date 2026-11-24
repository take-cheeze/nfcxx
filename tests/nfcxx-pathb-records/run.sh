#!/bin/bash
# Checks scripts/nfcxx-pathb.rb --records (the Path B -c route planned from the driver's state records, the header of the port):
# each case is a state (the groups state_put writes) and the lines it must plan, in text and as --shell statements. The --shell
# output is evaluated by bash, and its words are compared with the text lines, so the eval'd plan is the one the driver runs.
# The refusals (exit 2) are the states the driver never sends.
#
#   bash tests/nfcxx-pathb-records/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
planner=$repo/scripts/nfcxx-pathb.rb
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi; }

# sg NAME VALUE...: one group, as state_put writes it (k NAME, then v VALUE for each value, NUL-terminated)
sg() { local n=$1; shift; printf 'k%s\0' "$n"; for v in ${1+"$@"}; do printf 'v%s\0' "$v"; done; }
# st: the state of a -c of one source, the driver's values; the variables below change one case
ROOT_DIR=/r
st() {
  sg root "$ROOT_DIR"; sg backend "${BACKEND:-pathb}"; sg default_backend "${DB:-1}"; sg compile_only "${CO:-1}"
  sg ncpp "${NCPP:-1}"; sg outset "${OS:-0}"; sg out "${OUT:-a.o}"; sg std "${STD:---c++23}"
  sg srcs ${SRCS:-a/foo.cc}; sg files ${FILES:--I/x a/foo.cc}; sg cflags ${CFLAGS:--I/x}
  sg pb_flags ${PBF:-}; sg pb_pre ${PBPRE:-}; sg cuda_opts ${CUDA:-}
  sg modules "${MOD:-0}"; sg modopts ${MODOPTS:-}; sg nfcxx_argv -c a/foo.cc; sg cache_entry "${CE:-}"
}
# expect NAME EXPECTED: the text output of the current st state equals EXPECTED
expect() {
  local got; got=$(st | ruby "$planner" --records 2>/dev/null); local rc=$?
  if [ "$rc" = 0 ] && [ "$got" = "$2" ]; then check "$1" 0; else check "$1" 1; printf '%s\n' "--- got ($rc)" "$got" "--- want" "$2" >&2; fi
}
# refuse NAME: the planner refuses the current state (exit 2, nothing on standard output)
refuse() {
  local got; got=$(st | ruby "$planner" --records 2>/dev/null); local rc=$?
  if [ "$rc" = 2 ] && [ -z "$got" ]; then check "$1" 0; else check "$1" 1; fi
}

# the default backend: the compile, then the rule for its status (gcc, with the driver's argv)
exp_default="RUN	/r/scripts/pathb-cc.rb	-std=c++23	-I/x	a/foo.cc	-o	foo.o
CHECK	gcc	nfcxx: Path B did not build a/foo.cc (status 	); building the program with the gcc backend, which compiles with C semantics (-fwrapv -fno-strict-aliasing)	env	NFCXX_BACKEND=gcc	/r/nfcxx	-c	a/foo.cc"
unset OS OUT FILES CFLAGS
expect "default backend: no -o names the object by the source (foo.o), the gcc rule" "$exp_default"

# an explicit --backend=pathb: the rule is the exit
exp_exit="RUN	/r/scripts/pathb-cc.rb	-std=c++23	-I/x	a/foo.cc	-o	foo.o
CHECK	exit"
DB=0 expect "--backend=pathb: the status ends the driver" "$exp_exit"
unset DB

# -o names the one object
exp_o="RUN	/r/scripts/pathb-cc.rb	-std=c++23	-I/x	a/foo.cc	-o	out/x.o
CHECK	gcc	nfcxx: Path B did not build a/foo.cc (status 	); building the program with the gcc backend, which compiles with C semantics (-fwrapv -fno-strict-aliasing)	env	NFCXX_BACKEND=gcc	/r/nfcxx	-c	a/foo.cc"
OS=1 OUT=out/x.o expect "-o: the output names the object" "$exp_o"
unset OS OUT

# the options of the state reach pathb-cc in the bash's order: pb_flags, -std, cflags, pb_pre, cuda_opts, modopts, the input
exp_order="RUN	/r/scripts/pathb-cc.rb	--asan	--pic	-std=c++20	-DX=1	-include	pre.h	--cuda	--modules	--modules_directory	/m	a/foo.cc	-o	foo.o
CHECK	exit"
DB=0 STD=--c++20 CFLAGS="-DX=1" PBF="--asan --pic" PBPRE="-include pre.h" CUDA="--cuda" MOD=1 MODOPTS="--modules --modules_directory /m" expect "argument order: pb_flags, -std, cflags, pb_pre, cuda_opts, modopts" "$exp_order"
unset DB STD CFLAGS PBF PBPRE CUDA MOD MODOPTS

# modopts are the module scan's: with modules 0 they are not on the command line, and with modules 0 they must be empty (refused)
exp_nomod="RUN	/r/scripts/pathb-cc.rb	-std=c++23	-I/x	a/foo.cc	-o	foo.o
CHECK	exit"
DB=0 MODOPTS="" expect "modules 0: no module options" "$exp_nomod"
DB=0 MODOPTS="--modules" refuse "modopts without modules is refused"
unset DB MODOPTS

# .cu inputs: their host copies are the files (the object takes the copy's basename)
exp_cu="RUN	/r/scripts/pathb-cc.rb	-std=c++23	-I/x	/cache/k/kern.cu	-o	kern.o
CHECK	gcc	nfcxx: Path B did not build /cache/k/kern.cu (status 	); building the program with the gcc backend, which compiles with C semantics (-fwrapv -fno-strict-aliasing)	env	NFCXX_BACKEND=gcc	/r/nfcxx	-c	a/foo.cc"
FILES="-I/x /cache/k/kern.cu" expect "a .cu copy: the object takes the copy's basename" "$exp_cu"
unset FILES

# several inputs: the options and the link files are skipped, each input is compiled and checked, in order
exp_multi="RUN	/r/scripts/pathb-cc.rb	-std=c++23	-I/x	a/foo.cc	-o	foo.o
CHECK	exit
RUN	/r/scripts/pathb-cc.rb	-std=c++23	-I/x	b/bar.cc	-o	bar.o
CHECK	exit"
DB=0 FILES="-I/x a/foo.cc -lm libq.a x.o -Wl,-z,now b/bar.cc" SRCS="a/foo.cc b/bar.cc" expect "several inputs: options and link files skipped" "$exp_multi"
unset DB FILES SRCS

# the cache: an entry with one source stores the object after the compiles; none without an entry, nor with two sources
exp_store="RUN	/r/scripts/pathb-cc.rb	-std=c++23	-I/x	a/foo.cc	-o	foo.o
CHECK	exit
STORE	foo.o"
DB=0 OS=0 OUT=foo.o CE=entry expect "cache entry: STORE after the compile" "$(printf '%s\n' "RUN	/r/scripts/pathb-cc.rb	-std=c++23	-I/x	a/foo.cc	-o	foo.o" "CHECK	exit" "STORE	foo.o")"
unset DB OS OUT CE
DB=0 CE=entry SRCS="a/foo.cc b/bar.cc" FILES="-I/x a/foo.cc b/bar.cc" expect "cache entry, two sources: no STORE" "$(printf '%s\n' "RUN	/r/scripts/pathb-cc.rb	-std=c++23	-I/x	a/foo.cc	-o	foo.o" "CHECK	exit" "RUN	/r/scripts/pathb-cc.rb	-std=c++23	-I/x	b/bar.cc	-o	bar.o" "CHECK	exit")"
unset DB CE SRCS FILES

# refusals: the states the driver never sends
BACKEND=gcc refuse "backend gcc: refused"
CO=0 refuse "compile_only 0: refused"
NCPP=0 refuse "ncpp 0: refused"
MOD=2 refuse "modules 2: refused"
unset BACKEND CO NCPP MOD

# a group that is missing, or a scalar with two values, is refused
printf 'kroot\0v%s\0' /r | ruby "$planner" --records >/dev/null 2>&1; rc=$?
check "a missing group is refused (exit 2)" $([ "$rc" = 2 ] && echo 0 || echo 1)
{ st; sg std --c++20 --c++23; } | ruby "$planner" --records >/dev/null 2>&1; rc=$?
check "a scalar with two values is refused (exit 2)" $([ "$rc" = 2 ] && echo 0 || echo 1)

# --shell: the statements bash evals give the same words as the text lines (kind first, then its words, nwords counts them)
shell_ok() {
  local text shell
  text=$(st | ruby "$planner" --records) || return 1
  shell=$(st | ruby "$planner" --records --shell) || return 1
  (
    eval "$shell"
    local i w=0 n line
    for ((i = 0; i < ${#nfcxx_plan_kinds[@]}; i++)); do
      n=${nfcxx_plan_nwords[i]}
      line=${nfcxx_plan_kinds[i]}
      local j
      for ((j = 0; j < n; j++)); do line+=$'\t'"${nfcxx_plan_words[w + j]}"; done
      w=$((w + n))
      printf '%s\n' "$line"
    done
  ) > "$tmpd/eval.out"
  [ "$(cat "$tmpd/eval.out")" = "$text" ]
}
tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
DB=0 shell_ok; check "--shell: the eval'd words are the text lines (backend pathb)" $?
DB=1 CE=entry OUT=o.o OS=1 shell_ok; check "--shell: the eval'd words are the text lines (gcc rule, STORE)" $?
DB=1 MOD=1 MODOPTS="--modules --modules_directory /d e" FILES="-I/x a/foo.cc" shell_ok; check "--shell: words with spaces and a message with specials" $?
unset DB CE OUT OS MOD MODOPTS FILES

echo "nfcxx-pathb records: $pass passed, $fail failed"
[ "$fail" = 0 ]

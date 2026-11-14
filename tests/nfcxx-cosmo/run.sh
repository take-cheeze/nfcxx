#!/bin/bash
# Compares scripts/nfcxx-cosmo.rb (the port) with nfcxx's bash on the --cosmo C path, for each argument list of cases.txt.
#
# The oracle is the bash: a copy of nfcxx in a sandbox, run to its end. The sandbox has the repository's scripts. ehshim and asan-vla are
# stubs (ehshim is guarded and its output is unused here; asan-vla is never run by a case, the port leaves that case
# unported). sret.rb is the real script, which on x86-64 Linux prints nothing and exits 0. The commands on the path are
# stubs (stub.sh, linked under the command names in the sandbox's bin directory and at the cosmocc locations): gcc/cc/g++ probes answer, cosmocc and the
# C compiles are logged (RUN), cp is logged (CP), and mktemp -d is a directory under the sandbox's tmp (TMP).
# The bash runs under env -i (the case's NFCXX_* words only) in the sandbox's work directory, whose files are the "exists"
# facts. In the output the sandbox's repository is ROOT, its work directory WORK, its temporary directories TMP.
#
# A word SB/REL in a case's environment names REL under the sandbox's host directory (SB/outside/cosmocc is a stand-in for a
# cosmocc outside the repository). facts.txt names such files the same way (host-exec, host-file, host-absent); run.sh creates
# them, and prints the directory as SB in the oracle's lines.
#
# The port gets the same facts (facts.txt, the host's uname and the exists lines are not needed: the port reads uname from
# the facts too) and the same arguments and environment. A case the port refuses (exit 3) is listed as unported with its
# reason and not compared; every other case must print the same lines and exit status as the bash (stderr is not compared).
#
#   bash tests/nfcxx-cosmo/run.sh [CASES]     CASES defaults to tests/nfcxx-cosmo/cases.txt
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
cases=${1:-$here/cases.txt}
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
root=$sb/root; work=$sb/work; bin=$sb/bin; tmp=$sb/tmp
mkdir -p "$root/build" "$bin" "$work/inc" "$work/sub" "$work/libs" "$tmp"
cp -r "$repo/scripts" "$root/scripts"
cp "$repo/nfcxx" "$root/nfcxx"
chmod +x "$root/nfcxx"
for s in ehshim.rb sret.rb asan-vla; do ln -sf "$here/stub.sh" "$root/scripts/$s"; done
for c in gcc cc g++ cp mktemp; do ln -s "$here/stub.sh" "$bin/$c"; done
# the repository's rewriter is built on first use (ensure_tool, every run): the sandbox's copy counts as built
: > "$root/build/cuda-rewrite"; chmod +x "$root/build/cuda-rewrite"
# the facts: the ROOT files the bash checks (root-exec: executable stand-ins named cosmocc; root-file: not executable), and the host
cp "$here/facts.txt" "$sb/facts"
while read -r kind rel; do
  case $kind in
    root-exec) mkdir -p "$(dirname "$root/$rel")"; ln -sf "$here/stub.sh" "$root/$rel" ;;
    root-file) mkdir -p "$(dirname "$root/$rel")"; : > "$root/$rel" ;;
    host-exec) mkdir -p "$(dirname "$sb/${rel#SB/}")"; ln -sf "$here/stub.sh" "$sb/${rel#SB/}" ;;
    host-file) mkdir -p "$(dirname "$sb/${rel#SB/}")"; : > "$sb/${rel#SB/}" ;;
  esac
done < "$sb/facts"
printf 'uname-s %s\nuname-m %s\n' "$(uname -s)" "$(uname -m)" >> "$sb/facts"
# the work directory: the sources the cases name, and the directories
mkdir -p "$work/inc" "$work/sub" "$work/libs"
for f in a.c b.c sub/x.c a.cpp b.o libq.a; do : > "$work/$f"; done

pass=0; fail=0; unp=0; unported_list=""; failed_list=""
while IFS= read -r line; do
  case $line in ""|"#"*) continue ;; esac
  read -r -a toks <<< "$line"
  penv=(); oenv=(); args=()
  for t in "${toks[@]}"; do
    if [ ${#args[@]} = 0 ] && [[ $t =~ ^NFCXX_[A-Z_]+= ]]; then
      penv+=("$t")
      k=${t%%=*}; v=${t#*=}
      if [[ $v == ROOT/* ]]; then v=$root/${v#ROOT/}; fi
      if [[ $v == SB/* ]]; then v=$sb/${v#SB/}; fi
      oenv+=("$k=$v")
    else
      args+=("$t")
    fi
  done
  port_out=$(env -i PATH="$PATH" ${penv[@]+"${penv[@]}"} ruby "$repo/scripts/nfcxx-cosmo.rb" --facts="$sb/facts" ${args[@]+"${args[@]}"} 2>"$sb/perr"); rc=$?
  if [ $rc = 3 ]; then
    unp=$((unp + 1)); unported_list+="  $line
      $(head -1 "$sb/perr")
"
    continue
  fi
  : > "$sb/stublog"
  (cd "$work" && env -i PATH="$bin:/usr/bin:/bin" NFCXX_STUB_LOG="$sb/stublog" NFCXX_STUB_TMP="$tmp" \
     ${oenv[@]+"${oenv[@]}"} bash "$root/nfcxx" ${args[@]+"${args[@]}"} >/dev/null 2>"$sb/oerr"); orc=$?
  oracle_out=$(sed -e "s#$tmp/[^/]*#TMP#g" -e "s#$work#WORK#g" -e "s#$root#ROOT#g" -e "s#$sb/#SB/#g" "$sb/stublog"; echo "STATUS $orc")
  if [ "$port_out" = "$oracle_out" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed_list+="== $line
--- port
$port_out
--- bash
$oracle_out
--- bash stderr
$(head -3 "$sb/oerr")
"
  fi
done < "$cases"

[ -z "$failed_list" ] || printf '%s' "$failed_list"
echo "passed $pass, failed $fail, unported $unp"
[ -z "$unported_list" ] || { echo "unported (reason from the port):"; printf '%s' "$unported_list"; }
[ "$fail" = 0 ]

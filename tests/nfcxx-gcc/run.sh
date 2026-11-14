#!/bin/bash
# Compares scripts/nfcxx-gcc-plan.rb (the port) with nfcxx's bash on the gcc backend, for each argument list of cases.txt.
#
# The oracle is the bash: a copy of nfcxx in a sandbox, run to its end. The sandbox has the repository's scripts, except
# ehshim, sret.sh and asan-vla, which are stubs. Commands on the gcc path are stubs (stub.sh, linked under the command
# names in the sandbox's bin directory and at build/edg/bin/eccp):
#   gcc, cc, g++  probes answer from facts.txt; the compiles and links, and nfcxx's exec of g++ -E, are logged, not run
#   cp            logged (CP), not copied
#   mktemp -d     a directory under the sandbox's tmp, printed as TMP
#   eccp          logged (RUN), with ENV for EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS
#   ehshim, sret.sh, asan-vla: the facts' paths
#   ninja         logged (RUN); a repository tool is built on first use, and the sandbox's copy counts as built
# Everything else (rm, sed, awk, grep, ...) runs for real. The bash runs under env -i (no NFCXX_* variables) in the
# sandbox's work directory, whose files and directories are the "exists" facts. In the output the sandbox's repository is
# ROOT, its work directory WORK, its temporary directories TMP.
#
# The port gets the same facts (facts.txt plus the exists lines) and the same arguments. A case the port refuses (exit 3)
# is listed as unported with its reason and not compared; every other case must print the same lines and exit status as
# the bash (the stderr text is not compared).
#
#   bash tests/nfcxx-gcc/run.sh [CASES]     CASES defaults to tests/nfcxx-gcc/cases.txt
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
cases=${1:-$here/cases.txt}
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
root=$sb/root; work=$sb/work; bin=$sb/bin; tmp=$sb/tmp
mkdir -p "$root/build/edg/bin" "$root/build/edg/lib" "$bin" "$work" "$tmp" "$root/build/asan"
cp -r "$repo/scripts" "$root/scripts"
# the copy of nfcxx, unchanged: the commands after the eccp call (the cache store, the second CUDA pass, the depmode step)
# run as they do; with the cache off and no CUDA input they print nothing, except the depmode step, which is ported
cp "$repo/nfcxx" "$root/nfcxx"
chmod +x "$root/nfcxx"
for s in ehshim sret.sh asan-vla; do ln -sf "$here/stub.sh" "$root/scripts/$s"; done
for c in gcc cc g++ cp mktemp ninja; do ln -s "$here/stub.sh" "$bin/$c"; done
# the repository's tools are built (ensure_tool finds them fresh: no ninja run); the sandbox has no tool sources
: > "$root/build/cuda-rewrite"; chmod +x "$root/build/cuda-rewrite"
ln -s "$here/stub.sh" "$root/build/edg/bin/eccp"
# the work directory: the sources and objects the cases name, a module source, and the directories
mkdir -p "$work/inc" "$work/sub" "$work/libs"
for f in a.cc b.cc c.c d.c x.o y.o libq.a pre.h; do : > "$work/$f"; done
printf 'export module m;\n' > "$work/mod.cc"
cp "$here/facts.txt" "$sb/facts"
(cd "$work" && find . -mindepth 1 -printf '%P\n' | sort) | sed 's/^/exists /' >> "$sb/facts"
# the ld.NAME stubs (-fuse-ld=NAME): the facts' ld lines
awk '$1 == "ld" { print $2 }' "$sb/facts" | while read -r x; do ln -s "$here/stub.sh" "$bin/ld.$x"; done

pass=0; fail=0; unp=0; unported_list=""; failed_list=""
while IFS= read -r line; do
  case $line in ""|"#"*) continue ;; esac
  read -r -a args <<< "$line"
  port_out=$(ruby "$repo/scripts/nfcxx-gcc-plan.rb" --facts="$sb/facts" "${args[@]}" 2>"$sb/perr"); rc=$?
  if [ $rc = 3 ]; then
    unp=$((unp + 1)); unported_list+="  $line
      $(head -1 "$sb/perr")
"
    continue
  fi
  : > "$sb/stublog"
  (cd "$work" && env -i PATH="$bin:/usr/bin:/bin" NFCXX_FACTS="$sb/facts" NFCXX_STUB_LOG="$sb/stublog" \
     NFCXX_STUB_TMP="$tmp" NFCXX_STUB_ROOT="$root" bash "$root/nfcxx" "${args[@]}" >/dev/null 2>"$sb/oerr"); orc=$?
  oracle_out=$(sed -e "s#$tmp/[^/]*#TMP#g" -e "s#$work#WORK#g" -e "s#$root#ROOT#g" "$sb/stublog"; echo "STATUS $orc")
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

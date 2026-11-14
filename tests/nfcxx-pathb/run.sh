#!/bin/bash
# Compares scripts/nfcxx-pathb.rb (the port) with nfcxx's bash on the Path B compile and link of hosted C++ sources, for each
# case of cases.txt.
#
# The oracle is the bash: a copy of nfcxx in a sandbox, run to its end. The sandbox has the repository's scripts, except
# pathb-cc, pathb-ldrt, ehshim, sret.sh, asan-vla and safeptr-rt, which are stubs (stub.sh). The commands of the Path B path are stubs too
# (stub.sh, linked under the command names in the sandbox's bin directory and at build/edg/bin/eccp):
#   cc                  the link: logged (RUN), not run
#   pathb-cc            logged (RUN ROOT/scripts/pathb-cc ARGS); its status is the facts' pathb-status
#   env                 the gcc fallback's exec: logged (EXEC); the bash is replaced, so no STATUS line follows it
#   mktemp -d           a directory under the sandbox's tmp, printed as TMP
#   g++, gcc            probes answer; no others run here
# Everything else (rm, sed, awk, grep, ...) runs for real. The bash runs under env -i (no NFCXX_* variables) in the sandbox's
# work directory, whose files and directories are the "exists" facts. In the output the sandbox's repository is ROOT, its work
# directory WORK, its temporary directories TMP.
#
# The port gets the same facts (facts.txt plus the exists lines) and the same arguments. A case the port refuses (exit 3) is
# listed as unported with its reason and not compared; every other case must print the same lines and status as the bash (the
# stderr text is not compared). For --backend=pathb the bash gets --backend=pathb in front of the arguments.
#
#   bash tests/nfcxx-pathb/run.sh [CASES]     CASES defaults to tests/nfcxx-pathb/cases.txt
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
cases=${1:-$here/cases.txt}
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
root=$sb/root; work=$sb/work; bin=$sb/bin; tmp=$sb/tmp
mkdir -p "$root/build/edg/bin" "$root/build/edg/lib" "$root/build/qbe" "$bin" "$work" "$tmp"
cp -r "$repo/scripts" "$root/scripts"
# the copy of nfcxx, unchanged
cp "$repo/nfcxx" "$root/nfcxx"
chmod +x "$root/nfcxx"
for s in ehshim sret.sh asan-vla safeptr-rt pathb-cc pathb-ldrt; do ln -sf "$here/stub.sh" "$root/scripts/$s"; done
for c in cc g++ gcc cp mktemp ninja env; do ln -s "$here/stub.sh" "$bin/$c"; done
# the tools the driver checks for: built (ensure_tool finds them fresh), QBE and EDG's driver are present, libC.a exists
: > "$root/build/cuda-rewrite"; chmod +x "$root/build/cuda-rewrite"
: > "$root/build/qbe/qbe"; chmod +x "$root/build/qbe/qbe"
: > "$root/build/edg/lib/libC.a"
ln -s "$here/stub.sh" "$root/build/edg/bin/eccp"
# the work directory: the sources and objects the cases name, a module source, and the directories
mkdir -p "$work/inc" "$work/sub" "$work/inc2/sycl/detail"
for f in a.cc b.cc fail.cc bad.cc x.o y.o libq.a pre.h sub/x.cc .hidden.cc noext c.c; do : > "$work/$f"; done
printf 'export module m;\n' > "$work/mod.cc"
: > "$work/inc2/sycl/detail/kernel_desc.hpp"
cp "$here/facts.txt" "$sb/facts"
(cd "$work" && find . -mindepth 1 -printf '%P\n' | sort) | sed 's/^/exists /' >> "$sb/facts"
# the ld.NAME stubs (-fuse-ld=NAME): the facts' ld lines
awk '$1 == "ld" { print $2 }' "$sb/facts" | while read -r x; do ln -sf "$here/stub.sh" "$bin/ld.$x"; done

pass=0; fail=0; unp=0; unported_list=""; failed_list=""
while IFS= read -r line; do
  case $line in ""|"#"*) continue ;; esac
  read -r -a words <<< "$line"
  choice=${words[0]}; args=("${words[@]:1}")
  port_out=$(ruby "$repo/scripts/nfcxx-pathb.rb" --facts="$sb/facts" --backend="$choice" -- "${args[@]}" 2>"$sb/perr"); rc=$?
  if [ $rc = 3 ]; then
    unp=$((unp + 1)); unported_list+="  $line
      $(head -1 "$sb/perr")
"
    continue
  fi
  bargs=("${args[@]}")
  [ "$choice" != pathb ] || bargs=(--backend=pathb "${args[@]}")
  : > "$sb/stublog"
  (cd "$work" && env -i PATH="$bin:/usr/bin:/bin" NFCXX_FACTS="$sb/facts" NFCXX_STUB_LOG="$sb/stublog" \
     NFCXX_STUB_TMP="$tmp" NFCXX_STUB_ROOT="$root" bash "$root/nfcxx" "${bargs[@]}" >/dev/null 2>"$sb/oerr"); orc=$?
  # an exec (the gcc fallback) replaces the bash: the status is the re-run's, so only the EXEC line is compared
  if tail -1 "$sb/stublog" | grep -q '^EXEC '; then
    oracle_out=$(sed -e "s#$tmp/[^/]*#TMP#g" -e "s#$work#WORK#g" -e "s#$root#ROOT#g" "$sb/stublog")
  else
    oracle_out=$({ sed -e "s#$tmp/[^/]*#TMP#g" -e "s#$work#WORK#g" -e "s#$root#ROOT#g" "$sb/stublog"; echo "STATUS $orc"; })
  fi
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

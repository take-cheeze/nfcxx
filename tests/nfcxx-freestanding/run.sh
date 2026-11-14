#!/bin/bash
# Compares scripts/nfcxx-freestanding.rb (the port) with nfcxx's bash on the --emit-c, --emit-hip, --freestanding,
# --target, -E and compile/link argument lists of cases.txt.
#
# The oracle is the bash: a copy of nfcxx in a sandbox, run to its end, with the sandbox's repository scripts (the
# copy of scripts/, unchanged except pathb-cc and pathb-ldrt, which are stubs). Commands the paths run are stubs (stub.sh,
# linked under the command names in the sandbox's bin directory and at the build paths): the probes of g++ answer from
# facts.txt, the EDG front end (cpfe), the Path B compile (pathb-cc), the link (cc) and the rewriter (cuda-rewrite) are
# logged, not run, and uname answers from facts.txt. Everything else (mkdir, find, awk, sed, realpath, ...) runs for real.
# The bash runs under env -i (no NFCXX_* variables) in the sandbox's work directory, whose directories are the "exists"
# facts. In the output the sandbox's repository is ROOT, its work directory WORK, its temporary directories TMP.
#
# The port gets the same facts and the same arguments. A case the port refuses (exit 3) is listed as unported with its
# reason and not compared; every other case must print the same lines and exit status as the bash (its stderr is not
# compared). After an EXEC line the bash's status is the program's, so no status is compared for it.
#
# A case may start with host tokens: clang (the host C++ compiler is clang), darwin (uname Darwin), machine=NAME (uname
# -m; the default is x86_64 on Linux with g++), noqbe (no build/qbe/qbe: the facts say so and the file is removed).
# Each combination gets its own facts file (facts.txt with those values).
#
#   bash tests/nfcxx-freestanding/run.sh [CASES]     CASES defaults to tests/nfcxx-freestanding/cases.txt
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
cases=${1:-$here/cases.txt}
[ "$(uname -s)" = Linux ] || { echo "run.sh: the sandbox's tools are Linux tools (GNU find, realpath)" >&2; exit 2; }
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
root=$sb/root; work=$sb/work; bin=$sb/bin; tmp=$sb/tmp
mkdir -p "$root/build/edg/bin" "$root/build/edg/lib" "$root/build/edg-base" "$bin" "$work" "$tmp" "$root/tools/cuda-rewrite" "$root/build/qbe"
cp -r "$repo/scripts" "$root/scripts"
cp "$repo/nfcxx" "$root/nfcxx"
chmod +x "$root/nfcxx"
for c in g++ gcc cc cp mktemp ninja uname; do ln -s "$here/stub.sh" "$bin/$c"; done
ln -s "$here/stub.sh" "$root/build/edg/bin/cpfe"
ln -s "$here/stub.sh" "$root/build/edg/bin/eccp"
ln -s "$here/stub.sh" "$root/build/cuda-rewrite"
# the Path B compile and the long double archive are stubs too (the real ones build C or need a QBE build)
ln -sf "$here/stub.sh" "$root/scripts/pathb-cc"
ln -sf "$here/stub.sh" "$root/scripts/pathb-ldrt"
# the EDG base's target tables (--target=NAME checks lib_NAME) and the eh-tls marker (--nfcxx_eh_thread_local)
awk '$1 == "target-table" { print $2 }' "$here/facts.txt" | while read -r t; do mkdir -p "$root/build/edg-base/lib_$t"; done
awk '$1 == "eh-tls" && $2 == 1 { found = 1 } END { exit !found }' "$here/facts.txt" && : > "$root/build/edg/eh-tls"
# the work directory: the sources and objects the cases name, a module source, and the directories
mkdir -p "$work/inc" "$work/sub" "$work/libs"
for f in a.cc b.cc c.c d.c x.o y.o libq.a pre.h x.cu y.cu; do : > "$work/$f"; done
printf 'export module m;\n' > "$work/mod.cc"

# facts_for TOKEN...: the facts file for a case's host tokens (written on first use); prints its path
facts_for() {
  local clang=0 uname=Linux machine=x86_64 qbe=1 t f
  for t in "$@"; do
    case $t in
      clang) clang=1 ;;
      darwin) uname=Darwin ;;
      machine=*) machine=${t#machine=} ;;
      noqbe) qbe=0 ;;
    esac
  done
  f=$sb/facts-$clang-$uname-$machine-$qbe
  if [ ! -f "$f" ]; then
    sed -e "s/^cxx-clang 0\$/cxx-clang $clang/" -e "s/^uname Linux\$/uname $uname/" -e "s/^machine x86_64\$/machine $machine/" \
        -e "/^qbe 1\$/d" "$here/facts.txt" > "$f"
    [ "$qbe" = 1 ] && echo "qbe 1" >> "$f"
    (cd "$work" && find . -mindepth 1 -type d -printf '%P\n' | sort) | sed 's/^/exists /' >> "$f"
  fi
  printf '%s\n' "$f"
}

pass=0; fail=0; unp=0; unported_list=""; failed_list=""
while IFS= read -r line; do
  case $line in ""|"#"*) continue ;; esac
  read -r -a args <<< "$line"
  htoks=()
  while [ ${#args[@]} -gt 0 ]; do
    case ${args[0]} in
      clang|darwin|noqbe|machine=*) htoks+=("${args[0]}"); args=("${args[@]:1}") ;;
      *) break ;;
    esac
  done
  facts=$(facts_for ${htoks[@]+"${htoks[@]}"})
  # build/qbe/qbe exists exactly when the facts say so (Path B checks it with -x)
  if grep -qx 'qbe 1' "$facts"; then : > "$root/build/qbe/qbe"; chmod +x "$root/build/qbe/qbe"; else rm -f "$root/build/qbe/qbe"; fi
  port_out=$(ruby "$repo/scripts/nfcxx-freestanding.rb" --facts="$facts" "${args[@]}" 2>"$sb/perr"); rc=$?
  if [ $rc = 3 ]; then
    unp=$((unp + 1)); unported_list+="  $line
      $(head -1 "$sb/perr")
"
    continue
  fi
  : > "$sb/stublog"
  (cd "$work" && env -i PATH="$bin:/usr/bin:/bin" NFCXX_FACTS="$facts" NFCXX_STUB_LOG="$sb/stublog" \
     NFCXX_STUB_TMP="$tmp" bash "$root/nfcxx" "${args[@]}" >/dev/null 2>"$sb/oerr"); orc=$?
  oracle_out=$(sed -e "s#$tmp/[^/]*#TMP#g" -e "s#$work#WORK#g" -e "s#$root#ROOT#g" "$sb/stublog")
  if ! grep -q '^EXEC ' "$sb/stublog"; then   # after EXEC the status is the program's: none is compared
    if [ -n "$oracle_out" ]; then oracle_out="$oracle_out
STATUS $orc"; else oracle_out="STATUS $orc"; fi
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

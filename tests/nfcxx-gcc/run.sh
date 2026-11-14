#!/bin/bash
# Compares scripts/nfcxx-gcc-plan.rb (the port) with nfcxx's bash on the gcc backend, for each argument list of the case sets.
#
# The oracle is the bash: a copy of nfcxx in a sandbox, run to its end. The sandbox has the repository's scripts, except
# ehshim, sret.sh, asan-vla, cuda-cub and cuda-driver-shim, which are stubs. Commands on the gcc path are stubs (stub.sh,
# linked under the command names in the sandbox's bin directory and at build/edg/bin/eccp):
#   gcc, cc, g++  probes answer from facts.txt; the compiles and links, and nfcxx's exec of g++ -E, are logged, not run
#   cp            logged (CP), not copied
#   mktemp -d     a directory under the sandbox's tmp, printed as TMP
#   eccp          logged (RUN), with ENV for EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS
#   ehshim, sret.sh, asan-vla, cuda-cub, cuda-driver-shim: the facts' values; uname -m: the fact machine
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
  for s in ehshim sret.sh asan-vla cuda-cub cuda-driver-shim; do ln -sf "$here/stub.sh" "$root/scripts/$s"; done
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
       NFCXX_STUB_TMP="$tmp" NFCXX_STUB_ROOT="$root" ${cuda_home:+CUDA_HOME=$cuda_home} \
       bash "$root/nfcxx" "${args[@]}" >/dev/null 2>"$sb/oerr"); orc=$?
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
  rm -rf "$sb"
}

if [ -n "${1:-}" ]; then
  run_set "$1" ""
else
  run_set "$here/cases.txt" ""
  run_set "$here/cases-cuda-home.txt" "cuda-home cuda"
  run_set "$here/cases-shim-error.txt" "cuda-shim-error scripts/cuda-driver-shim: the shim does not build here"
fi

[ -z "$failed_list" ] || printf '%s' "$failed_list"
echo "passed $pass, failed $fail, unported $unp"
[ -z "$unported_list" ] || { echo "unported (reason from the port):"; printf '%s' "$unported_list"; }
[ "$fail" = 0 ]

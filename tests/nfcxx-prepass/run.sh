#!/bin/bash
# Compares scripts/nfcxx-prepass.rb (the port) with the two pre-passes of nfcxx's bash driver: the cppfront translation of
# .cpp2 inputs, and the SYCL two-pass build of a -c compile that includes <sycl/...>.
#
# Each line of CASES is "FACTS ARG...": FACTS names facts/FACTS.txt, the facts the sandbox and the port share.
#
# The oracle is the bash: a sandbox with a copy of the repository's scripts and the driver, run under env -i. The copy of
# the driver is cut after its cpp2_prepare call (the main compile is not compared), and its nested self-runs (the two
# SYCL passes) call a stub, nfcxx-nested, instead of the driver. The other external commands are stubs (stub.sh):
# cppfront, the integration-header script, the nested runs, mktemp, mkdir, cat and the host probes. Everything else runs
# for real (realpath, sha1sum, grep, sed, awk, cut). The sandbox's paths are normalized: temporary directories to <tmp>,
# the cache to <cache>, the repository to <root>, the work directory to <work>.
#
# The port gets the same facts and arguments, from the work directory. A case the port refuses (exit 3) is listed as
# unported with its reason and not compared. Every other case must print the same lines and exit status (STATUS N),
# and the same "nfcxx:" message lines on stderr.
#
#   bash tests/nfcxx-prepass/run.sh [CASES]     CASES defaults to tests/nfcxx-prepass/cases.txt
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
cases=${1:-$here/cases.txt}
pass=0; fail=0; unp=0; unported_list=""; failed_list=""

while IFS= read -r line; do
  case $line in ""|"#"*) continue ;; esac
  read -r -a fields <<< "$line"
  fname=${fields[0]}; args=("${fields[@]:1}")

  sb=$(realpath -m "$(mktemp -d)")
  root=$sb/root; work=$sb/work; bin=$sb/bin; tmp=$sb/tmp; cache=$sb/cache
  mkdir -p "$root/build" "$work" "$bin" "$tmp" "$sb/home" "$sb/xdg"
  cp -r "$repo/scripts" "$root/scripts"
  ln -sf "$here/stub.sh" "$root/scripts/sycl-integration-header.sh"
  # the driver, cut after its cpp2_prepare call; its nested self-runs go to the stub
  awk '{ print } /^cpp2_prepare$/ { print "exit 0"; exit }' "$repo/nfcxx" \
    | sed 's|"\$root/nfcxx"|"$root/nfcxx-nested"|g' > "$root/nfcxx"
  chmod +x "$root/nfcxx"
  ln -s "$here/stub.sh" "$root/nfcxx-nested"
  : > "$root/build/cuda-rewrite"; chmod +x "$root/build/cuda-rewrite"
  for c in gcc cc g++ mktemp mkdir cat; do ln -s "$here/stub.sh" "$bin/$c"; done

  [ -f "$here/facts/$fname.txt" ] || { echo "no facts file facts/$fname.txt" >&2; exit 2; }
  sed -e "s#\bROOT\b#$root#g" -e "s#\bCACHE\b#$cache#g" -e "s#\bSB\b#$sb#g" "$here/facts/$fname.txt" > "$sb/facts"
  # the files the facts name exist in the sandbox (relative names: in the work directory)
  while read -r kind p; do
    case $kind in
      file) f=$p; case $p in /*) ;; *) f=$work/$p ;; esac; mkdir -p "$(dirname "$f")"; : > "$f" ;;
      exec) mkdir -p "$(dirname "$p")"; ln -s "$here/stub.sh" "$p" ;;
    esac
  done < "$sb/facts"
  # the sources the cases name
  printf 'main: () -> int = { return 0; }\n' > "$work/hello.cpp2"
  printf 'main: () -> int = { return 0; }\n' > "$work/a.cpp2"
  printf 'main: () -> int = { return 0; }\n' > "$work/b.cpp2"
  mkdir -p "$work/sub"; printf 'main: () -> int = { return 0; }\n' > "$work/sub/x.cpp2"
  printf '#include <sycl/sycl.hpp>\nint k;\n' > "$work/sy.cc"
  printf '#include <sycl/sycl.hpp>\nmain: () -> int = { return 0; }\n' > "$work/sy.cpp2"
  printf 'int main() { return 0; }\n' > "$work/plain.cc"
  envs=(); while read -r kind k v; do [ "$kind" = env ] && envs+=("$k=$v"); done < "$sb/facts"

  # the port
  (cd "$work" && ruby "$repo/scripts/nfcxx-prepass.rb" --facts="$sb/facts" --root="$root" "${args[@]}" \
     >"$sb/pout" 2>"$sb/perr"); prc=$?
  if [ "$prc" = 3 ]; then
    unp=$((unp + 1)); unported_list+="  $line
      $(head -1 "$sb/perr")
"
    rm -rf "$sb"; continue
  fi

  # the bash
  : > "$sb/log"
  (cd "$work" && env -i PATH="$bin:/usr/bin:/bin" "${envs[@]}" NFCXX_FACTS="$sb/facts" NFCXX_STUB_LOG="$sb/log" \
     NFCXX_STUB_TMP="$tmp" NFCXX_STUB_ROOT="$root" bash "$root/nfcxx" "${args[@]}" >"$sb/bout" 2>"$sb/berr"); orc=$?

  norm() { sed -e "s#$tmp/d[0-9.]*#<tmp>#g" -e "s#$cache#<cache>#g" -e "s#$root#<root>#g" -e "s#$work#<work>#g" -e "s#$sb#<sb>#g"; }
  port_txt=$(norm < "$sb/pout")
  oracle_txt=$({ norm < "$sb/log"; echo "STATUS $orc"; })
  [ -s "$sb/bout" ] && oracle_txt+=$'\nSTDOUT-NOT-EMPTY'
  port_err=$(grep '^nfcxx: ' "$sb/perr" | norm)
  oracle_err=$(grep '^nfcxx: ' "$sb/berr" | norm)
  if [ "$port_txt" = "$oracle_txt" ] && [ "$port_err" = "$oracle_err" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed_list+="== $line
--- port
$port_txt
$port_err
--- bash
$oracle_txt
$oracle_err
"
  fi
  rm -rf "$sb"
done < "$cases"

[ -z "$failed_list" ] || printf '%s' "$failed_list"
echo "passed $pass, failed $fail, unported $unp"
[ -z "$unported_list" ] || { echo "unported (reason from the port):"; printf '%s' "$unported_list"; }
[ "$fail" = 0 ]

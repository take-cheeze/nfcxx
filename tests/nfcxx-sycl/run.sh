#!/bin/bash
# Differential test of the SYCL pre-pass: scripts/nfcxx-sycl.rb (the decision and the two passes, which nfcxx's bash calls)
# against the bash block of nfcxx on main (tests/nfcxx-sycl/oracle.sh, verbatim). Each case runs two copies of the driver in
# sandboxes with the stub commands of tests/nfcxx-prepass/stub.sh: both cut right after the lines before the SYCL block, and
# the new one runs the block as it is in nfcxx, the oracle copy runs oracle.sh in its place. The commands the nested runs and
# the header script get (the stub's log: EXEC, RUN, WRITE and the wrapper's lines) must be the same, and so the status, the
# stdout and the stderr. The stub's CAT lines (the bash's cat of the pass-1 log) are left out of the comparison: the port reads
# that log itself. The temporary directory is normalized to <tmp>.
#
#   bash tests/nfcxx-sycl/run.sh [CASES]     CASES defaults to tests/nfcxx-sycl/cases.txt
#   NFCXX_SYCL_VERBOSE=1 prints each case's outcome (the port's)
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
stub="$repo/tests/nfcxx-prepass/stub.sh"
cases=${1:-$here/cases.txt}
ruby_bin=$(command -v ruby)
pass=0; fail=0; failed_list=""

# the driver copies: the lines of nfcxx before the SYCL block (the same in both), then the block (the port's two calls, or
# oracle.sh), then the lines after it up to the -c move, which the copies end on
cut_new() { awk '/^# SYCL kernel integration/ { exit } { print }' "$repo/nfcxx"
  awk '/^# SYCL kernel integration/ { go = 1 } go { print } /^\[ \$compile_only = 1 \] \|\| moves=1/ { exit }' "$repo/nfcxx" | sed '$d'
  echo 'exit 77'; }
cut_oracle() { awk '/^# SYCL kernel integration/ { exit } { print }' "$repo/nfcxx"
  cat "$here/oracle.sh"; echo 'exit 77'; }

while IFS= read -r line; do
  case $line in ""|"#"*) continue ;; esac
  read -r -a fields <<< "$line"
  fname=${fields[0]}; args=("${fields[@]:1}")
  facts_file=$here/facts/$fname.txt; [ -f "$facts_file" ] || facts_file=$repo/tests/nfcxx-prepass/facts/$fname.txt
  [ -f "$facts_file" ] || { echo "no facts file for $fname" >&2; exit 2; }

  outcome() {  # outcome WHICH: the run of one copy in a fresh sandbox; prints the normalized outcome
    local which=$1 sb root work bin tmp cache
    sb=$(realpath -m "$(mktemp -d)")
    root=$sb/root; work=$sb/work; bin=$sb/bin; tmp=$sb/tmp; cache=$sb/cache
    mkdir -p "$root/build" "$work" "$bin" "$tmp" "$sb/home" "$sb/xdg"
    cp -r "$repo/scripts" "$root/scripts"
    ln -sf "$stub" "$root/scripts/sycl-integration-header.rb"
    # the nested runs of the driver (root/nfcxx, the name the block calls) go to the stub; the copy under test is root/driver
    printf '#!/bin/bash\nexec "$(dirname "$0")/nfcxx-nested" "$@"\n' > "$root/nfcxx"; chmod +x "$root/nfcxx"
    ln -s "$stub" "$root/nfcxx-nested"
    if [ "$which" = new ]; then cut_new > "$root/driver"; else cut_oracle > "$root/driver"; fi
    chmod +x "$root/driver"
    : > "$root/build/cuda-rewrite"; chmod +x "$root/build/cuda-rewrite"
    for c in gcc cc g++ mktemp mkdir cat; do ln -s "$stub" "$bin/$c"; done
    sed -e "s#\bROOT\b#$root#g" -e "s#\bCACHE\b#$cache#g" -e "s#\bSB\b#$sb#g" "$facts_file" > "$sb/facts"
    while read -r kind p; do
      case $kind in
        file) f=$p; case $p in /*) ;; *) f=$work/$p ;; esac; mkdir -p "$(dirname "$f")"; : > "$f" ;;
        exec) mkdir -p "$(dirname "$p")"; ln -sf "$stub" "$p" ;;
      esac
    done < "$sb/facts"
    printf 'int k;\n' > "$work/plain.cc"
    printf '#include <sycl/sycl.hpp>\nint k;\n' > "$work/sy.cc"
    printf '#include <sycl/sycl.hpp>\nint k;\n' > "$work/sy.cxx"
    printf '#include <sycl/sycl.hpp>\nint k;\n' > "$work/sy.cu"
    printf '#include <sycl/sycl.hpp>\nmain: () -> int = { return 0; }\n' > "$work/sy.cpp2"
    printf '#include <sycl/sycl.hpp>\nint k;\n' > "$work/sy.c"
    printf 'int main() { return 0; }\n' > "$work/plain.c"
    printf 'main: () -> int = { return 0; }\n' > "$work/hello.cpp2"
    local envs=() k v
    while read -r kind k v; do [ "$kind" = env ] && envs+=("$k=$v"); done < "$sb/facts"
    local log=$sb/log; : > "$log"
    (cd "$work" && env -i RUBY="$ruby_bin" PATH="$bin:/usr/bin:/bin" TMPDIR="$tmp" "${envs[@]}" NFCXX_FACTS="$sb/facts" \
       NFCXX_STUB_LOG="$log" NFCXX_STUB_TMP="$tmp" NFCXX_STUB_ROOT="$root" bash "$root/driver" "${args[@]}" \
       >"$sb/out" 2>"$sb/err"); local rc=$?
    local norm=(-e "s#$tmp/[^ \"/]*#<tmp>#g" -e "s#$cache#<cache>#g" -e "s#$root#<root>#g" -e "s#$work#<work>#g" -e "s#$sb#<sb>#g")
    echo "STATUS $rc"
    echo "STDOUT $(sed "${norm[@]}" < "$sb/out" | tr '\n' '|')"
    echo "STDERR $(sed "${norm[@]}" < "$sb/err" | tr '\n' '|')"
    sed "${norm[@]}" < "$log"
    rm -rf "$sb"
  }

  oracle_txt=$(outcome oracle); port_txt=$(outcome new)
  [ -z "${NFCXX_SYCL_VERBOSE:-}" ] || { echo "== $line"; echo "$port_txt"; }
  if [ "$oracle_txt" = "$port_txt" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed_list+="== $line
--- bash (main)
$oracle_txt
--- port
$port_txt
"
  fi
done < "$cases"

[ -z "$failed_list" ] || printf '%s' "$failed_list"
echo "nfcxx-sycl: $pass passed, $fail failed"
[ "$fail" = 0 ]

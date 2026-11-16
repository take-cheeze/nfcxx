#!/bin/bash
# Compares nfcxx's C++ module build with the bash it replaces, for each argument list of cases.txt and build-cases.txt.
#
# Two sandboxes, each a copy of the repository's scripts with the stubs (stub.sh) for the external commands. The oracle's nfcxx
# is the repository's nfcxx with mod_build_program replaced by the original bash function (bash-build.sh). The port is the
# repository's nfcxx as it is: mod_build_program calls scripts/nfcxx-modules.rb build. Both run to their end in env -i (nested
# calls of nfcxx run in the same sandbox), against stubs that log every eccp, pathb-cc and cc call and every cp.
#
# For every argument list (cases.txt and build-cases.txt):
#   - the build: the full stub log (every logged call, in order, with its words), the status, stdout and stderr of the port
#     must equal the oracle's (paths normalized: the temporary directory is TMP, the work directory WORK, the sandbox root ROOT).
#   - the plan (cases.txt only): scripts/nfcxx-modules.rb's plan (the module words of each call, the status) must equal the
#     oracle's calls, projected to the module words. A case the plan does not cover (exit 3) is listed as unported.
# The sources: tests/modules/*, and src/ here. The facts (facts.txt and the SRC lines written from nfcxx's module functions).
#
#   bash tests/nfcxx-modules/run.sh [CASES] [BUILD_CASES]
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
cases=${1:-$here/cases.txt}
build_cases=${2:-$here/build-cases.txt}
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
oracle=$sb/oracle; port=$sb/port; work=$sb/work; bin=$sb/bin; tmp=$sb/tmp
mkdir -p "$work" "$tmp" "$bin"
# mkroot ROOT NFCXX: a repository root for nfcxx (its scripts, the stubs, the build tree) with NFCXX as its nfcxx
mkroot() {
  local r=$1 src=$2
  mkdir -p "$r/build/edg/bin" "$r/build/edg/lib" "$r/build/asan"
  cp -r "$repo/scripts" "$r/scripts"
  cp "$src" "$r/nfcxx"; chmod +x "$r/nfcxx"
  for s in ehshim.rb asan-vla.rb; do ln -sf "$here/stub.sh" "$r/scripts/$s"; done
  : > "$r/build/cuda-rewrite"; chmod +x "$r/build/cuda-rewrite"
  ln -s "$here/stub.sh" "$r/build/edg/bin/eccp"
  ln -sf "$here/stub.sh" "$r/scripts/pathb-cc.rb"
  ln -sf "$here/stub.sh" "$r/scripts/pathb-ldrt.rb"
  mkdir -p "$r/build/qbe"; ln -s "$here/stub.sh" "$r/build/qbe/qbe"
}
# the oracle's nfcxx: the original mod_build_program in place of the thin call (from the first line of the function to its closing brace)
awk -v f="$here/bash-build.sh" '
  /^mod_build_program\(\) \{/ { while ((getline l < f) > 0) print l; skip = 1; next }
  skip && /^\}/ { skip = 0; next }
  !skip { print }' "$repo/nfcxx" > "$sb/nfcxx-oracle"
# the module wrappers are no longer in nfcxx (its call sites are direct); the oracle gets their verbatim copy first
{ cat "$repo/tests/nfcxx-modscan/oracle-wrappers.sh"; cat "$sb/nfcxx-oracle"; } > "$sb/nfcxx-oracle.tmp" && mv "$sb/nfcxx-oracle.tmp" "$sb/nfcxx-oracle"
mkroot "$oracle" "$sb/nfcxx-oracle"
mkroot "$port" "$repo/nfcxx"
root=$oracle   # the module functions of nfcxx (mod_decl_name and the rest) run the scripts of this root
for c in gcc cc g++ cp mktemp ninja; do ln -s "$here/stub.sh" "$bin/$c"; done
# the sources: the repository's module tests and the port's own (src/)
cp "$repo"/tests/modules/*.cpp "$repo"/tests/modules/*.cppm "$here"/src/* "$work"/
cp "$here/facts.txt" "$sb/facts"
# the SRC facts: nfcxx's module functions, run on each source in the work directory
fns=$(cat "$repo/tests/nfcxx-modscan/oracle-wrappers.sh")
src_fact() {  # src_fact FILE: the SRC line the port reads for a source argument
  local f=$1 m=0 decl imps msg rc
  ( eval "$fns"; mod_is_module_src "$f" ) && m=1
  decl=$( eval "$fns"; mod_decl_name "$f" ); [ -n "$decl" ] || decl=-
  imps=$( eval "$fns"; mod_imports "$f" | paste -sd, - ); [ -n "$imps" ] || imps=-
  msg=$( eval "$fns"; mod_check_src "$f" 2>&1 ); rc=$?
  [ -n "$msg" ] || msg=-
  printf 'SRC\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$m" "$decl" "$imps" "$rc" "$msg"
}
(cd "$work" && for f in *.cc *.cpp *.cppm *.ixx; do src_fact "$f"; done) >> "$sb/facts"
(cd "$work" && find . -mindepth 1 -printf '%P\n' | sort) | sed 's/^/exists /' >> "$sb/facts"

# exec_case NAME ROOT ARGS...: nfcxx of ROOT on ARGS in the work directory; $sb/NAME.log (the stub log), .out, .err and .rc
exec_case() {
  local name=$1 r=$2; shift 2
  : > "$sb/$name.log"
  (cd "$work" && env -i PATH="$bin:/usr/bin:/bin" RUBY="$(command -v ruby)" TMPDIR="$tmp" NFCXX_FACTS="$sb/facts" \
     NFCXX_STUB_LOG="$sb/$name.log" NFCXX_STUB_TMP="$tmp" NFCXX_STUB_ROOT="$r" bash "$r/nfcxx" "$@" \
     >"$sb/$name.out" 2>"$sb/$name.err"); echo $? > "$sb/$name.rc"
}
# norm ROOT FILE: FILE with the sandbox paths as placeholders (the temporary directory, the work directory, the root)
norm() { sed -e "s#$tmp/[^/[:space:]]*#TMP#g" -e "s#$work#WORK#g" -e "s#$1#ROOT#g" "$2"; }

# the projection: the eccp, pathb-cc and cc calls of the stub log (normalized on stdin) as "ECCP|PATHB|CC WORDS": the module words
# (the --modules options, the source, the interface and object paths, the -o output and the objects of a link)
project() {
  ruby -e '
    def norm(x) = x =~ %r{\A(/|WORK(/|\z)|TMP(/|\z))} ? x : "WORK/#{x}"
    STDIN.each_line do |l|
      t = l.split
      next unless t[0] == "RUN"
      tool = if t[1] =~ %r{/eccp\z} then "ECCP"
             elsif t[1] =~ %r{/pathb-cc(\.rb)?\z} then "PATHB"
             elsif t[1] == "cc" then "CC"
             end
      next unless tool
      words = []
      i = 2
      while i < t.size
        w = t[i]
        if w == "--modules" then words << w
        elsif %w[--modules_directory --create_module_interface -o].include?(w)
          words << w
          i += 1
          words << norm(t[i]) if t[i]
        elsif w =~ /\.(cc|cpp|cxx|cppm|ixx)\z/ then words << norm(w)
        elsif w =~ %r{\ATMP/[mp]\d+\.o\z} then words << w
        end
        i += 1
      end
      puts tool + " " + words.join(" ") unless words.empty?
    end'
}

pass=0; fail=0; unp=0; unported_list=""; failed_list=""
# run_list FILE PLAN: each argument list of FILE; PLAN=1 also compares the plan
run_list() {
  local file=$1 plan=$2 line n=0 args port_out prc ok
  while IFS= read -r line; do
    case $line in ""|"#"*) continue ;; esac
    n=$((n + 1)); read -r -a args <<< "$line"
    exec_case o "$oracle" "${args[@]}"
    exec_case p "$port" "${args[@]}"
    ok=1; why=""
    norm "$oracle" "$sb/o.log" > "$sb/o.n"; norm "$port" "$sb/p.log" > "$sb/p.n"
    cmp -s "$sb/o.rc" "$sb/p.rc" || { ok=0; why+=" status($(cat "$sb/o.rc") vs $(cat "$sb/p.rc"))"; }
    cmp -s "$sb/o.n" "$sb/p.n" || { ok=0; why+=" stub-log"; }
    cmp -s "$sb/o.out" "$sb/p.out" || { ok=0; why+=" stdout"; }
    cmp -s <(norm "$oracle" "$sb/o.err") <(norm "$port" "$sb/p.err") || { ok=0; why+=" stderr"; }
    if [ "$plan" = 1 ]; then
      port_out=$(ruby "$repo/scripts/nfcxx-modules.rb" --facts="$sb/facts" --cwd=WORK "${args[@]}" 2>"$sb/perr"); prc=$?
      if [ $prc = 3 ]; then
        unp=$((unp + 1)); unported_list+="  $line
      $(head -1 "$sb/perr")
"
      else
        oracle_plan=$( { norm "$oracle" "$sb/o.log" | project; echo "STATUS $(cat "$sb/o.rc")"; } )
        [ "$port_out" = "$oracle_plan" ] || { ok=0; why+=" plan"; plan_detail="--- plan
$port_out
--- bash
$oracle_plan
"; }
      fi
    fi
    if [ $ok = 1 ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      failed_list+="== $line ($why)
$(cat "$sb/o.err" | head -3)
$( [ -n "${plan_detail:-}" ] && printf '%s' "$plan_detail")
"
    fi
    plan_detail=""
  done < "$file"
}

run_list "$cases" 1
run_list "$build_cases" 0
[ -z "$failed_list" ] || printf '%s' "$failed_list"
echo "passed $pass, failed $fail, unported $unp"
[ -z "$unported_list" ] || { echo "unported (reason from the port):"; printf '%s' "$unported_list"; }
[ $fail = 0 ]

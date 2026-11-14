#!/bin/bash
# Compares scripts/nfcxx-modules.rb (the plan printer) with nfcxx's bash for the C++ module build, for each argument list of cases.txt.
#
# The oracle is the bash: a copy of nfcxx in a sandbox, run to its end (with the module build's nested calls: mod_build_program
# runs nfcxx again, and those runs are the bash too). The sandbox has the repository's scripts, except ehshim, sret.sh and
# asan-vla, which are stubs. The external commands are stubs (stub.sh, linked under their names in the sandbox's bin directory
# and at build/edg/bin/eccp): gcc, cc, g++ probes answer from facts.txt, the compiles and links are logged; cp is logged; mktemp
# -d makes a directory under the sandbox's tmp; eccp is logged. Everything else runs for real. The bash runs under env -i.
#
# The comparison is of the module-owned lines: each eccp, pathb-cc and cc call of the bash is projected to its module words
# (the --modules options, the source, the interface and object paths, the -o output and the objects of a link), as ECCP,
# PATHB or CC lines in the same form the port prints them, then the exit status. The port's facts are the SRC lines, written here by running nfcxx's own module
# functions (mod_is_module_src, mod_decl_name, mod_imports, mod_check_src) on each source.
#
# A case the port does not cover (exit 3) is listed as unported with its reason and is not compared.
#
#   bash tests/nfcxx-modules/run.sh [CASES]     CASES defaults to tests/nfcxx-modules/cases.txt
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
cases=${1:-$here/cases.txt}
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
root=$sb/root; work=$sb/work; bin=$sb/bin; tmp=$sb/tmp
mkdir -p "$root/build/edg/bin" "$root/build/edg/lib" "$bin" "$work" "$tmp" "$root/build/asan"
cp -r "$repo/scripts" "$root/scripts"
cp "$repo/nfcxx" "$root/nfcxx"
chmod +x "$root/nfcxx"
for s in ehshim sret.sh asan-vla; do ln -sf "$here/stub.sh" "$root/scripts/$s"; done
for c in gcc cc g++ cp mktemp ninja; do ln -s "$here/stub.sh" "$bin/$c"; done
: > "$root/build/cuda-rewrite"; chmod +x "$root/build/cuda-rewrite"
ln -s "$here/stub.sh" "$root/build/edg/bin/eccp"
ln -sf "$here/stub.sh" "$root/scripts/pathb-cc"
ln -sf "$here/stub.sh" "$root/scripts/pathb-ldrt"
mkdir -p "$root/build/qbe"; ln -s "$here/stub.sh" "$root/build/qbe/qbe"
# the sources: the repository's module tests and the port's own (src/)
cp "$repo"/tests/modules/*.cpp "$repo"/tests/modules/*.cppm "$here"/src/* "$work"/
cp "$here/facts.txt" "$sb/facts"
# the SRC facts: nfcxx's module functions, run on each source in the work directory
fns=$(sed -n '/^mod_is_module_src()/,/^# mod_build_program/p' "$repo/nfcxx" | sed '$d')
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

# the projection: the eccp, pathb-cc and cc calls of the stub log (sed-normalized on stdin) as "ECCP|PATHB|CC WORDS". A word is kept when it is a
# module word; a path that is not absolute is under WORK (the bash's -c compile runs in the work directory with relative paths).
project() {
  ruby -e '
    def norm(x) = x =~ %r{\A(/|WORK(/|\z)|TMP(/|\z))} ? x : "WORK/#{x}"
    STDIN.each_line do |l|
      t = l.split
      next unless t[0] == "RUN"
      tool = if t[1] =~ %r{/eccp\z} then "ECCP"
             elsif t[1] =~ %r{/pathb-cc\z} then "PATHB"
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
while IFS= read -r line; do
  case $line in ""|"#"*) continue ;; esac
  read -r -a args <<< "$line"
  port_out=$(ruby "$repo/scripts/nfcxx-modules.rb" --facts="$sb/facts" --cwd=WORK "${args[@]}" 2>"$sb/perr"); rc=$?
  if [ $rc = 3 ]; then
    unp=$((unp + 1)); unported_list+="  $line
      $(head -1 "$sb/perr")
"
    continue
  fi
  : > "$sb/stublog"
  (cd "$work" && env -i PATH="$bin:/usr/bin:/bin" NFCXX_FACTS="$sb/facts" NFCXX_STUB_LOG="$sb/stublog" \
     NFCXX_STUB_TMP="$tmp" NFCXX_STUB_ROOT="$root" bash "$root/nfcxx" "${args[@]}" >/dev/null 2>"$sb/oerr"); orc=$?
  oracle_out=$(sed -e "s#$tmp/[^/[:space:]]*#TMP#g" -e "s#$work#WORK#g" -e "s#$root#ROOT#g" "$sb/stublog" | project; echo "STATUS $orc")
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

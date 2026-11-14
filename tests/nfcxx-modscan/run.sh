#!/bin/bash
# scripts/nfcxx-modscan.rb (the Ruby source scans of the C++ module build) must answer what nfcxx's bash mod_decl_name,
# mod_imports and mod_check_src answer, for every module source of tests/nfcxx-modules/src and for the edge cases written below:
# the same name, the same imports, and the same exit status and message for a refusal. The bash functions are read from nfcxx.
#   bash tests/nfcxx-modscan/run.sh
here=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# the bash functions, as nfcxx defines them (from mod_decl_name up to mod_build_program)
sed -n '/^mod_decl_name() {/,/^# mod_build_program:/p' "$root/nfcxx" | sed '$d' > "$work/bash-scan.sh"
[ -s "$work/bash-scan.sh" ] || { echo "cannot read the bash scan functions from nfcxx"; exit 1; }
cat >> "$work/bash-scan.sh" <<'SH'
# mod_is_module_src is not compared here (it stays in bash on the compile path)
SH
mkdir -p "$work/edge"
printf '  \texport   module  a.b ; // tabbed\nexport import  x.y;\n' > "$work/edge/tabs.cppm"
printf 'export import std.io;\n' > "$work/edge/std_export.cppm"
printf 'import std;\n' > "$work/edge/std_plain.cpp"
printf 'import stdx;\nimport std.compat;\n' > "$work/edge/std_prefix.cpp"
printf 'export module m:part;\n' > "$work/edge/partition.cppm"
printf 'module m:impl;\n' > "$work/edge/impl_part.cpp"
printf 'import <vector>;\n' > "$work/edge/header_angle.cpp"
printf 'export import "h.h";\n' > "$work/edge/header_quote.cpp"
printf 'module ;\nexport module n;\nimport a;\n' > "$work/edge/global_frag.cppm"
printf 'export module first;\nexport module second;\n' > "$work/edge/two_decls.cppm"
printf 'module x;\nexport modulex y;\n' > "$work/edge/not_decl.cppm"
printf 'export module nosemi' > "$work/edge/no_semi.cppm"
printf 'export module q;' > "$work/edge/no_newline.cppm"
printf 'int main() { return 0; }\n' > "$work/edge/plain.cpp"
pass=0; fail=0
files=("$root"/tests/nfcxx-modules/src/* "$work"/edge/*)
for f in "${files[@]}"; do
  # the bash answers, in a subshell (mod_check_src exits 2 on a refusal)
  bdec=$( (source "$work/bash-scan.sh"; mod_decl_name "$f") 2>/dev/null )
  bimp=$( (source "$work/bash-scan.sh"; mod_imports "$f") 2>/dev/null )
  (source "$work/bash-scan.sh"; mod_check_src "$f") > "$work/bash.err" 2>&1; brc=$?
  rdec=$(ruby "$root/scripts/nfcxx-modscan.rb" decl-name "$f")
  rimp=$(ruby "$root/scripts/nfcxx-modscan.rb" imports "$f")
  ruby "$root/scripts/nfcxx-modscan.rb" check "$f" > "$work/ruby.err" 2>&1; rrc=$?
  ok=1
  [ "$bdec" = "$rdec" ] || { ok=0; echo "FAIL decl-name $f: bash [$bdec] ruby [$rdec]"; }
  [ "$bimp" = "$rimp" ] || { ok=0; echo "FAIL imports $f: bash [$bimp] ruby [$rimp]"; }
  [ "$brc" = "$rrc" ] || { ok=0; echo "FAIL check status $f: bash $brc ruby $rrc"; }
  cmp -s "$work/bash.err" "$work/ruby.err" || { ok=0; echo "FAIL check message $f: bash [$(cat "$work/bash.err")] ruby [$(cat "$work/ruby.err")]"; }
  if [ $ok = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
done
echo "nfcxx-modscan: $pass passed, $fail failed (${#files[@]} files)"
[ $fail = 0 ]

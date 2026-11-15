#!/bin/bash
# scripts/nfcxx-modscan.rb (the Ruby source scans of the C++ module build) must answer what nfcxx's bash did, for every module
# source of tests/nfcxx-modules/src and for the edge cases written below:
#   - mod_is_module_src (the grep test of the driver's module block): the same status (0, 1 or 2) as the original grep function
#     in oracle-is-module.sh, and as nfcxx's thin call of the port, for each file and for the unreadable ones;
#   - mod_decl_name, mod_imports and mod_check_src: the same name, the same imports, and the same exit status and message
#     for a refusal, as nfcxx's functions (which call the port).
#   bash tests/nfcxx-modscan/run.sh
here=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# the bash wrappers: the verbatim copy of nfcxx's before the driver made the direct calls (oracle-wrappers.sh)
cp "$here/oracle-wrappers.sh" "$work/bash-scan.sh"
[ -s "$work/bash-scan.sh" ] || { echo "cannot read the bash scan functions from oracle-wrappers.sh"; exit 1; }
# mod_is_module_src: the original grep function (the oracle) and the thin call of the port (also in oracle-wrappers.sh)
cp "$here/oracle-is-module.sh" "$work/oracle-is-module.sh"
sed -n '/^mod_is_module_src() {/,/^}/p' "$here/oracle-wrappers.sh" > "$work/thin-is-module.sh"
[ -s "$work/thin-is-module.sh" ] || { echo "cannot read mod_is_module_src from oracle-wrappers.sh"; exit 1; }
mkdir -p "$work/edge"
e="$work/edge"
printf '  \texport   module  a.b ; // tabbed\nexport import  x.y;\n' > "$e/tabs.cppm"
printf 'export import std.io;\n' > "$e/std_export.cppm"
printf 'import std;\n' > "$e/std_plain.cpp"
printf 'import stdx;\nimport std.compat;\n' > "$e/std_prefix.cpp"
printf 'export module m:part;\n' > "$e/partition.cppm"
printf 'module m:impl;\n' > "$e/impl_part.cpp"
printf 'import <vector>;\n' > "$e/header_angle.cpp"
printf 'export import "h.h";\n' > "$e/header_quote.cpp"
printf 'module ;\nexport module n;\nimport a;\n' > "$e/global_frag.cppm"
printf 'export module first;\nexport module second;\n' > "$e/two_decls.cppm"
printf 'module x;\nexport modulex y;\n' > "$e/not_decl.cppm"
printf 'export module nosemi' > "$e/no_semi.cppm"
printf 'export module q;' > "$e/no_newline.cppm"
printf 'int main() { return 0; }\n' > "$e/plain.cpp"
# is-module cases: comments and string literals that mention module or import, plain C++, unusual whitespace and bytes
printf '// export module hidden;\n/* import std; */\nint a;\n' > "$e/comment_mention.cpp"
printf 'const char *s = "import std;";\n' > "$e/string_mention.cpp"
printf '"import std;"\n' > "$e/string_start.cpp"
printf '   import x;\n' > "$e/indent_import.cpp"
printf 'import\tb;\n' > "$e/tab_import.cpp"
printf 'import<vector>;\n' > "$e/import_no_space.cpp"
printf 'import 2x;\n' > "$e/import_digit.cpp"
printf 'module\n' > "$e/bare_module.cpp"
printf 'module ;\n' > "$e/module_semi_space.cppm"
printf 'int a;\nimport a;' > "$e/import_no_newline.cpp"
printf 'export modulex;\nexport module ;\n' > "$e/module_no_name.cppm"
printf 'export module crlf;\r\nexport import y;\r\n' > "$e/crlf.cppm"
printf '\vimport vt;\n' > "$e/vtab.cpp"
printf '\fexport module ff;\n' > "$e/formfeed.cppm"
printf 'int x; // \xff\xfe caf\xe9\n' > "$e/latin1_plain.cpp"
printf '// caf\xe9 comment\nexport module latin;\nimport a;\n' > "$e/latin1_module.cppm"
printf '\x00\nimport a;\n' > "$e/nul_then_import.cpp"
: > "$e/empty.cpp"
pass=0; fail=0
files=("$root"/tests/nfcxx-modules/src/* "$e"/*)
for f in "${files[@]}"; do
  ok=1
  # the bash answers, in a subshell (mod_check_src exits 2 on a refusal)
  bdec=$( (source "$work/bash-scan.sh"; mod_decl_name "$f") 2>/dev/null )
  bimp=$( (source "$work/bash-scan.sh"; mod_imports "$f") 2>/dev/null )
  (source "$work/bash-scan.sh"; mod_check_src "$f") > "$work/bash.err" 2>&1; brc=$?
  rdec=$(ruby "$root/scripts/nfcxx-modscan.rb" decl-name "$f")
  rimp=$(ruby "$root/scripts/nfcxx-modscan.rb" imports "$f")
  ruby "$root/scripts/nfcxx-modscan.rb" check "$f" > "$work/ruby.err" 2>&1; rrc=$?
  # mod_is_module_src: the original grep function, nfcxx's thin call, and the port's is-module
  (source "$work/oracle-is-module.sh"; mod_is_module_src "$f"); mrc=$?
  (root="$root"; source "$work/thin-is-module.sh"; mod_is_module_src "$f"); trc=$?
  ruby "$root/scripts/nfcxx-modscan.rb" is-module "$f"; qrc=$?
  [ "$bdec" = "$rdec" ] || { ok=0; echo "FAIL decl-name $f: bash [$bdec] ruby [$rdec]"; }
  [ "$bimp" = "$rimp" ] || { ok=0; echo "FAIL imports $f: bash [$bimp] ruby [$rimp]"; }
  [ "$brc" = "$rrc" ] || { ok=0; echo "FAIL check status $f: bash $brc ruby $rrc"; }
  cmp -s "$work/bash.err" "$work/ruby.err" || { ok=0; echo "FAIL check message $f: bash [$(cat "$work/bash.err")] ruby [$(cat "$work/ruby.err")]"; }
  [ "$mrc" = "$qrc" ] || { ok=0; echo "FAIL is-module status $f: grep $mrc ruby $qrc"; }
  [ "$mrc" = "$trc" ] || { ok=0; echo "FAIL is-module thin call $f: grep $mrc nfcxx $trc"; }
  if [ $ok = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
done
# the sources mod_is_module_src cannot read: grep's status 2 (the message differs: grep says "grep: FILE: ...", the port says
# "nfcxx-modscan: FILE: ..."; the driver ignores both, the status is the test)
for f in "$work/no-such-file.cpp" "" "$work"; do
  (source "$work/oracle-is-module.sh"; mod_is_module_src "$f") 2>/dev/null; mrc=$?
  ruby "$root/scripts/nfcxx-modscan.rb" is-module "$f" 2>/dev/null; qrc=$?
  if [ "$mrc" = 2 ] && [ "$qrc" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL is-module unreadable [$f]: grep $mrc ruby $qrc"; fi
done
echo "nfcxx-modscan: $pass passed, $fail failed (${#files[@]} files, 3 unreadable paths)"
[ $fail = 0 ]

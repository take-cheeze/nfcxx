#!/usr/bin/env bash
# Path B CIL spike (docs/notes/pathb-cil.md): C++ files through scripts/pathb-cil, run with dotnet. `// EXPECT: N` is the
# exit status; `// EXPECT-REFUSED: text` means the emitter must refuse the file with a message containing text.
cd "$(dirname "$0")/../.."
root=$PWD; here=$root/tests/pathb-cil
command -v dotnet >/dev/null || { echo "SKIP pathb-cil: dotnet is not installed"; exit 0; }
[ -x "$root/build/cil/ilasm" ] || { echo "SKIP pathb-cil: scripts/setup-cil.sh has not run"; exit 0; }
[ -x "$root/build/pathb/cmake/bin/cpfe" ] || { echo "SKIP pathb-cil: scripts/setup-pathb.sh has not run"; exit 0; }
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for f in "$here"/cases/*.cpp; do
  n=$(basename "$f" .cpp)
  want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$f" | head -1)
  refused=$(sed -n 's,^// EXPECT-REFUSED: *,,p' "$f" | head -1)
  if [ -n "$refused" ]; then
    if "$root/scripts/pathb-cil" -o "$tmp/$n" "$f" 2>"$tmp/$n.err"; then echo "FAIL $n: compiled, want a refusal"; fail=1
    elif grep -qF "$refused" "$tmp/$n.err"; then echo "ok   $n (refused)"
    else echo "FAIL $n: refusal text differs"; head -3 "$tmp/$n.err"; fail=1; fi
    continue
  fi
  if ! "$root/scripts/pathb-cil" -o "$tmp/$n" "$f" 2>"$tmp/$n.err"; then echo "FAIL (compile) $n"; head -5 "$tmp/$n.err"; fail=1; continue; fi
  (cd "$tmp" && ./"$n" >/dev/null 2>"$tmp/$n.run"); got=$?
  if [ "$got" = "$want" ]; then echo "ok   $n"; else echo "FAIL $n: want exit $want got $got"; head -3 "$tmp/$n.run"; fail=1; fi
done
exit $fail

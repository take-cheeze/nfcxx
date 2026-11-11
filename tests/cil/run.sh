#!/usr/bin/env bash
# CIL backend check (docs/notes/cil.md): C programs compiled by nfcc with NFCXX_BACKEND=cil into .NET assemblies and run
# with dotnet. Each case's first line says `// EXPECT: N` (the exit status) and, when tests/cil/cases/NAME.out exists, its
# stdout must match it exactly. tests/cil/multi/NAME is one program of several files (EXPECT in main.c, the first file).
# tests/cil/errors/NAME.c must fail to compile with the text after `// EXPECT-ERROR:`.
# SKIP when dotnet is not installed or scripts/setup-cil.sh has not fetched ilasm.
cd "$(dirname "$0")/../.."
root=$PWD; here=$root/tests/cil
command -v dotnet >/dev/null || { echo "SKIP cil: dotnet is not installed"; exit 0; }
[ -x "$root/build/cil/ilasm" ] || { echo "SKIP cil: scripts/setup-cil.sh has not run"; exit 0; }
export NFCXX_BACKEND=cil
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
check_exit() {  # check_exit NAME WANT_EXIT
  local name=$1 want=$2 got
  (cd "$tmp" && ./"$name" > "$tmp/$name.stdout" 2>"$tmp/$name.stderr"); got=$?
  if [ "$got" != "$want" ]; then echo "FAIL $name: want exit $want got $got"; head -3 "$tmp/$name.stderr"; fail=1; return 1; fi
  return 0
}
for f in "$here"/cases/*.c; do
  n=$(basename "$f" .c); want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$f" | head -1)
  if ! "$root/nfcc" "$f" -o "$tmp/$n" 2>"$tmp/$n.cc"; then echo "FAIL (compile) cases/$n"; head -5 "$tmp/$n.cc"; fail=1; continue; fi
  check_exit "$n" "$want" || continue
  if [ -f "$here/cases/$n.out" ] && ! cmp -s "$here/cases/$n.out" "$tmp/$n.stdout"; then
    echo "FAIL cases/$n: stdout differs"; diff "$here/cases/$n.out" "$tmp/$n.stdout" | head -5; fail=1; continue
  fi
  echo "ok   cases/$n"
done
for d in "$here"/multi/*/; do
  n=$(basename "$d"); want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$d/main.c" | head -1)
  if ! "$root/nfcc" "$d"/*.c -o "$tmp/m-$n" 2>"$tmp/m-$n.cc"; then echo "FAIL (compile) multi/$n"; head -5 "$tmp/m-$n.cc"; fail=1; continue; fi
  check_exit "m-$n" "$want" || continue
  echo "ok   multi/$n"
done
for f in "$here"/errors/*.c; do
  n=$(basename "$f" .c); want=$(sed -n 's,^// EXPECT-ERROR: *,,p' "$f" | head -1)
  if "$root/nfcc" "$f" -o "$tmp/e-$n" 2>"$tmp/e-$n.cc"; then echo "FAIL errors/$n: compiled, want an error"; fail=1; continue; fi
  if grep -qF "$want" "$tmp/e-$n.cc"; then echo "ok   errors/$n"; else echo "FAIL errors/$n: error text differs"; head -3 "$tmp/e-$n.cc"; fail=1; fi
done
exit $fail

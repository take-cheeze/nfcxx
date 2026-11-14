#!/usr/bin/env bash
# CIL backend check (docs/notes/cil.md): C programs compiled by nfcc with NFCXX_BACKEND=cil into .NET assemblies and run
# with dotnet. Each case's first line says `// EXPECT: N` (the exit status) and, when tests/cil/cases/NAME.out exists, its
# stdout must match it exactly. tests/cil/multi/NAME is one program of several files (EXPECT in main.c, the first file).
# tests/cil/errors/NAME.c must fail to compile with the text after `// EXPECT-ERROR:`.
# The compile goes through Path B first (scripts/cil-cc, docs/notes/pathb-cil.md) and falls back to the cproc route when
# Path B refuses a file. A file with `// QBE-ONLY: reason` is one that still needs cproc (it must fall back: when it stops
# doing so the marker is stale); every other file must go through Path B. `// PATHB-ONLY: reason` is a case the cproc route
# gets wrong; it is skipped when NFCXX_CIL_CPROC=1 (the cproc route for every file, which CI runs too).
# SKIP when dotnet is not installed or scripts/setup-cil.rb has not fetched ilasm.
cd "$(dirname "$0")/../.."
root=$PWD; here=$root/tests/cil
command -v dotnet >/dev/null || { echo "SKIP cil: dotnet is not installed"; exit 0; }
[ -x "$root/build/cil/ilasm" ] || { echo "SKIP cil: scripts/setup-cil.rb has not run"; exit 0; }
export NFCXX_BACKEND=cil NFCXX_CIL_VERBOSE=1
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
check_exit() {  # check_exit NAME WANT_EXIT
  local name=$1 want=$2 got
  (cd "$tmp" && ./"$name" > "$tmp/$name.stdout" 2>"$tmp/$name.stderr"); got=$?
  if [ "$got" != "$want" ]; then echo "FAIL $name: want exit $want got $got"; head -3 "$tmp/$name.stderr"; fail=1; return 1; fi
  return 0
}
check_route() {  # check_route LABEL SOURCE STDERR: the route the compile took must match the file's QBE-ONLY marker
  [ -z "${NFCXX_CIL_CPROC:-}" ] || return 0
  if grep -q '^// QBE-ONLY:' "$2"; then
    grep -q "using cproc" "$3" || { echo "FAIL $1: marked QBE-ONLY but Path B took it (remove the marker)"; fail=1; return 1; }
  else
    grep -q "cil-cc: Path B: " "$3" && ! grep -q "using cproc" "$3" || { echo "FAIL $1: Path B refused it:"; grep "using cproc" "$3" | head -2; fail=1; return 1; }
  fi
}
for f in "$here"/cases/*.c; do
  n=$(basename "$f" .c); want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$f" | head -1)
  if [ -n "${NFCXX_CIL_CPROC:-}" ] && grep -q '^// PATHB-ONLY:' "$f"; then echo "skip cases/$n (PATHB-ONLY)"; continue; fi
  if ! "$root/nfcc" "$f" -o "$tmp/$n" 2>"$tmp/$n.cc"; then echo "FAIL (compile) cases/$n"; head -5 "$tmp/$n.cc"; fail=1; continue; fi
  check_route "cases/$n" "$f" "$tmp/$n.cc" || continue
  check_exit "$n" "$want" || continue
  if [ -f "$here/cases/$n.out" ] && ! cmp -s "$here/cases/$n.out" "$tmp/$n.stdout"; then
    echo "FAIL cases/$n: stdout differs"; diff "$here/cases/$n.out" "$tmp/$n.stdout" | head -5; fail=1; continue
  fi
  echo "ok   cases/$n"
done
for d in "$here"/multi/*/; do
  n=$(basename "$d"); want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$d/main.c" | head -1)
  if ! "$root/nfcc" "$d"/*.c -o "$tmp/m-$n" 2>"$tmp/m-$n.cc"; then echo "FAIL (compile) multi/$n"; head -5 "$tmp/m-$n.cc"; fail=1; continue; fi
  if [ -z "${NFCXX_CIL_CPROC:-}" ] && [ "$(grep -c 'cil-cc: Path B: ' "$tmp/m-$n.cc")" != "$(ls "$d"/*.c | wc -l)" ]; then
    echo "FAIL multi/$n: not every file went through Path B"; grep "using cproc" "$tmp/m-$n.cc" | head -2; fail=1; continue
  fi
  check_exit "m-$n" "$want" || continue
  echo "ok   multi/$n"
done
for f in "$here"/errors/*.c; do
  n=$(basename "$f" .c); want=$(sed -n 's,^// EXPECT-ERROR: *,,p' "$f" | head -1)
  if "$root/nfcc" "$f" -o "$tmp/e-$n" 2>"$tmp/e-$n.cc"; then echo "FAIL errors/$n: compiled, want an error"; fail=1; continue; fi
  if [ -z "${NFCXX_CIL_CPROC:-}" ]; then check_route "errors/$n" "$f" "$tmp/e-$n.cc" || continue; fi
  if grep -qF "$want" "$tmp/e-$n.cc"; then echo "ok   errors/$n"; else echo "FAIL errors/$n: error text differs"; head -3 "$tmp/e-$n.cc"; fail=1; fi
done
exit $fail

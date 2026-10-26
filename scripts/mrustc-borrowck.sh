#!/usr/bin/env bash
# Borrow-check a Rust program's own functions with scripts/pathb-borrowck.rb, through mrustc's
# monomir dump (see docs/notes/mrustc-borrowck.md). mrustc itself has no borrow checker.
#   scripts/mrustc-borrowck.sh prog.rs [mrustc flags...]
# Exit status is the checker's: 0 accepted, 1 a borrow or initialization error, 2 malformed IR,
# 3 refused (outside the supported subset). 4 means mrustc or the translator failed.
#   MRUSTC=<bin>, MRUSTC_STD=<dir>  as for scripts/mrustc-monomir.sh
#   MRUSTC_BORROWCK_KEEP=<dir>      keep the dump (prog.mir) and the checker input (prog.ir) there
set -uo pipefail
start=$PWD
cd "$(dirname "$0")/.."
root=$PWD
mrustc=${MRUSTC:-$root/build/mrustc/src/bin/mrustc}
std=${MRUSTC_STD:-$root/build/mrustc/src/output-1.90.0}

src="" extra=()
for a in "$@"; do
  case $a in
    *.rs) src=$a ;;
    *) extra+=("$a") ;;
  esac
done
[ -n "$src" ] || { echo "usage: scripts/mrustc-borrowck.sh prog.rs [mrustc flags...]" >&2; exit 4; }
case $src in /*) ;; *) src=$start/$src ;; esac
[ -x "$mrustc" ] && [ -f "$std/libstd.rlib.o" ] || { echo "mrustc-borrowck: no mrustc or standard library; run scripts/setup-mrustc.sh" >&2; exit 4; }

if [ -n "${MRUSTC_BORROWCK_KEEP:-}" ]; then
  tmp=$MRUSTC_BORROWCK_KEEP; mkdir -p "$tmp"
else
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fi

# Unoptimised MIR (-Z disable-mir-opt also turns off inlining after monomorphisation), so the checker
# sees the borrows and scopes the source has, with SCOPEEND statements for the ends of storage.
# A subshell, so that the shell's own report of an aborted mrustc goes to the log too.
( MRUSTC_MMIR_SCOPE_END=1 MRUSTC_TARGET_VER=${MRUSTC_TARGET_VER:-1.90} exec "$mrustc" "$src" -o "$tmp/prog" -L "$std" \
  --edition 2021 -C codegen-type=monomir -Z disable-mir-opt ${extra[@]+"${extra[@]}"} ) >"$tmp/mrustc.log" 2>&1 || {
  # mrustc's MIR validation tracks which locals are valid, so it rejects a use after a move or of an
  # uninitialized local itself, and its lifetime inference rejects a reference that outlives its
  # referent's function. Those are verdicts on the program, reported as the checker's errors are.
  if grep -q '^MIR ERROR: .*Use of non-valid lvalue' "$tmp/mrustc.log"; then
    sed -n 's/^MIR ERROR: /mrustc-mir-validation: /p' "$tmp/mrustc.log" | head -1
    exit 1
  fi
  if grep -q 'error:0: Lifetime bound .* failed' "$tmp/mrustc.log"; then
    sed -n 's/^.* error:0: \(Lifetime bound .* failed.*\)$/mrustc-lifetime: \1/p' "$tmp/mrustc.log" | head -1
    exit 1
  fi
  tail -20 "$tmp/mrustc.log" >&2; echo "mrustc-borrowck: mrustc failed" >&2; exit 4
}
ruby "$root/scripts/monomir-to-pathb.rb" --borrow "$tmp/prog.mir" "$tmp/prog.ir" ||
  { echo "mrustc-borrowck: monomir-to-pathb failed" >&2; exit 4; }
"$root/scripts/mrb" "$root/scripts/pathb-borrowck.rb" --infer-loan-ends --infer-summaries "$tmp/prog.ir"

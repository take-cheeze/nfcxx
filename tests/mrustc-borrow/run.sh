#!/usr/bin/env bash
# Rust programs borrow-checked through mrustc's MIR and scripts/pathb-borrowck.rb
# (scripts/mrustc-borrowck.sh, docs/notes/mrustc-borrowck.md). Each case says what rustc does with it
# (`// rustc: ok` or the error code) and what this pipeline must do (`// nfcxx: ok|error|refused`),
# with optional `// diag: TEXT` lines that must appear in the output. The cases where the two differ
# are the known gaps. The rustc verdicts are those of rustc 1.99.0. When rustc is installed, its verdict
# is compared with the case's and a difference is printed as a note: an older rustc rejects some
# programs that 1.99 accepts (gap_two_offsets, NLL's problem case 3). Needs scripts/setup-mrustc.sh first.
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; agree=0; differ=0
rustc=${RUSTC:-$(command -v rustc || true)}
for src in tests/mrustc-borrow/cases/*.rs; do
  name=$(basename "$src" .rs)
  want_rustc=$(sed -n 's|^// rustc: \([A-Za-z0-9]*\).*|\1|p' "$src" | head -1)
  want=$(sed -n 's|^// nfcxx: \([a-z]*\).*|\1|p' "$src" | head -1)
  out=$(scripts/mrustc-borrowck.sh "$src" 2>&1); rc=$?
  case $rc in 0) got=ok ;; 1) got=error ;; 3) got=refused ;; *) got="failed($rc)" ;; esac
  ok=1
  [ "$got" = "$want" ] || { echo "FAIL $name: expected $want, got $got"; echo "$out" | sed 's/^/  /' | tail -5; ok=0; }
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    grep -Fq -- "$d" <<<"$out" || { echo "FAIL $name: missing diagnostic '$d'"; echo "$out" | sed 's/^/  /' | tail -5; ok=0; }
  done < <(sed -n 's|^// diag: ||p' "$src")
  if [ -n "$rustc" ]; then
    r=$("$rustc" --edition 2021 --crate-type bin --emit=metadata -o "$tmp/$name.rmeta" "$src" 2>&1 | grep -o 'error\[E[0-9]*\]' | head -1)
    r=${r#error[}; r=${r%]}; r=${r:-ok}
    [ "$r" = "$want_rustc" ] || echo "note $name: $("$rustc" --version) gives $r, the case records $want_rustc"
  fi
  # rustc's verdict against ours: an error code is a rejection, so it agrees with error.
  if { [ "$want_rustc" = ok ] && [ "$got" = ok ]; } || { [ "$want_rustc" != ok ] && [ "$got" = error ]; }; then
    agree=$((agree + 1)); verdict=agree
  else
    differ=$((differ + 1)); verdict=differs
  fi
  if [ $ok = 1 ]; then echo "ok   $name (rustc $want_rustc, nfcxx $got: $verdict)"; pass=$((pass + 1)); else fail=$((fail + 1)); fi
done
[ -n "$rustc" ] || echo "note: no rustc, so the cases' rustc verdicts were not checked"
echo "pass $pass fail $fail; same verdict as rustc $agree, different $differ"
[ $fail -eq 0 ]

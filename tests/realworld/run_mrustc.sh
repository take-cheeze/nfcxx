#!/usr/bin/env bash
# Real crates with dependencies through mrustc and nfcxx's C pipeline. Each case directory under tests/realworld/mrustc
# holds a program (src/main.rs), its Cargo.toml and Cargo.lock (the lock pins the versions mrustc compiles, and every entry
# under [dependencies] is a crate it uses), and expected.txt: what rustc prints for the program. The dependency
# tree is built by mrustc's minicargo from a `cargo vendor` of the lock, and the program and every crate of its link are
# compiled by scripts/mrustc-nfcc.sh with MRUSTC_NFCC_CRATES=all. Needs scripts/setup-mrustc.sh, cargo (cargo vendor
# downloads the crates) and network access. With --monomir, the program and reachable generics
# use Path B and QBE; remaining dependency functions link against mrustc's gcc-built objects.
#   tests/realworld/run_mrustc.sh [--monomir] [case...]     (default: every case)
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
std=$root/build/mrustc/src/output-1.90.0
mrustc_bin=$root/build/mrustc/src/bin
driver=mrustc-nfcc
if [ "${1:-}" = --monomir ]; then
  driver=mrustc-monomir
  shift
fi
cases=("$@")
[ ${#cases[@]} -gt 0 ] || cases=($(ls tests/realworld/mrustc))
pass=0; fail=0

for case in "${cases[@]}"; do
  src=$root/tests/realworld/mrustc/$case
  work=$root/build/mrustc/realworld/$case
  out=$work/out
  pkg=$(sed -n 's/^name = "\(.*\)"/\1/p' "$src/Cargo.toml" | head -1)
  tag=$(sed -n 's/^version = "\(.*\)"/\1/p' "$src/Cargo.toml" | head -1 | tr . _)
  deps=$(sed -n '/^\[dependencies\]/,$p' "$src/Cargo.toml" | sed -n 's/^\([A-Za-z0-9_-]*\) = .*/\1/p')
  mkdir -p "$out"
  [ -d "$work/vendor" ] || (cd "$src" && cargo vendor --locked -q "$work/vendor" > /dev/null)
  # minicargo looks for core and the other std crates in its output directory, so the library output is copied there.
  [ -f "$out/libstd.rlib.o" ] || cp -r "$std/." "$out/"
  # minicargo writes mrustc's configuration dump into the working directory, so it runs in the build directory.
  if ! (cd "$work" && MRUSTC_TARGET_VER=1.90 "$mrustc_bin/minicargo" "$src" --vendor-dir "$work/vendor" --output-dir "$out" > "$work/minicargo.log" 2>&1); then
    tail -20 "$work/minicargo.log" >&2
    echo "FAIL $case: minicargo" ; fail=$((fail + 1)); continue
  fi
  externs=()
  for dep in $deps; do
    ext=${dep//-/_}
    externs+=(--extern "$ext=$(ls "$out/lib$ext"-*.rlib | head -1)")
  done
  if ! MRUSTC_NFCC_CRATES=all MRUSTC_STD="$out" "$root/scripts/$driver.sh" "$src/src/main.rs" -o "$work/$pkg" \
      --crate-name "${pkg//-/_}" --crate-type bin --crate-tag "$tag" "${externs[@]}" --cfg debug_assertions -O \
      > "$work/nfcc.log" 2>&1; then
    tail -20 "$work/nfcc.log" >&2
    echo "FAIL $case: $driver" ; fail=$((fail + 1)); continue
  fi
  if got=$("$work/$pkg" 2>&1) && [ "$got" = "$(cat "$src/expected.txt")" ]; then
    echo "ok   $case ($(echo $deps | tr " " ",") through $driver)"; pass=$((pass + 1))
  else
    echo "FAIL $case: output differs from expected.txt"; fail=$((fail + 1))
  fi
done

echo "pass $pass fail $fail"
[ $fail -eq 0 ]

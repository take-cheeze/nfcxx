#!/usr/bin/env bash
# A real crate with dependencies through mrustc and nfcxx's C pipeline: serde_json 1.0.133 (with serde, serde_core, ryu,
# itoa and memchr) is built by mrustc's minicargo, and then the program and every crate of its link are compiled by
# scripts/mrustc-nfcc.sh. The expected output is what rustc prints for the same program. Needs scripts/setup-mrustc.sh,
# cargo (cargo vendor downloads the crates) and network access.
# The lock file pins serde_json 1.0.133: 1.0.154 depends on zmij, which mrustc 1.90 does not compile (its type checker
# reports "Mismatched types - f64 and f32").
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
std=$root/build/mrustc/src/output-1.90.0
mrustc_bin=$root/build/mrustc/src/bin
src=$root/tests/realworld/mrustc/serde-json
work=$root/build/mrustc/realworld/serde-json
out=$work/out
mkdir -p "$work" "$out"

[ -d "$work/vendor" ] || (cd "$src" && cargo vendor --locked -q "$work/vendor" > /dev/null)
# minicargo looks for core and the other std crates in its output directory, so the library output is copied there.
cp -rn "$std/." "$out/"
MRUSTC_TARGET_VER=1.90 "$mrustc_bin/minicargo" "$src" --vendor-dir "$work/vendor" --output-dir "$out" > "$work/minicargo.log" 2>&1 \
  || { tail -20 "$work/minicargo.log" >&2; echo "realworld serde-json: minicargo failed" >&2; exit 1; }

MRUSTC_NFCC_CRATES=all MRUSTC_STD="$out" "$root/scripts/mrustc-nfcc.sh" "$src/src/main.rs" -o "$work/jsonapp" \
  --crate-name jsonapp --crate-type bin --crate-tag 0_1_0 --extern "serde_json=$out/libserde_json-1_0_133_H22080.rlib" \
  --cfg debug_assertions -O

want=$'"nfcxx"\n"rust"\n43\n{"n":42,"name":"nfcxx","ok":true,"pi":3.5,"tags":["c","rust"]}\ntrue\nerror at line 1'
got=$("$work/jsonapp" 2>&1) || { echo "FAIL serde-json: exit $?, output '$got'"; exit 1; }
if [ "$got" != "$want" ]; then echo "FAIL serde-json: output '$got'"; exit 1; fi
echo "ok   serde-json (serde_json 1.0.133 through mrustc and nfcxx)"

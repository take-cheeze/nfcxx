#!/usr/bin/env bash
# Path B with zero-cost exception handling (docs/notes/pathb-zero-cost-eh.md): EDG's partial EH lowering, landing pads and
# exception tables (QBE's eh directives), the Itanium C++ ABI runtime of libstdc++. The programs:
#
#   tests/pathb-eh-tables/cases/*.cpp   this mode's own probes. NAME.helper.cpp beside one is compiled by g++ and linked
#                                       in: exceptions cross between the two compilers' code in both directions.
#   tests/pathb-eh-tables/traps/*.cpp   programs that must end in std::terminate (exit status 134, SIGABRT).
#   tests/pathb-qbe/cases/eh_*.cpp, tests/pathb-qbe/traps/eh_*.cpp, tests/cases/eh_*.cpp
#                                       the EH probes of the frames mode (the default Path B harness), run here too.
#
# Each: scripts/pathb-dump.rb --ir (a PATHB_EH=tables harness) -> scripts/pathb-ir-opt.rb (pathb-cc's passes) ->
# scripts/pathb-ssa-build -> cc, linked with be/nfcxx_ehrt.c (the personality wrapper), the long double helpers and
# libstdc++, not EDG's libC.a. The exit code must equal the // EXPECT: value; `// STDOUT: same` also needs the standard
# output of the g++ build of the same sources. A trap's stderr message is libstdc++'s, not EDG's runtime's, so a
# `// TRAP-STDERR:` line is not checked. `// TABLES-SKIP: reason` skips a program in this mode (counted, reported).
#
#   PATHB_CPFE, PATHB_BASE   the harness (scripts/setup-pathb.sh with PATHB_EH=tables); QBE: a QBE with the eh directives.
# Exit 1 on any failure, 2 when the harness or QBE is missing.
set -u
cd "$(dirname "$0")/../.."
root=$PWD
cpfe=${PATHB_CPFE:-}
[ -n "$cpfe" ] && [ -x "$cpfe" ] || { echo "pathb-eh-tables: set PATHB_CPFE and PATHB_BASE to a PATHB_EH=tables harness" >&2; exit 2; }
qbe=${QBE:-build/qbe/qbe}
[ -x "$qbe" ] || { echo "pathb-eh-tables: no QBE at $qbe" >&2; exit 2; }
printf 'function $f() {\n@s\n\tehnoexcept\n\tret\n}\n' | "$qbe" - >/dev/null 2>&1 || { echo "pathb-eh-tables: $qbe has no exception table directives (set QBE)" >&2; exit 2; }
tmo="timeout 10 "; command -v timeout >/dev/null 2>&1 || tmo=""
ldrt=$(scripts/pathb-ldrt.rb) || exit 2
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cc -O2 -c -o "$tmp/ehrt.o" be/nfcxx_ehrt.c || exit 2
total=0; pass=0; failed=0; skipped=0
lines=()

build() { # SRC STEM: SRC through the pipeline to STEM.exe (with SRC's helper); a message on stdout when it fails
  local f=$1 n=$2 std flags h=
  std=$(sed -n 's,^// STD: *\(c++[0-9a-z]*\).*,-std=\1,p' "$f" | head -1)
  scripts/pathb-dump.rb --ir $std "$f" > "$n.ir" 2> "$n.fe" || { echo "front end: $(head -1 "$n.fe")"; return 1; }
  if grep -q '(unsupported' "$n.ir"; then echo "unsupported: $(grep -o '(unsupported[^)]*' "$n.ir" | sort -u | head -1)"; return 1; fi
  ruby scripts/pathb-ir-opt.rb --prune-unused --strip-leaf-eh --inline --scope-facts --shrink-eh-frames "$n.ir" > "$n.opt.ir" 2> "$n.opt" &&
    mv "$n.opt.ir" "$n.ir"
  scripts/pathb-ssa-build --qbe="$qbe" -o "$n.s" "$n.ir" 2> "$n.ssa" || { echo "ssa/qbe: $(grep -v '^\s*from ' "$n.ssa" | head -1)"; return 1; }
  if [ -f "${f%.cpp}.helper.cpp" ]; then
    h=$n.helper.o
    g++ -O1 -c -o "$h" "${f%.cpp}.helper.cpp" 2> "$n.hcc" || { echo "helper: $(head -1 "$n.hcc")"; return 1; }
  fi
  cc -o "$n.exe" "$n.s" $h "$tmp/ehrt.o" "$ldrt" -lstdc++ -lgcc_s -lpthread -lm -latomic 2> "$n.ld" ||
    { echo "link: $(grep -m1 -o 'undefined reference to .*' "$n.ld" || head -1 "$n.ld")"; return 1; }
}

run_one() { # SRC trap|case
  local f=$1 mode=$2 n name want got skip msg
  total=$((total + 1))
  name=${f#tests/}; n=$tmp/$(echo "$name" | tr '/' '_' | sed 's/\.cpp$//')
  skip=$(sed -n 's,^// TABLES-SKIP: *,,p' "$f" | head -1)
  if [ -n "$skip" ]; then skipped=$((skipped + 1)); lines+=("SKIP     $name: $skip"); return; fi
  if ! msg=$(build "$f" "$n"); then failed=$((failed + 1)); lines+=("FAIL     $name: $msg"); return; fi
  sh -c "${tmo}"'"$0" > "$1" 2> "$2"; exit $?' "$n.exe" "$n.stdout" "$n.stderr"; got=$?
  if [ "$mode" = trap ]; then want=134; else want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$f" | head -1); fi
  if [ "$got" != "$want" ]; then
    failed=$((failed + 1)); lines+=("FAIL     $name: exit $got, expected $want $(head -c 200 "$n.stderr" | tr '\n' ' ')"); return
  fi
  if grep -q '^// STDOUT: same' "$f"; then
    local hs=; [ -f "${f%.cpp}.helper.cpp" ] && hs=${f%.cpp}.helper.cpp
    local std; std=$(sed -n 's,^// STD: *\(c++[0-9a-z]*\).*,-std=\1,p' "$f" | head -1)
    if ! g++ $std -o "$n.gcc" "$f" $hs 2> "$n.gcccc"; then
      failed=$((failed + 1)); lines+=("FAIL     $name: g++: $(head -1 "$n.gcccc")"); return
    fi
    "$n.gcc" > "$n.gccout" 2> /dev/null
    if ! cmp -s "$n.stdout" "$n.gccout"; then
      failed=$((failed + 1)); lines+=("FAIL     $name: standard output differs from g++'s"); return
    fi
  fi
  pass=$((pass + 1)); lines+=("ok       $name")
}

for f in tests/pathb-eh-tables/cases/*.cpp tests/pathb-qbe/cases/eh_*.cpp tests/cases/eh_*.cpp; do
  case $f in *.helper.cpp) continue ;; esac
  [ -f "$f" ] && run_one "$f" case
done
for f in tests/pathb-eh-tables/traps/*.cpp tests/pathb-qbe/traps/eh_*.cpp; do
  case $f in *.helper.cpp) continue ;; esac
  [ -f "$f" ] && run_one "$f" trap
done
printf '%s\n' "${lines[@]}"
echo "pathb-eh-tables: $total programs, $pass pass, $failed fail, $skipped skipped"
[ "$failed" = 0 ]

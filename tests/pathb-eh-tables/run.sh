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
# scripts/pathb-ssa-build -> cc, linked with libnfcxxld.a (scripts/pathb-ldrt.rb: the long double helpers)
# and libstdc++ (its personality, __gxx_personality_v0, is the tables'), with no EDG libC.a: the lowering's helpers (VLAs,
# complex arithmetic) are the link script's libnfcxxedg.a, and libstdc++ has the C++ ABI, its EH runtime and RTTI. The exit code must equal the // EXPECT:
# value; `// STDOUT: same` also needs the standard output of the g++ build of the same sources. A trap's stderr message is libstdc++'s, not EDG's runtime's, so a
# `// TRAP-STDERR:` line is not checked. `// TABLES-SKIP: reason` skips a program in this mode (counted, reported).
#
# --all: every program of tests/pathb-qbe/cases and tests/cases, not only their EH probes (in this mode every function with
# a destructor has landing pads).
#   PATHB_CPFE, PATHB_BASE   the harness (scripts/setup-pathb.sh with PATHB_EH=tables; default build/pathb, the default
#                            harness, when it has tables); QBE: a QBE with the eh directives.
# Exit 1 on any failure, 2 when the harness or QBE is missing.
set -u
ulimit -c 0   # the traps abort: no core files
cd "$(dirname "$0")/../.."
root=$PWD
cpfe=${PATHB_CPFE:-$root/build/pathb/cmake/bin/cpfe}
[ -x "$cpfe" ] && [ -f "$(dirname "$cpfe")/eh-tables" ] ||
  { echo "pathb-eh-tables: set PATHB_CPFE and PATHB_BASE to a PATHB_EH=tables harness ($cpfe has no tables)" >&2; exit 2; }
export PATHB_CPFE=$cpfe PATHB_BASE=${PATHB_BASE:-$(dirname "$(dirname "$(dirname "$cpfe")")")/edg-base}
qbe=${QBE:-build/qbe/qbe}
[ -x "$qbe" ] || { echo "pathb-eh-tables: no QBE at $qbe" >&2; exit 2; }
printf 'function $f() {\n@s\n\tehnoexcept\n\tret\n}\n' | "$qbe" - >/dev/null 2>&1 || { echo "pathb-eh-tables: $qbe has no exception table directives (set QBE)" >&2; exit 2; }
tmo="timeout 10 "; command -v timeout >/dev/null 2>&1 || tmo=""
ldrt=$(scripts/pathb-ldrt.rb) || exit 2
libdir=${EDG_LIB:-$root/build/edg/lib}
# (scripts/pathb-ldrt.rb copies the helpers out of it)
[ -f "$libdir/libC.a" ] || { echo "pathb-eh-tables: no $libdir/libC.a" >&2; exit 2; }
# the host's C++ library: libc++ (its C++ ABI and EH runtime) on macOS, libstdc++ and libgcc_s elsewhere
if [ "$(uname -s)" = Darwin ]; then hostlibs="-lc++ -lpthread -lm"; else hostlibs="-lstdc++ -lgcc_s -lpthread -lm -latomic"; fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
total=0; pass=0; failed=0; skipped=0
lines=()

build() { # SRC STEM: SRC through the pipeline to STEM.exe (with SRC's helper); a message on stdout when it fails
  local f=$1 n=$2 std flags h=
  std=$(sed -n 's,^// STD: *\(c++[0-9a-z]*\).*,-std=\1,p' "$f" | head -1)
  flags=$(sed -n 's,^// NFCXX-FLAGS: *,,p' "$f" | head -1)   # (as tests/pathb-qbe/run.sh: front end options)
  scripts/pathb-dump.rb --ir --ir-noinline $std $flags "$f" > "$n.ir" 2> "$n.fe" || { echo "front end: $(head -1 "$n.fe")"; return 1; }
  ruby scripts/pathb-ir-opt.rb --prune-unused --strip-leaf-eh --inline --hoist-pure --scope-facts --shrink-eh-frames "$n.ir" > "$n.opt.ir" 2> "$n.opt" &&
    mv "$n.opt.ir" "$n.ir"
  scripts/pathb-ssa-build --qbe="$qbe" -o "$n.s" "$n.ir" 2> "$n.ssa" || { echo "ssa/qbe: $(grep -v '^\s*from ' "$n.ssa" | head -1)"; return 1; }
  if [ -f "${f%.cpp}.helper.cpp" ]; then
    h=$n.helper.o
    g++ -O1 -c -o "$h" "${f%.cpp}.helper.cpp" 2> "$n.hcc" || { echo "helper: $(head -1 "$n.hcc")"; return 1; }
  fi
  cc -o "$n.exe" "$n.s" $h "$ldrt" $hostlibs 2> "$n.ld" ||
    { echo "link: $(grep -m1 -o 'undefined reference to .*' "$n.ld" || head -1 "$n.ld")"; return 1; }
}

run_one() { # SRC trap|case
  local f=$1 mode=$2 n name want got skip msg
  total=$((total + 1))
  name=${f#tests/}; n=$tmp/$(echo "$name" | tr '/' '_' | sed 's/\.cpp$//')
  skip=$(sed -n 's,^// TABLES-SKIP: *,,p' "$f" | head -1)
  if [ -n "$skip" ]; then skipped=$((skipped + 1)); lines+=("SKIP     $name: $skip"); return; fi
  # a documented macOS-only failure (its marker, as tests/run.sh reads it): skipped on Darwin, and said so
  if [ "$(uname -s)" = Darwin ]; then
    xf=$(sed -n 's,^// MACOS-XFAIL-pathb: *,,p' "$f" | head -1)
    if [ -n "$xf" ]; then skipped=$((skipped + 1)); lines+=("SKIP     $name (macOS): $xf"); return; fi
  fi
  if ! msg=$(build "$f" "$n"); then failed=$((failed + 1)); lines+=("FAIL     $name: $msg"); return; fi
  sh -c "${tmo}"'"$0" > "$1" 2> "$2"; exit $?' "$n.exe" "$n.stdout" "$n.stderr"; got=$?
  if [ "$mode" = trap ]; then want=134; else want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$f" | head -1); fi
  if [ "$got" != "$want" ]; then
    failed=$((failed + 1)); lines+=("FAIL     $name: exit $got, expected $want $(head -c 200 "$n.stderr" | tr '\n' ' ')"); return
  fi
  # (`// GCC-SKIP:` and `// GCC: undefined`, as tests/pathb-qbe/run.sh: g++ is not compared)
  if grep -q '^// STDOUT: same' "$f" && ! grep -q '^// GCC-SKIP\|^// GCC: undefined' "$f"; then
    local hs=; [ -f "${f%.cpp}.helper.cpp" ] && hs=${f%.cpp}.helper.cpp
    local std; std=$(sed -n 's,^// STD: *\(c++[0-9a-z]*\).*,-std=\1,p' "$f" | head -1)
    [ -n "$std" ] || std=-std=c++23   # the front end's default (scripts/pathb-dump.rb)
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

pat=eh_; [ "${1:-}" = --all ] && pat=
for f in tests/pathb-eh-tables/cases/*.cpp tests/pathb-qbe/cases/$pat*.cpp tests/cases/$pat*.cpp; do
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

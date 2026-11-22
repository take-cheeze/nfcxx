#!/usr/bin/env bash
# Path B with -g (scripts/pathb-cc.rb -g): the IR's (loc ...) statements become QBE's dbgloc lines, so the object has a
# line table. -g must not change the code: each program here, compiled at -O2 with and without -g, has the same .text,
# and the -g object has a .debug_line section. The programs are the ones whose code -g changed before the fixes (the
# inliner's size counted the locations, the e-graph pass took one for a memory write, QBE did not thread a jump
# through a block of dbgloc lines, its vectorizer refused a loop header with one, a dbgloc after a call kept the tail
# call from being made), and a few others.
#   PATHB_CPFE, PATHB_BASE   the harness (default build/pathb)
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
cases="tests/cases/qbe_empty_struct_copy.cpp tests/pathb-qbe/cases/vla.cpp tests/pathb-qbe/cases/likely_unlikely.cpp
       tests/pathb-qbe/cases/hosted_string.cpp tests/pathb-qbe/cases/hosted_unordered.cpp tests/pathb-qbe/cases/gaps_regex.cpp
       tests/pathb-qbe/cases/eh_types.cpp tests/pathb-qbe/cases/gaps_alloca.cpp tests/pathb-qbe/cases/int128_misc.cpp
       tests/pathb-qbe/cases/eh_std.cpp tests/cases/virtual_dispatch.cpp tests/cases/exceptions.cpp"
for f in $cases; do
  n=$(basename "$f" .cpp)
  std=$(sed -n 's,^// STD: *\(c++[0-9]*\).*,-std=\1,p' "$f" | head -1)
  if ! ruby scripts/pathb-cc.rb -O2 $std -c "$f" -o "$tmp/$n.o" 2> "$tmp/$n.err" ||
     ! ruby scripts/pathb-cc.rb -O2 -g $std -c "$f" -o "$tmp/$n-g.o" 2>> "$tmp/$n.err"; then
    echo "FAIL $f: $(head -1 "$tmp/$n.err")"; fail=$((fail + 1)); continue
  fi
  if ! readelf -S "$tmp/$n-g.o" | grep -q '\.debug_line'; then
    echo "FAIL $f: no .debug_line with -g"; fail=$((fail + 1)); continue
  fi
  if readelf -S "$tmp/$n.o" | grep -q '\.debug_line'; then
    echo "FAIL $f: a .debug_line without -g"; fail=$((fail + 1)); continue
  fi
  objcopy -O binary -j .text "$tmp/$n.o" "$tmp/$n.text"
  objcopy -O binary -j .text "$tmp/$n-g.o" "$tmp/$n-g.text"
  if cmp -s "$tmp/$n.text" "$tmp/$n-g.text"; then
    echo "ok   $f"; pass=$((pass + 1))
  else
    echo "FAIL $f: -g changes the code"; fail=$((fail + 1))
  fi
done
echo "pathb-debug: $pass passed, $fail failed"
[ $fail = 0 ]

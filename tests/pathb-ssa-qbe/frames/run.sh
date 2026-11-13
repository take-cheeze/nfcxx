#!/usr/bin/env bash
# Stack frames of the SSA route (scripts/pathb-ssa.rb, scripts/pathb-ssa-qbe.rb), docs/notes/pathb-ssa-qbe.md, "Frames".
#  1. setjmp.ir: a function that calls _setjmp keeps in memory only the slots that are live after the call ("a": assigned before
#     the call, set in one arm, read after the second return), and promotes the others ("t": written after the call before any
#     read). The result of the second return must see a's last store (10 + n + 5): a promoted "a" would give 1 + n + 5.
#  2. share.ir: slots whose (life-start)/(life-end) lifetimes do not overlap share one stack object (what --scope-facts of
#     scripts/pathb-ir-opt.rb writes around each inlined body). Seven 1 KB arrays: a, b, c and e (in a loop) are never live together
#     and share one; d overlaps c and does not join it; f has no facts and g is named after its life-end, so neither is shared.
#     The frame is 4 KB, not 7 KB (3 KB if c and d overlapped), and the sums (which fill/sumi in drv.c recompute) are right.
set -eu
cd "$(dirname "$0")/../../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dir=tests/pathb-ssa-qbe/frames

# 1. setjmp
ruby scripts/pathb-ssa.rb $dir/setjmp.ir > "$tmp/sj.ssa"
promoted=$(sed -n 's/^  (ssa-promoted \(.*\))$/\1/p' "$tmp/sj.ssa" | tr '\n' ' ')
case $promoted in
  *'"t"'*) ;;
  *) echo "FAIL setjmp: t (dead after the call) is not promoted: '$promoted'"; exit 1 ;;
esac
case $promoted in
  *'"a"'*) echo "FAIL setjmp: a (live after the call) is promoted: '$promoted'"; exit 1 ;;
esac
ruby scripts/pathb-ssa-build -o "$tmp/sj.s" $dir/setjmp.ir
cat > "$tmp/sj.c" <<'EOF'
#include <setjmp.h>
#include <stdio.h>
int case_main(int);
int main(void) {
  int ns[] = {0, 3, -4, 100};
  for (int k = 0; k < 4; k++) printf("%d ", case_main(ns[k]));
  printf("\n");
  return 0;
}
EOF
cc "$tmp/sj.c" "$tmp/sj.s" -o "$tmp/sj"
got=$("$tmp/sj")
want="15 18 11 115 "
[ "$got" = "$want" ] || { echo "FAIL setjmp: got '$got', want '$want'"; exit 1; }
echo "ok   setjmp: dead slots promoted, live slot in memory: $got"

# 2. sharing
ruby scripts/pathb-ssa-build -o "$tmp/sh.s" $dir/share.ir
cc $dir/drv.c "$tmp/sh.s" -o "$tmp/sh"
got=$("$tmp/sh")
[ "$got" = ok ] || { echo "FAIL share: $got"; exit 1; }
frame=$(awk '$0 == "case_main:" { on = 1; next } on && /subq \$[0-9]+, %rsp/ { gsub(/[$,]/, "", $2); print $2; exit }' "$tmp/sh.s")
if [ -z "$frame" ] || [ "$frame" -lt 4096 ] || [ "$frame" -gt 4300 ]; then
  echo "FAIL share: frame of case_main is '$frame' bytes, want 4096 to 4300 (7 KB without sharing, 3 KB if c and d were shared)"; exit 1
fi
echo "ok   share: frame $frame bytes for seven 1 KB arrays, sums right"

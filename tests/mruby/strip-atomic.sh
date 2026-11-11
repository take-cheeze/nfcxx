#!/usr/bin/env bash
# scripts/strip-atomic.{py,rb}: the mruby port must give the same bytes as the Python original (the oracle in
# tests/mruby/oracle/) on each input in tests/mruby/strip-atomic/, which covers nested and unbalanced parentheses,
# identifiers that contain the keyword, CRLF line ends, the keyword at end of file and an empty input.
cd "$(dirname "$0")/../.."
root=$PWD; here=$root/tests/mruby/strip-atomic
[ -x "${MRB:-$root/build/mruby-tool/bin/mruby}" ] || { echo "SKIP strip-atomic: no mruby (scripts/setup-mruby.sh)"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
for f in "$here"/*.c; do
  n=$(basename "$f")
  "$root/scripts/mrb" "$root/tests/mruby/oracle/strip-atomic.rb" < "$f" > "$tmp/$n.py"
  "$root/scripts/mrb" "$root/scripts/strip-atomic.rb" < "$f" > "$tmp/$n.rb"
  if cmp -s "$tmp/$n.py" "$tmp/$n.rb"; then echo "ok   strip-atomic $n"
  else echo "FAIL strip-atomic $n: differs from the oracle"; cmp "$tmp/$n.py" "$tmp/$n.rb" | head -2; fail=1; fi
done
exit $fail

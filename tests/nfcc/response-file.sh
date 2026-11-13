#!/usr/bin/env bash
# scripts/response-file.rb (the Ruby port of nfcc's @file expansion, for bc2cpp) must expand every argument list to the
# same bytes as nfcc's bash code. The bash code is taken from nfcc itself (the lines from its "# Response files" comment to
# the loop that calls add_arg), so the check follows the driver, not a copy. Compared: a corpus of response files
# (whitespace, quotes, backslashes, CRLF, empty files, nesting, unterminated quotes, a trailing backslash, UTF-8, a
# directory, a missing file), the full argument list, and the exit status of a loop (32 levels: an error, both sides).
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# The bash side: die, then the expansion as nfcc has it, then the expanded words, each followed by a NUL byte.
{
  echo 'die() { echo "nfcc: error: $*" >&2; exit 1; }'
  start=$(grep -n '^# Response files (@file)' "$root/nfcc" | cut -d: -f1)
  end=$(grep -n '^for a in "\$@"; do add_arg' "$root/nfcc" | cut -d: -f1)
  [ -n "$start" ] && [ -n "$end" ] || { bad setup "cannot find the expansion in nfcc"; exit 1; }
  sed -n "${start},${end}p" "$root/nfcc"
  echo 'set -- "${expanded[@]+"${expanded[@]}"}"'
  echo 'for w in "$@"; do printf "%s\0" "$w"; done'
} > "$tmp/bash_expand.sh"

# The corpus. Written with quoted heredocs, so the backslashes in the files are the ones the test means.
cd "$tmp"
printf 'a b\tc\n' > ws.rsp
cat > quotes.rsp <<'EOF'
'x y' "p q" 'it\'s' "say \"hi\""
EOF
cat > backslash.rsp <<'EOF'
a\ b \"c\" "d\\e" \\
EOF
printf 'one\r\ntwo\r\n' > crlf.rsp
: > empty.rsp
cat > emptyquotes.rsp <<'EOF'
"" '' x
EOF
printf '@inner.rsp outer\n' > nest1.rsp
printf 'deep\n' > inner.rsp
printf '@loop.rsp\n' > loop.rsp
printf '"unterminated x\n' > unterm.rsp
printf 'tail\\' > tailbs.rsp
printf 'é ü\n' > utf8.rsp
printf '@@x.rsp @nope.rsp\n' > dbl.rsp
mkdir dir.rsp

run_bash() { (cd "$tmp" && bash "$tmp/bash_expand.sh" "$@"); }
run_ruby() { (cd "$tmp" && ruby "$root/scripts/response-file.rb" "$@"); }

for f in ws quotes backslash crlf empty emptyquotes nest1 unterm tailbs utf8 dbl; do
  b=$(run_bash "@$f.rsp" | od -An -c) ; r=$(run_ruby "@$f.rsp" | od -An -c)
  if [ "$b" = "$r" ]; then ok "response file $f"; else bad "response file $f" "bash: $b / ruby: $r"; fi
done

full=(-c x.c @ws.rsp -o @quotes.rsp @backslash.rsp @crlf.rsp @empty.rsp @emptyquotes.rsp @nest1.rsp @unterm.rsp @tailbs.rsp @utf8.rsp @dbl.rsp @nope.rsp @dir.rsp "" @ -x)
if run_bash "${full[@]}" > "$tmp/full_bash.bin" 2>&1 && run_ruby "${full[@]}" > "$tmp/full_ruby.bin" 2>&1 &&
   cmp -s "$tmp/full_bash.bin" "$tmp/full_ruby.bin"; then
  ok "full argument list ($(tr -cd '\0' < "$tmp/full_ruby.bin" | wc -c) words)"
else
  bad "full argument list" "outputs differ"
fi

rb=0; bb=0
run_bash @loop.rsp >/dev/null 2>&1 || bb=$?
run_ruby @loop.rsp >/dev/null 2>&1 || rb=$?
if [ "$bb" != 0 ] && [ "$bb" = "$rb" ]; then ok "loop is refused (status $rb)"; else bad "loop is refused" "bash $bb, ruby $rb"; fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

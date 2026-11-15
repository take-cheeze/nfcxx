#!/usr/bin/env bash
# Tests scripts/nfcxx-cache-gha.rb against tests/gha-cache/mock_results.py, the same mock run.sh uses, and checks it
# against the Python original (tests/gha-cache/oracle-nfcxx-cache-gha.py): each case runs both helpers, and the exit code, stdout and stderr must match.
# The one expected difference is the usage text, which names the .rb file and `ruby` where the Python one names the
# .py file and `python3 -I`; the same() check substitutes those two names and nothing else. Entries also cross between
# the two (a Ruby put read by Python and a Python put read by Ruby). It does not reach GitHub.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
py=$root/tests/gha-cache/oracle-nfcxx-cache-gha.py
rb=$root/scripts/nfcxx-cache-gha.rb
mock=$root/tests/gha-cache/mock_results.py
work=$(mktemp -d); trap 'kill $mock_pid 2>/dev/null || true; rm -rf "$work"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

helper() {  # helper LANG TAG ARGS...: runs the py or rb helper; its exit code, stdout and stderr go to $work/TAG.*
  local lang=$1 tag=$2 rc=0; shift 2
  if [ "$lang" = py ]; then python3 -I "$py" "$@" >"$work/$tag.out" 2>"$work/$tag.err" || rc=$?
  else ruby "$rb" "$@" >"$work/$tag.out" 2>"$work/$tag.err" || rc=$?; fi
  echo "$rc" >"$work/$tag.code"
}
same() {  # same NAME PY_TAG RB_TAG WANT: the two helpers agree on exit code (WANT), stdout and stderr
  local name=$1 p=$2 r=$3 want=$4
  sed -e 's/nfcxx-cache-gha\.py/nfcxx-cache-gha.rb/g' -e 's/run it with `python3 -I`/run it with `ruby`/' \
    "$work/$p.err" >"$work/$p.err.norm"
  if [ "$(cat "$work/$p.code")" = "$want" ] && cmp -s "$work/$p.code" "$work/$r.code" \
     && cmp -s "$work/$p.out" "$work/$r.out" && cmp -s "$work/$p.err.norm" "$work/$r.err"; then
    ok "$name (exit $want)"
  else
    bad "$name: want exit $want; python exit $(cat "$work/$p.code"), ruby exit $(cat "$work/$r.code")"
    echo "     python stderr:"; sed 's/^/       /' "$work/$p.err"
    echo "     ruby stderr:"; sed 's/^/       /' "$work/$r.err"
  fi
}

token=test-token-rb-$$
python3 -I "$mock" "$token" > "$work/url" &
mock_pid=$!
for _ in $(seq 1 100); do [ -s "$work/url" ] && break; sleep 0.05; done
export ACTIONS_RESULTS_URL=$(head -n1 "$work/url") ACTIONS_RUNTIME_TOKEN=$token ACTIONS_CACHE_SERVICE_V2=1

# An entry of three files, the way the driver makes one (obj, ti, ii), plus a file that must not be in the entry.
src=$work/src; mkdir -p "$src"
head -c 300000 /dev/urandom > "$src/obj"
printf 'ti record\n' > "$src/ti"
printf 'ii record\n' > "$src/ii"
printf 'not in the entry\n' > "$src/other"

# 1. get of an absent key: a miss, exit 1, no output, no directory.
key=rb-miss-$$
helper py miss-py get "$key" "$work/miss-py"
helper rb miss-rb get "$key" "$work/miss-rb"
same "get miss" miss-py miss-rb 1
if [ ! -e "$work/miss-py" ] && [ ! -e "$work/miss-rb" ]; then ok "a miss creates no directory"
else bad "a miss created a directory"; fi

# 2. put then get round trip, both directions: Python puts and Ruby gets; Ruby puts and Python gets.
kp=rb-rt-py-$$; kr=rb-rt-rb-$$
helper py rt-put-py put "$kp" "$src" obj ti ii
helper rb rt-put-rb put "$kr" "$src" obj ti ii
same "put stores an entry (python and ruby put to two keys)" rt-put-py rt-put-rb 0
mkdir -p "$work/rt"
helper rb rt-get-rb get "$kp" "$work/rt/from-py"
helper py rt-get-py get "$kr" "$work/rt/from-rb"
if [ "$(cat "$work/rt-get-rb.code")" = 0 ] && [ "$(cat "$work/rt-get-py.code")" = 0 ]; then
  rt_ok=1
  for f in obj ti ii; do
    cmp -s "$src/$f" "$work/rt/from-py/$f" && cmp -s "$src/$f" "$work/rt/from-rb/$f" || rt_ok=0
  done
  [ ! -e "$work/rt/from-py/other" ] && [ ! -e "$work/rt/from-rb/other" ] || rt_ok=0
  if [ "$rt_ok" = 1 ]; then ok "a Python entry gets back through Ruby and a Ruby entry through Python (obj, ti, ii; not other)"
  else bad "an entry did not come back intact across the two helpers"; fi
else bad "a get of the cross-written entries did not exit 0 (ruby $(cat "$work/rt-get-rb.code"), python $(cat "$work/rt-get-py.code"))"; fi

# 3. put of an existing key: stored already, exit 0 from both; the stored entry is not overwritten.
ke=rb-exist-$$
helper py exist-first put "$ke" "$src" obj ti ii
helper py exist-py put "$ke" "$src" obj ti ii
helper rb exist-rb put "$ke" "$src" obj ti ii
same "put of an existing key is accepted (entries are immutable)" exist-py exist-rb 0
mkdir -p "$work/src2"; printf 'changed\n' > "$work/src2/ti"
helper rb exist-changed put "$ke" "$work/src2" ti
if [ "$(cat "$work/exist-changed.code")" = 0 ]; then
  mkdir -p "$work/exist"; helper py exist-get get "$ke" "$work/exist/e"
  if [ "$(cat "$work/exist-get.code")" = 0 ] && cmp -s "$src/ti" "$work/exist/e/ti"; then
    ok "a second put with other contents leaves the stored entry as it was"
  else bad "the second put changed the stored entry"; fi
else bad "a Ruby put of an existing key with other contents exited $(cat "$work/exist-changed.code")"; fi

# 4. bad keys: a slash, empty, too long; and a key ending in one newline, which Python's regex accepts too.
helper py badkey-py get 'a/b' "$work/bk-py"; helper rb badkey-rb get 'a/b' "$work/bk-rb"
same "a key with a slash is refused" badkey-py badkey-rb 2
helper py badkey2-py put '' "$src" obj; helper rb badkey2-rb put '' "$src" obj
same "an empty key is refused" badkey2-py badkey2-rb 2
longkey=$(printf 'k%.0s' $(seq 201))
helper py badkey3-py get "$longkey" "$work/bk3-py"; helper rb badkey3-rb get "$longkey" "$work/bk3-rb"
same "a key of 201 characters is refused" badkey3-py badkey3-rb 2
nlkey=$(printf 'nl-%s\nX' "$$"); nlkey=${nlkey%X}
helper py nlkey-py get "$nlkey" "$work/nl-py"; helper rb nlkey-rb get "$nlkey" "$work/nl-rb"
same "a key ending in one newline is accepted, as Python accepts it (a miss)" nlkey-py nlkey-rb 1

# 5. put without FILE.
helper py nofile-py put "$key" "$src"; helper rb nofile-rb put "$key" "$src"
same "put without FILE" nofile-py nofile-rb 2

# 6. missing or empty service variables.
( unset ACTIONS_RESULTS_URL; helper py noenv-py get "$key" "$work/noenv-py" )
( unset ACTIONS_RESULTS_URL; helper rb noenv-rb get "$key" "$work/noenv-rb" )
same "ACTIONS_RESULTS_URL unset" noenv-py noenv-rb 2
( export ACTIONS_RUNTIME_TOKEN=; helper py notok-py get "$key" "$work/notok-py" )
( export ACTIONS_RUNTIME_TOKEN=; helper rb notok-rb get "$key" "$work/notok-rb" )
same "ACTIONS_RUNTIME_TOKEN empty" notok-py notok-rb 2

# 7. a FILE that is not a file: absent, or a directory.
mkdir -p "$src/subdir"
helper py nofile2-py put "$key" "$src" obj nosuch; helper rb nofile2-rb put "$key" "$src" obj nosuch
same "a FILE that does not exist" nofile2-py nofile2-rb 2
helper py dirfile-py put "$key" "$src" subdir; helper rb dirfile-rb put "$key" "$src" subdir
same "a FILE that is a directory" dirfile-py dirfile-rb 2

# 8. usage: no arguments, or an unknown command.
helper py usage-py; helper rb usage-rb
same "no arguments print the usage" usage-py usage-rb 2
helper py usage2-py bogus x y; helper rb usage2-rb bogus x y
same "an unknown command prints the usage" usage2-py usage2-rb 2

# 9. a wrong token: the service's answer is quoted in the message (Python's bytes repr).
( export ACTIONS_RUNTIME_TOKEN=wrong; helper py wrongtok-py get "$key" "$work/wrongtok-py" )
( export ACTIONS_RUNTIME_TOKEN=wrong; helper rb wrongtok-rb get "$key" "$work/wrongtok-rb" )
same "a wrong token is an error, with the service's answer quoted" wrongtok-py wrongtok-rb 2

# 10. unpack refuses a member that leaves the directory (run.sh checks the same for Python).
python3 -I - "$work" <<'EOF'
import io, sys, tarfile
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as t:
    d = tarfile.TarInfo("../escape"); d.size = 2; t.addfile(d, io.BytesIO(b"x\n"))
open(sys.argv[1] + "/evil.tar", "wb").write(buf.getvalue())
EOF
evil=$(ruby -e 'require ARGV[0]
begin
  NfcxxCacheGha.unpack(File.binread(ARGV[1]), ARGV[2]); puts "extracted"
rescue NfcxxCacheGha::CacheError
  puts "refused"
end' "$rb" "$work/evil.tar" "$work/evil-dest")
if [ "$evil" = refused ] && [ ! -e "$work/escape" ] && [ ! -e "$work/evil-dest/../escape" ]; then
  ok "an entry with a path outside its directory is refused (ruby)"
else bad "an entry with a path outside its directory: $evil (ruby)"; fi

# 11. unpack refuses a non-regular member. Python would extract this symlink (the data filter allows a link inside the
# directory), so this is a deliberate difference: the Ruby reader takes regular files only.
python3 -I - "$work" <<'EOF'
import io, sys, tarfile
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as t:
    d = tarfile.TarInfo("lnk"); d.type = tarfile.SYMTYPE; d.linkname = "obj"; t.addfile(d)
open(sys.argv[1] + "/link.tar", "wb").write(buf.getvalue())
EOF
linked=$(ruby -e 'require ARGV[0]
begin
  NfcxxCacheGha.unpack(File.binread(ARGV[1]), ARGV[2]); puts "extracted"
rescue NfcxxCacheGha::CacheError => e
  puts e.message
end' "$rb" "$work/link.tar" "$work/link-dest")
if [ "$linked" = "unexpected entry 'lnk'" ]; then ok "a symlink member is refused (ruby reader takes regular files only)"
else bad "a symlink member: $linked"; fi

# 12. The driver's remote tier: the two functions from nfcxx, which call the Ruby helper.
funcs=$work/remote-funcs.sh
sed -n '/^cache_remote_get() {/,/^}/p; /^cache_remote_put() {/,/^}/p' "$root/nfcxx" \
  > "$funcs"
if ! grep -q '"\${RUBY:-ruby}" "\$root/scripts/nfcxx-cache-gha.rb"' "$funcs"; then
  bad "the driver functions do not call the Ruby helper (substitution did not apply)"
fi
drv=0
(
  set -eu
  root=$root; . "$funcs"
  local_entry=$work/driver/objects/k1; mkdir -p "$local_entry"
  cp "$src/obj" "$src/ti" "$src/ii" "$local_entry/"
  cache_remote_put rb-drv1-$$ "$local_entry"
  if cache_remote_get rb-drv1-$$ "$work/driver2/objects/drv1"; then
    cmp "$src/obj" "$work/driver2/objects/drv1/obj" && cmp "$src/ii" "$work/driver2/objects/drv1/ii"
    echo "driver functions: a stored entry comes back"
  else echo "driver functions: the stored entry did not come back"; exit 1; fi
  if cache_remote_get rb-drv-absent-$$ "$work/driver2/objects/none"; then echo "driver functions: a miss reported as a hit"; exit 1; fi
  [ ! -e "$work/driver2/objects/none" ] || { echo "driver functions: a miss left a directory"; exit 1; }
  echo "driver functions: a miss is a failure with no entry"
) > "$work/driver.out" 2>&1 || drv=$?
cat "$work/driver.out"
if [ "$drv" = 0 ]; then pass=$((pass + 3)); else fail=$((fail + 1)); fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

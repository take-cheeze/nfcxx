#!/bin/bash
# scripts/nfcxx-cache-io.rb must do what the bash helpers of nfcxx do: cache_sha, cache_log, cache_remote_get and
# cache_remote_put (taken from nfcxx itself). The remote tier needs the GitHub cache, which this machine does not have,
# so the remote cases run the failing path: a get is a miss (status 1), a put prints the build-continues note.
#   bash tests/nfcxx-cache-io/run.sh
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# the bash helpers, as nfcxx defines them
{
  echo "root=$repo"
  sed -n '/^cache_sha()/p' "$repo/nfcxx"
  sed -n '/^cache_log() {/,/^}/p' "$repo/nfcxx"
  sed -n '/^cache_remote_get() {/,/^}/p' "$repo/nfcxx"
  sed -n '/^cache_remote_put() {/,/^}/p' "$repo/nfcxx"
} > "$work/bash-cache.sh"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "pass $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

printf 'some input\n' | (source "$work/bash-cache.sh"; cache_sha) > "$work/b.sha"
printf 'some input\n' | ruby "$repo/scripts/nfcxx-cache-io.rb" sha > "$work/r.sha"
cmp -s "$work/b.sha" "$work/r.sha" && ok "sha" || bad "sha"

(source "$work/bash-cache.sh"; cache_log_file="$work/b.log"; cache_log one two; cache_log three)
ruby "$repo/scripts/nfcxx-cache-io.rb" log "$work/r.log" one two
ruby "$repo/scripts/nfcxx-cache-io.rb" log "$work/r.log" three
cmp -s "$work/b.log" "$work/r.log" && ok "log" || bad "log"

(source "$work/bash-cache.sh"; cache_remote_get KEYX "$work/be"; echo "status $?") > "$work/b.get" 2>/dev/null
ruby "$repo/scripts/nfcxx-cache-io.rb" remote-get KEYX "$work/re" 2>/dev/null; echo "status $?" > "$work/r.get"
b=$(tail -1 "$work/b.get"); r=$(tail -1 "$work/r.get")
[ "$b" = "$r" ] && ok "remote-get miss ($r)" || bad "remote-get: bash [$b] ruby [$r]"

(source "$work/bash-cache.sh"; cache_remote_put KEYX "$work/be" 2> "$work/b.put")
ruby "$repo/scripts/nfcxx-cache-io.rb" remote-put KEYX "$work/re" 2> "$work/r.put"
sed -e "s|$work/be|E|g" "$work/b.put" > "$work/b.put2"; sed -e "s|$work/re|E|g" "$work/r.put" > "$work/r.put2"
cmp -s "$work/b.put2" "$work/r.put2" && ok "remote-put note" || { bad "remote-put"; cat "$work/b.put2" "$work/r.put2"; }
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]

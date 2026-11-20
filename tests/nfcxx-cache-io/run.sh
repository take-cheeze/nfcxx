#!/bin/bash
# nfcxx's cache_log, cache_remote_get and cache_remote_put are calls of scripts/nfcxx-cache-io.rb now. The reference is the
# bash they were (tests/nfcxx-cache-io/bash-oracle.sh, frozen). Each case runs the reference and the current nfcxx functions
# from the same starting state, each in its own directory, against a stand-in GHA client (fake-gha.rb, which answers as
# FAKE_GHA says). Both must exit with the case's status, print the same stdout and stderr, and leave the same files.
# cache_sha stays bash (the key is computed in bash); its check is the sha of nfcxx against scripts/nfcxx-cache-io.rb sha.
#   bash tests/nfcxx-cache-io/run.sh
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# A sandbox with the Ruby helper and the stand-in client where the real one would be: the Ruby helper finds its client
# beside itself, and the reference calls $root/scripts/nfcxx-cache-gha.rb.
sb=$work/sb
mkdir -p "$sb/scripts"
cp "$repo/scripts/nfcxx-cache-io.rb" "$sb/scripts/"
cp "$here/fake-gha.rb" "$sb/scripts/nfcxx-cache-gha.rb"

# The current functions, as nfcxx defines them.
sed -n '/^cache_log() {/,/^}/p; /^cache_remote_get() {/,/^}/p; /^cache_remote_put() {/,/^}/p' "$repo/tests/driver-body/nfcxx-bash" > "$work/new-funcs.sh"
grep -q 'nfcxx-cache-io.rb" log' "$work/new-funcs.sh" && grep -q 'nfcxx-cache-io.rb" remote-get' "$work/new-funcs.sh" \
  && grep -q 'nfcxx-cache-io.rb" remote-put' "$work/new-funcs.sh" \
  || { echo "FAIL the functions of nfcxx do not call scripts/nfcxx-cache-io.rb"; exit 1; }

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

norm() {  # the directories of the two runs, and the temporary names of a remote get (its pid), made the same
  sed -e "s#$work/case/old#DIR#g" -e "s#$work/case/new#DIR#g" -e 's/\.remote\.[0-9][0-9]*/.remote.PID/g'
}

case_run() {  # case_run NAME MODE WANT PREP BODY: PREP makes the starting files, then BODY runs with the reference (old)
  # and with nfcxx's functions (new), in directories of their own; the status must be WANT for both, and the output and the files the same
  local name=$1 mode=$2 want=$3 prep=$4 body=$5 impl funcs dir
  for impl in old new; do
    case $impl in old) funcs=$here/bash-oracle.sh ;; new) funcs=$work/new-funcs.sh ;; esac
    dir=$work/case/$impl; rm -rf "$dir"; mkdir -p "$dir"
    (cd "$dir" && eval "$prep")
    (cd "$dir" && env RUBY=ruby root="$sb" FAKE_GHA="$mode" FAKE_GHA_LOG=gha.log bash -c "source '$funcs'; $body") \
      > "$work/$impl.out" 2> "$work/$impl.err"
    echo $? > "$work/$impl.rc"
  done
  local ok_case=1
  [ "$(cat "$work/old.rc")" = "$want" ] && [ "$(cat "$work/new.rc")" = "$want" ] \
    || { ok_case=0; echo "     status: reference $(cat "$work/old.rc"), new $(cat "$work/new.rc"), wanted $want"; }
  norm < "$work/old.out" > "$work/old.out.n"; norm < "$work/new.out" > "$work/new.out.n"
  norm < "$work/old.err" > "$work/old.err.n"; norm < "$work/new.err" > "$work/new.err.n"
  diff -u "$work/old.out.n" "$work/new.out.n" > "$work/out.diff" || { ok_case=0; echo "     stdout differs:"; sed 's/^/       /' "$work/out.diff"; }
  diff -u "$work/old.err.n" "$work/new.err.n" > "$work/err.diff" || { ok_case=0; echo "     stderr differs:"; sed 's/^/       /' "$work/err.diff"; }
  diff -r "$work/case/old" "$work/case/new" > "$work/tree.diff" || { ok_case=0; echo "     files differ:"; sed 's/^/       /' "$work/tree.diff"; }
  if [ "$ok_case" = 1 ]; then ok "$name (status $want)"; else bad "$name"; fi
}

# The records of an entry the build left: obj, ti and ii (the local entry the remote put stores).
entry3='mkdir -p objects/k1; echo O > objects/k1/obj; echo T > objects/k1/ti; echo I > objects/k1/ii'

# cache_remote_get: a hit fills the entry (the fake client's obj, ti and ii); a miss or an error is status 1 with no entry
case_run "get: a hit fills the entry" hit 0 '' 'cache_remote_get K1 objects/k1'
case_run "get: a miss is status 1 and no entry" miss 1 '' 'cache_remote_get K1 objects/k1'
case_run "get: an error is status 1, and the client's output goes through" error 1 '' 'cache_remote_get K1 objects/k1'
case_run "get: a hit leaves an entry that is already there" hit 0 'mkdir -p objects/k1; echo OLD > objects/k1/obj' 'cache_remote_get K1 objects/k1'
case_run "get: a hit makes the parent directories" hit 0 '' 'cache_remote_get K2 objects/a/b/k2'
case_run "get: a miss makes no directory" miss 1 '' 'cache_remote_get K3 objects/a/k3'

# cache_remote_put: the object and the records that exist go up; a failed store is a note on stderr and status 0
case_run "put: obj, ti and ii go up" put-ok 0 "$entry3" 'cache_remote_put K1 objects/k1'
case_run "put: only obj when there are no records" put-ok 0 'mkdir -p objects/k1; echo O > objects/k1/obj' 'cache_remote_put K1 objects/k1'
case_run "put: a failed store is a note and status 0" put-fail 0 "$entry3" 'cache_remote_put K1 objects/k1'

# cache_log: one line per call (joined as "$*"); no file set, nothing written
case_run "log: calls append one line each, joined as one argument" miss 0 '' \
  'cache_log_file=$PWD/cache.log; cache_log one two; cache_log "x  y"; cache_log ""; cache_log "$(printf "a\nb")"'
case_run "log: an existing file is appended to" miss 0 'echo before > cache.log' 'cache_log_file=$PWD/cache.log; cache_log after'
case_run "log: text that looks like an option" miss 0 '' 'cache_log_file=$PWD/cache.log; cache_log -n -e x'
case_run "log: no file set writes nothing" miss 0 '' 'cache_log_file=; cache_log nothing'

# sha: nfcxx's cache_sha (bash, unchanged) and the Ruby helper's sha agree on the same input
sed -n '/^cache_sha()/p' "$repo/tests/driver-body/nfcxx-bash" > "$work/sha.sh"
printf 'some input\n' | (. "$work/sha.sh"; cache_sha) > "$work/b.sha"
printf 'some input\n' | ruby "$repo/scripts/nfcxx-cache-io.rb" sha > "$work/r.sha"
cmp -s "$work/b.sha" "$work/r.sha" && ok "sha (bash and ruby agree)" || bad "sha"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

#!/usr/bin/env bash
# Tests scripts/nfcxx-cache-gha.py against tests/gha-cache/mock_results.py (a mock of the Actions cache service).
# This checks the client's requests and its handling of the service's answers. It does not reach GitHub.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
helper=$root/scripts/nfcxx-cache-gha.py
mock=$root/tests/gha-cache/mock_results.py
work=$(mktemp -d); trap 'kill $mock_pid 2>/dev/null || true; rm -rf "$work"' EXIT
pass=0; fail=0
check() {  # check NAME CMD...: runs CMD, prints ok or FAIL
  name=$1; shift
  if "$@" >"$work/out" 2>&1; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name"; sed 's/^/     /' "$work/out"; fi
}
expect_code() {  # expect_code NAME WANT CMD...: the exit status must be WANT
  name=$1; want=$2; shift 2
  set +e; "$@" >"$work/out" 2>&1; got=$?; set -e
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); echo "ok   $name (exit $got)"
  else fail=$((fail + 1)); echo "FAIL $name: exit $got, wanted $want"; sed 's/^/     /' "$work/out"; fi
}

token=test-token-$$
python3 -I "$mock" "$token" > "$work/url" &
mock_pid=$!
for _ in $(seq 1 100); do [ -s "$work/url" ] && break; sleep 0.05; done
export ACTIONS_RESULTS_URL=$(head -n1 "$work/url") ACTIONS_RUNTIME_TOKEN=$token ACTIONS_CACHE_SERVICE_V2=1
h() { python3 -I "$helper" "$@"; }

# An entry of three files, the way the driver makes one (obj, ti, ii), plus a file that must not be in the entry.
src=$work/src; mkdir -p "$src"
head -c 300000 /dev/urandom > "$src/obj"
printf 'ti record\n' > "$src/ti"
printf 'ii record\n' > "$src/ii"
printf 'not in the entry\n' > "$src/other"

check "put stores the entry" h put 0123abcd "$src" obj ti ii
mkdir "$work/got"
check "get returns the entry" h get 0123abcd "$work/got/e"
check "get: obj matches" cmp "$src/obj" "$work/got/e/obj"
check "get: ti matches" cmp "$src/ti" "$work/got/e/ti"
check "get: ii matches" cmp "$src/ii" "$work/got/e/ii"
test ! -e "$work/got/e/other" && { pass=$((pass + 1)); echo "ok   get: only the named files are stored"; } \
  || { fail=$((fail + 1)); echo "FAIL get: an unnamed file was stored"; }

expect_code "get of an absent key is a miss" 1 h get ffffffff "$work/got/none"
check "a second put of the same key is accepted (entries are immutable)" h put 0123abcd "$src" obj ti ii
printf 'changed\n' > "$src/ti"
check "the second put did not overwrite the entry" sh -c "python3 -I '$helper' get 0123abcd '$work/got/again' && cmp '$work/got/again/ti' '$work/got/e/ti'"
printf 'ti record\n' > "$src/ti"

expect_code "a wrong token is an error, not a miss" 2 env ACTIONS_RUNTIME_TOKEN=wrong python3 -I "$helper" get 0123abcd "$work/got/x"
expect_code "no service in the environment is an error" 2 env -u ACTIONS_RESULTS_URL python3 -I "$helper" get 0123abcd "$work/got/y"
expect_code "a key with a slash is refused" 2 h get "a/b" "$work/got/z"
expect_code "put of a missing file is an error" 2 h put 55555555 "$src" obj nosuch

# A tar whose member escapes the directory must not be extracted: _unpack refuses it (the mock serves it through get).
python3 -I - "$work" <<'EOF'
import io, sys, tarfile
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as t:
    d = tarfile.TarInfo("../escape"); d.size = 2; t.addfile(d, io.BytesIO(b"x\n"))
open(sys.argv[1] + "/evil.tar", "wb").write(buf.getvalue())
EOF
evil=$(python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("h", sys.argv[1]); h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
try:
    h._unpack(open(sys.argv[2], "rb").read(), sys.argv[3]); print("extracted")
except Exception as e:
    print("refused")
' "$helper" "$work/evil.tar" "$work/evil-dest")
if [ "$evil" = refused ] && [ ! -e "$work/escape" ] && [ ! -e "$work/evil-dest/../escape" ]; then
  pass=$((pass + 1)); echo "ok   an entry with a path outside its directory is refused"
else fail=$((fail + 1)); echo "FAIL an entry with a path outside its directory: $evil"; fi

# The driver's remote tier: its two functions, taken from nfcxx itself (they use $root and the helper).
funcs=$work/remote-funcs.sh
sed -n '/^cache_remote_get() {/,/^}/p; /^cache_remote_put() {/,/^}/p' "$root/nfcxx" > "$funcs"
(
  set -eu
  root=$root; . "$funcs"
  local_entry=$work/driver/objects/k1; mkdir -p "$local_entry"
  cp "$src/obj" "$src/ti" "$src/ii" "$local_entry/"
  cache_remote_put drv1 "$local_entry"                       # a store: obj, ti and ii go up
  if cache_remote_get drv1 "$work/driver2/objects/drv1"; then
    cmp "$src/obj" "$work/driver2/objects/drv1/obj" && cmp "$src/ii" "$work/driver2/objects/drv1/ii"
    echo "driver functions: a stored entry comes back"
  else echo "driver functions: the stored entry did not come back"; exit 1; fi
  if cache_remote_get drv-absent "$work/driver2/objects/none"; then echo "driver functions: a miss reported as a hit"; exit 1; fi
  [ ! -e "$work/driver2/objects/none" ] || { echo "driver functions: a miss left a directory"; exit 1; }
  echo "driver functions: a miss is a failure with no entry"
) > "$work/driver.out" 2>&1 && drv=0 || drv=$?
cat "$work/driver.out"
if [ "$drv" = 0 ]; then pass=$((pass + 3)); else fail=$((fail + 1)); fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

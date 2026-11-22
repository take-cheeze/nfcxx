#!/usr/bin/env bash
# Goldens of nfcxx's compile cache hit and store (the handoff of docs/notes/driver-body-port.md, B5): the cache's decisions as
# the driver makes them end to end. Each case runs ./nfcxx in a sandbox of its own, against a copy of the tree under test and
# a fake EDG build (bin/eccp writes the object named by -o, and the .ti and .ii beside it). Recorded per case: each run's
# command, environment, status, stdout and stderr, then the sandbox after the runs (every name, and each file's text).
# Normalized: the sandbox's and the tree's paths (WORK), a cache key (40 hex digits: KEY), the sha256 lines of the body and
# scripts/ in the key inputs of the cache log (SRCSHA: they change whenever a source changes; the lines after them are not normalized), and the pids of temporary names (PID).
# The remote tier runs the fake GHA client of tests/nfcxx-cache-io/fake-gha.rb, put in the copy of the tree for the remote cases.
#   tests/driver-cache-handoff/run.sh            compares each case with tests/driver-cache-handoff/golden/
#   tests/driver-cache-handoff/run.sh --record   writes the goldens (record them from the tree the goldens are taken from only)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
mode=${1:-}
golden=$here/golden
fixtures=$repo/tests/nfcxx-cache/fixtures
ruby_bin=$(command -v "${RUBY:-ruby}")
work=$(realpath "$(mktemp -d)")
trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# the tree under test: a copy without .git (the driver's own files, with the build of its tools)
tree=$work/tree
mkdir -p "$tree"
tar --exclude=.git -C "$repo" -cf - . | tar -C "$tree" -xf -
gha_real=$work/gha-real.rb
cp "$tree/scripts/nfcxx-cache-gha.rb" "$gha_real"
use_fake_gha() { cp "$repo/tests/nfcxx-cache-io/fake-gha.rb" "$tree/scripts/nfcxx-cache-gha.rb"; }
restore_gha() { cp "$gha_real" "$tree/scripts/nfcxx-cache-gha.rb"; }

# the fake EDG build: bin/eccp writes the object named by -o, and the records beside a .o object (as eccp writes them for -c)
edg=$work/edg
mkdir -p "$edg/bin"
cat > "$edg/bin/eccp" <<'EOF'
#!/bin/sh
out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
[ -n "$out" ] || exit 0
printf 'OBJECT %s\n' "$out" > "$out"
case $out in *.o) stem=${out%.o}; printf 'RECORD ti\n' > "$stem.ti"; printf 'RECORD ii\n' > "$stem.ii" ;; esac
exit 0
EOF
chmod +x "$edg/bin/eccp"

norm() {  # the normalization of the header comment
  sed -E -e "s#$work#WORK#g" -e 's/\b[0-9a-f]{40}\b/KEY/g' -e 's/\.(tmp|remote)\.[0-9]+/.\1.PID/g' |
  awk '/^\| nfcxx-cache-1$/ { n = 0 }   # the first two sha lines of a key input block are the body and scripts/ (SRCSHA)
       /^\| [0-9a-f]+  -$/ && n < 2 { n++; print "| SRCSHA  -"; next }
       { print }'
}

# the case state: sb (the sandbox), tr (the raw transcript), ENVS (the environment of the next run), runs
case_begin() {  # case_begin NAME: a fresh sandbox with the fixtures, an empty transcript, the real GHA client
  CASE=$1; sb=$work/sb; rm -rf "$sb"; mkdir -p "$sb"; cp "$fixtures"/* "$sb"/
  tr=$work/$CASE.tr; : > "$tr"; runs=0; ENVS=(); restore_gha
}
run_nfcxx() {  # run_nfcxx ARG...: one run of ./nfcxx in the sandbox, with ENVS; the status, stdout and stderr go to the transcript
  local rc
  (cd "$sb" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" RUBY="$ruby_bin" EDG_BUILD="$edg" \
     ${ENVS[@]+"${ENVS[@]}"} "$tree/nfcxx" "$@") > "$work/out" 2> "$work/err"; rc=$?
  runs=$((runs + 1))
  { echo "== run $runs: nfcxx $*"; echo "env: ${ENVS[*]:-}"; echo "rc: $rc"; echo "-- stdout"; cat "$work/out"
    echo "-- stderr"; cat "$work/err"; } >> "$tr"
}
note() { echo "($*)" >> "$tr"; }
snapshot() {  # the sandbox after the runs: each name, and the text of each file
  echo "== sandbox" >> "$tr"
  (cd "$sb" && find . -mindepth 1 | LC_ALL=C sort) | while IFS= read -r p; do
    p=${p#./}
    if [ -d "$sb/$p" ]; then echo "D $p" >> "$tr"
    else echo "F $p" >> "$tr"; sed 's/^/| /' "$sb/$p" >> "$tr"; fi
  done
}
case_end() {  # case_end: the normalized transcript is recorded, or compared with its golden
  snapshot
  norm < "$tr" > "$work/$CASE.norm"
  if [ "$mode" = --record ]; then cp "$work/$CASE.norm" "$golden/$CASE.txt"; echo "recorded $CASE"; return; fi
  if cmp -s "$work/$CASE.norm" "$golden/$CASE.txt" 2>/dev/null; then
    pass=$((pass + 1)); echo "ok    $CASE"
  else
    fail=$((fail + 1)); echo "FAIL  $CASE"; diff -u "$golden/$CASE.txt" "$work/$CASE.norm" 2>/dev/null | sed 's/^/      /' | head -40
  fi
}

mkdir -p "$golden"

case_begin miss-store   # a miss builds and stores; no remote
ENVS=("NFCXX_CACHE=$sb/cache")
run_nfcxx --backend=gcc -c main.cpp -o main.o
case_end

case_begin hit-twice    # the second run is a hit: the entry is copied back (object, .ti and .ii)
ENVS=("NFCXX_CACHE=$sb/cache")
run_nfcxx --backend=gcc -c main.cpp -o main.o
rm -f "$sb/main.o"; note "main.o removed between the runs"
run_nfcxx --backend=gcc -c main.cpp -o main.o
case_end

case_begin hit-cache-log   # NFCXX_CACHE_LOG: the miss and the hit each append their key inputs, key and decision
ENVS=("NFCXX_CACHE=$sb/cache" "NFCXX_CACHE_LOG=$sb/cache.log")
run_nfcxx --backend=gcc -c main.cpp -o main.o
rm -f "$sb/main.o"; note "main.o removed between the runs"
run_nfcxx --backend=gcc -c main.cpp -o main.o
case_end

case_begin cache-log-flag   # --cache-log= and --cache= on the command line (the argv is part of the key)
ENVS=()
run_nfcxx --backend=gcc "--cache-log=$sb/cache.log" "--cache=$sb/cache" -c main.cpp -o main.o
rm -f "$sb/main.o"; note "main.o removed between the runs"
run_nfcxx --backend=gcc "--cache-log=$sb/cache.log" "--cache=$sb/cache" -c main.cpp -o main.o
case_end

case_begin remote-hit   # a local miss: the remote get fills the entry, and the hit copies it back; the next run is a local hit
use_fake_gha
ENVS=("NFCXX_CACHE=$sb/cache" "NFCXX_CACHE_REMOTE=gha" "FAKE_GHA=hit" "FAKE_GHA_LOG=$sb/gha.log")
run_nfcxx --backend=gcc -c main.cpp -o main.o
rm -f "$sb/main.o"; note "main.o removed between the runs"
run_nfcxx --backend=gcc -c main.cpp -o main.o
case_end

case_begin remote-miss-store   # a miss in both tiers builds, stores locally and puts the entry remotely
use_fake_gha
ENVS=("NFCXX_CACHE=$sb/cache" "NFCXX_CACHE_REMOTE=gha" "FAKE_GHA=put-ok" "FAKE_GHA_LOG=$sb/gha.log")
run_nfcxx --backend=gcc -c main.cpp -o main.o
case_end

case_begin remote-put-fail   # a failed remote put is a note on stderr; the build goes on with status 0
use_fake_gha
ENVS=("NFCXX_CACHE=$sb/cache" "NFCXX_CACHE_REMOTE=gha" "FAKE_GHA=put-fail" "FAKE_GHA_LOG=$sb/gha.log")
run_nfcxx --backend=gcc -c main.cpp -o main.o
case_end

case_begin remote-get-error   # a failed remote get is a miss: the client's output goes through, the build stores and puts
use_fake_gha
ENVS=("NFCXX_CACHE=$sb/cache" "NFCXX_CACHE_REMOTE=gha" "FAKE_GHA=error" "FAKE_GHA_LOG=$sb/gha.log")
run_nfcxx --backend=gcc -c main.cpp -o main.o
case_end

case_begin non-cached-E   # -E is not cached: no entry, no store, the preprocessed text on stdout
ENVS=("NFCXX_CACHE=$sb/cache")
run_nfcxx --backend=gcc -E main.cpp
case_end

case_begin no-cache   # no cache directory: the compile builds, and nothing is stored
ENVS=()
run_nfcxx --backend=gcc -c main.cpp -o main.o
case_end

case_begin headers-failed   # the host preprocessor cannot list the headers: no key, so no entry and no store
ENVS=("NFCXX_CACHE=$sb/cache")
run_nfcxx --backend=gcc -c main_bad.cpp -o main_bad.o
case_end

restore_gha
if [ "$mode" = --record ]; then echo "recorded into $golden"; exit 0; fi
echo "driver-cache-handoff: $pass passed, $fail failed"
[ "$fail" = 0 ]

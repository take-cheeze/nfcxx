#!/usr/bin/env bash
# Goldens of the eccp call (docs/notes/driver-body-port.md, item 7): the driver's run of the planned eccp command, end to end.
# Each case runs ./nfcxx in a sandbox of its own, against a copy of the tree under test and a fake EDG build. The fake eccp
# (bin/eccp) logs each argument, its working directory and the EDG_/NFCXX_ variables it was given to standard error ("eccp: ..."),
# writes the object named by -o (and the records beside a .o, as eccp does for -c), and exits 1 when FAKE_EDG_FAIL=1.
# Recorded per case, for each run: the command, the environment set for it, the status, the standard output, the driver's own
# standard error lines (^nfcxx: and ^eccp:), then the sandbox after the runs (every name, and the text of each small file),
# the spans of a --trace file (name, category, phase, in order) and the stages of a --time-log file (seconds dropped), and the
# names left in the temporary root.
# Normalized: the sandbox, the tree and the temporary root (WORK, SB, TREE, TMPENTRY), a cache key (KEY), the process ids (PID).
# Also normalized, and only these nondeterministic fields: the trace timestamps, durations and process ids in a --trace file
# (ts, dur, pid in its JSON lines: TS, DUR, PID), the seconds column of a --time-log file (SEC), and the random names mkdtemp
# and the driver give temporary entries (tmp.XXXXXXXXXX: tmp.RAND; nfcxx-tmp.DATE-PID-RAND). Nothing functional is normalized.
#   tests/driver-eccp-call/goldens.sh            compares each case with tests/driver-eccp-call/golden/
#   tests/driver-eccp-call/goldens.sh --record   writes the goldens (record them from the tree the goldens are taken from only)
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
mkdir -p "$work/tmp"

# the tool the driver builds on first use (cuda-rewrite) is built in the repository first, so the tree copy has it
ruby "$repo/scripts/nfcxx-ensure-tool.rb" "$repo/tools/cuda-rewrite" "$repo/build/cuda-rewrite" >/dev/null 2>&1 || true
tree=$work/tree
mkdir -p "$tree"
tar --exclude=.git -C "$repo" -cf - . | tar -C "$tree" -xf -

# the fake EDG build
edg=$work/edg
mkdir -p "$edg/bin"
cat > "$edg/bin/eccp" <<'EOF2'
#!/bin/sh
echo "eccp: status-env FAKE_EDG_FAIL=${FAKE_EDG_FAIL-unset}" >&2
for a in "$@"; do echo "eccp: arg $a" >&2; done
echo "eccp: cwd $(pwd -P)" >&2
env | grep -E '^(EDG_|NFCXX_|FAKE_)' | sort | sed 's/^/eccp: env /' >&2
out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
if [ "${FAKE_EDG_FAIL-}" = 1 ]; then echo "eccp: failed (fake)" >&2; exit 1; fi
[ -n "$out" ] || exit 0
printf 'OBJECT %s\n' "$out" > "$out"
case $out in *.o) stem=${out%.o}; printf 'RECORD ti\n' > "$stem.ti"; printf 'RECORD ii\n' > "$stem.ii" ;; esac
exit 0
EOF2
chmod +x "$edg/bin/eccp"

norm() {  # the normalization of the transcript
  sed -E -e "s|$work/tmp/[^ /\"]*|TMPENTRY|g" -e "s|$sb|SB|g" -e "s|$tree|TREE|g" -e "s|$work|WORK|g" \
         -e 's/\b[0-9a-f]{40}\b/KEY/g' -e 's/\.(tmp|remote)\.[0-9]+/.\1.PID/g' -e 's/\bpid [0-9]+/pid PID/g' -e 's/NFCXX_TRACE_OWNER=[0-9]+/NFCXX_TRACE_OWNER=PID/g' -e 's/trace-pending\.[0-9]+/trace-pending.PID/g' \
         -e 's/\btmp\.[A-Za-z0-9]{10}\b/tmp.RAND/g' -e 's/(^|[^-A-Za-z0-9])tmp\.[0-9]{8}-[0-9]+-[A-Za-z0-9]+\b/\1tmp.RAND/g' -e 's/\bnfcxx-tmp\.[0-9]{8}-[0-9]+-[A-Za-z0-9]+/nfcxx-tmp.DATE-PID-RAND/g' \
         -e 's/"ts":[0-9]+/"ts":TS/g' -e 's/"dur":[0-9]+/"dur":DUR/g' -e 's/"pid":[0-9]+/"pid":PID/g' \
         -e 's/^(\| )[0-9]+\.[0-9]+\t/\1SEC\t/'
}

case_begin() {  # case_begin NAME: a fresh sandbox with the fixtures and the directories the cases use, an empty transcript
  CASE=$1; sb=$work/sb; rm -rf "$sb" "$work/tmp"; mkdir -p "$sb" "$work/tmp"; cp "$fixtures"/* "$sb"/
  mkdir -p "$sb/obj" "$sb/inc"; printf 'int inc_val = 1;\n' > "$sb/inc/x.h"
  printf '__global__ void k() {}\nint main() { return 0; }\n' > "$sb/kernel.cu"
  tr=$work/$CASE.tr; : > "$tr"; runs=0; ENVS=()
}
run_nfcxx() {  # run_nfcxx ARG...: one run of ./nfcxx in the sandbox, with ENVS; the transcript gets its status and output
  local rc
  (cd "$sb" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$work/tmp" RUBY="$ruby_bin" EDG_BUILD="$edg" \
     ${ENVS[@]+"${ENVS[@]}"} "$tree/nfcxx" "$@") > "$work/out" 2> "$work/err"; rc=$?
  runs=$((runs + 1))
  { echo "== run $runs: nfcxx $*"; echo "env: ${ENVS[*]:-}"; echo "rc: $rc"; echo "-- stdout"; cat "$work/out"
    echo "-- stderr (nfcxx: and eccp: lines)"; grep -E '^(nfcxx|eccp):' "$work/err"
    echo "-- other stderr lines: $(grep -c -vE '^(nfcxx|eccp):' "$work/err")"; } >> "$tr"
}
note() { echo "($*)" >> "$tr"; }
snapshot() {  # the sandbox after the runs, the trace and time log, and the temporary root
  echo "== sandbox" >> "$tr"
  (cd "$sb" && find . -mindepth 1 | LC_ALL=C sort) | while IFS= read -r p; do
    p=${p#./}
    if [ -d "$sb/$p" ]; then echo "D $p" >> "$tr"
    else echo "F $p" >> "$tr"; if [ "$(wc -c < "$sb/$p")" -lt 300 ]; then sed 's/^/| /' "$sb/$p" >> "$tr"; fi; fi
  done
  if [ -f "$sb/t.json" ]; then
    echo "== trace spans" >> "$tr"
    "$ruby_bin" -rjson -e 'begin; a = JSON.parse(File.read(ARGV[0])); rescue StandardError; puts "unparsable"; exit; end
      a.each { |e| puts [e["name"], e["cat"], e["ph"]].inspect }' "$sb/t.json" >> "$tr"
  fi
  if [ -f "$sb/time.log" ]; then
    echo "== time log" >> "$tr"; awk -F'\t' '{ print "S", $2, $3, $4 }' "$sb/time.log" >> "$tr"
  fi
  echo "== temporary root" >> "$tr"
  (cd "$work/tmp" && find . -mindepth 1 | LC_ALL=C sort) | sed 's/^/T /' >> "$tr"
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

case_begin plain-c-o   # -c with -o: one eccp call in a temporary directory, the object is moved into place
run_nfcxx --backend=gcc -c main.cpp -o main.o
case_end

case_begin c-no-o      # -c without -o: the object is main.o
run_nfcxx --backend=gcc -c main.cpp
case_end

case_begin link-source # a compile and link in one call
run_nfcxx --backend=gcc main.cpp -o prog
case_end

case_begin link-objects # a link of an object made by a -c compile
run_nfcxx --backend=gcc -c main.cpp -o main.o
run_nfcxx --backend=gcc main.o -o prog
case_end

case_begin c-o-subdir  # -c with -o into a directory
run_nfcxx --backend=gcc -c main.cpp -o obj/main.o
case_end

case_begin cache-miss-hit # the compile cache: a miss runs eccp and stores; the second run is a hit and does not
ENVS=("NFCXX_CACHE=$sb/cache")
run_nfcxx --backend=gcc -c main.cpp -o main.o
rm -f "$sb/main.o"; note "main.o removed between the runs"
run_nfcxx --backend=gcc -c main.cpp -o main.o
case_end

case_begin preprocess  # -E: no eccp call
run_nfcxx --backend=gcc -E main.cpp
case_end

case_begin keep-intermediates # --keep-intermediates: the temporary directory is kept and named on stderr
run_nfcxx --backend=gcc --keep-intermediates -c main.cpp -o main.o
case_end

case_begin failing-compile # eccp exits 1: the driver ends with its status and stores nothing to the cache
ENVS=("FAKE_EDG_FAIL=1" "NFCXX_CACHE=$sb/cache")
run_nfcxx --backend=gcc -c main.cpp -o main.o
ls "$sb/cache" >/dev/null 2>&1 && note "cache directory exists" || note "no cache entry"
case_end

case_begin failing-link # eccp exits 1 on a link
ENVS=("FAKE_EDG_FAIL=1")
run_nfcxx --backend=gcc main.cpp -o prog
case_end

case_begin cuda-input  # a .cu input
run_nfcxx --backend=gcc -c kernel.cu -o kernel.o
case_end

case_begin trace-flag  # --trace: the eccp span is written with its name and category
run_nfcxx --backend=gcc "--trace=$sb/t.json" -c main.cpp -o main.o
case_end

case_begin trace-fail  # --trace with a failing eccp: no eccp span
ENVS=("FAKE_EDG_FAIL=1")
run_nfcxx --backend=gcc "--trace=$sb/t.json" -c main.cpp -o main.o
case_end

case_begin time-log    # NFCXX_TIME_LOG: the eccp stage is logged
ENVS=("NFCXX_TIME_LOG=$sb/time.log")
run_nfcxx --backend=gcc -c main.cpp -o main.o
case_end

case_begin shared-link # -shared: the shared link's exports reach eccp
run_nfcxx --backend=gcc -shared -fPIC main.cpp -o libm.so
case_end

case_begin include-define-lib # -I, -D and -l go to eccp in order
run_nfcxx --backend=gcc -Iinc -DFOO=1 main.cpp -o prog -lm
case_end

case_begin keep-and-fail # --keep-intermediates with a failing eccp: the kept directory is named
ENVS=("FAKE_EDG_FAIL=1")
run_nfcxx --backend=gcc --keep-intermediates -c main.cpp -o main.o
case_end

echo "driver-eccp-call goldens: $pass passed, $fail failed"
[ "$fail" = 0 ] || [ "$mode" = --record ]

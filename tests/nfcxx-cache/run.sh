#!/usr/bin/env bash
# Checks nfcxx's compile cache, now decided and stored by scripts/nfcxx-cache.rb, against the driver it was before
# (tests/nfcxx-cache/nfcxx-bash, frozen). Each case runs in one sandbox (a copy of fixtures/): the live driver, then the frozen
# one, from the same state. Compared: the printed decisions (CP and RUN lines of the file operations are left out: the Ruby
# helper makes its own copies, so the sandbox is compared instead), the exit status, stderr, and the sandbox after the run
# (every file and directory, with the cache entries and the cache log). The live driver's sandbox must also pass the case's
# CHECK, and its decision lines must print the case's EXPECT.
#   tests/nfcxx-cache/run.sh           runs the cases
#   tests/nfcxx-cache/run.sh --mutate  changes the key length in the Ruby helper and checks that cases fail, then restores it
#                                      and runs them again
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
port=$root/scripts/nfcxx-cache.rb
frozen=$here/nfcxx-bash
oracle=$here/bash-decision.sh
work=$(realpath "$(mktemp -d)")
scratch=$(realpath "$(mktemp -d)")
backup=$scratch/nfcxx-cache.rb.orig
trap 'cp "$backup" "$port" 2>/dev/null; rm -rf "$work" "$scratch"' EXIT

# A stand-in EDG build: nfcxx's setup needs bin/eccp (the build itself is stubbed). The key lists its files on both sides.
mkdir -p "$scratch/edg/bin" && printf '#!/bin/sh\nexit 1\n' > "$scratch/edg/bin/eccp" && chmod +x "$scratch/edg/bin/eccp"
base_env=("EDG_BUILD=$scratch/edg" "NFCXX_CACHE_IO=$here/remote-stub.rb")   # the remote helper: the stand-in of the remote tier
# The backend of a case is CASE_BACKEND (set_case: gcc, or pathb with the stubbed Path B compile).

norm() { sed -e "s#$work#SANDBOX#g" -e "s#$root#ROOT#g" -e 's/\.\(tmp\|remote\)\.[0-9][0-9]*/.\1.PID/g'; }
# The decision lines: the file operations (CP, and the RUN of rm, mkdir and mv) are left out; the build, the remote helper and
# EXIT are kept.
decisions() { grep -v -E '^(CP |RUN (rm|mkdir|mv) )' | norm; }

reset() {  # reset: the sandbox holds the fixtures and nothing else
  rm -rf "$work"; mkdir -p "$work"; cp -r "$here/fixtures/." "$work/"
}

# run_driver FILE: the driver of the case (FILE is the live nfcxx or the frozen copy), in the sandbox; the decision lines are printed
run_driver() {
  (cd "$work" && env -i RUBY="$(command -v ruby)" PATH="$PATH" HOME="$HOME" "${base_env[@]}" "${CASE_ENV[@]}" "${CASE_TEST[@]}" \
     bash "$oracle" "$1" "--backend=$CASE_BACKEND" "${CASE_ARGS[@]}")
}

snapshot() {  # the sandbox: every directory and file (with its sha-256), as the names and the contents
  (cd "$work" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
     if [ -d "$p" ]; then echo "D $p"; else echo "F $p $(sha256sum < "$p" | cut -c1-64)"; fi
   done) | norm
}

prepare() {  # prepare: the sandbox as the case starts (the fixtures, then PRE and MUTATE)
  reset
  [ -z "$PRE" ] || $PRE
  [ -z "$MUTATE" ] || $MUTATE
}

bad() { echo "      $*"; bad_case=1; }

run_case() {  # run_case: runs the case set up by set_case, and prints ok or FAIL
  bad_case=0
  prepare
  run_driver "$here/pinned-nfcxx.txt" > "$scratch/new.raw" 2> "$scratch/new.err"; new_rc=$?
  [ -z "$CHECK" ] || $CHECK
  snapshot > "$scratch/new.tree"
  prepare
  run_driver "$frozen" > "$scratch/old.raw" 2> "$scratch/old.err"; old_rc=$?
  snapshot > "$scratch/old.tree"

  decisions < "$scratch/new.raw" > "$scratch/new.dec"; decisions < "$scratch/old.raw" > "$scratch/old.dec"
  if ! diff -u "$scratch/old.dec" "$scratch/new.dec" > "$scratch/dec.diff"; then bad "decisions differ:"; sed 's/^/      /' "$scratch/dec.diff"; fi
  [ "$new_rc" = "$old_rc" ] || bad "exit status: new $new_rc, frozen $old_rc"
  norm < "$scratch/new.err" > "$scratch/new.errn"; norm < "$scratch/old.err" > "$scratch/old.errn"
  if ! diff -u "$scratch/old.errn" "$scratch/new.errn" > "$scratch/err.diff"; then bad "stderr differs:"; sed 's/^/      /' "$scratch/err.diff"; fi
  if ! diff -u "$scratch/old.tree" "$scratch/new.tree" > "$scratch/tree.diff"; then bad "the sandbox differs:"; sed 's/^/      /' "$scratch/tree.diff"; fi
  [ -z "$EXPECT" ] || grep -qF -- "$EXPECT" "$scratch/new.dec" || bad "EXPECT not printed: $EXPECT"
  if [ "$bad_case" = 0 ]; then pass=$((pass + 1)); echo "ok    $CASE"; else fail=$((fail + 1)); echo "FAIL  $CASE"; fi
}

# set_case NAME SRC OUT: a case with no environment, no extra options and no checks; the case then sets what it needs.
set_case() {
  CASE=$1; CASE_SRC=$2; CASE_OUT=$3; CASE_ARGS=(-c "$2" -o "$3"); CASE_ENV=(); CASE_TEST=(); CASE_BACKEND=gcc
  PRE=""; MUTATE=""; CHECK=""; EXPECT=""
}

# The key the frozen driver gives this case, from its cache log in the sandbox (run in the sandbox's own path, as the key needs it).
port_key() {
  reset
  local keylog=$scratch/keylog.txt; rm -f "$keylog"
  (cd "$work" && env -i RUBY="$(command -v ruby)" PATH="$PATH" HOME="$HOME" "${base_env[@]}" "${CASE_ENV[@]}" "NFCXX_CACHE_LOG=$keylog" \
     "${CASE_TEST[@]}" bash "$oracle" "$frozen" "--backend=$CASE_BACKEND" "${CASE_ARGS[@]}") > /dev/null 2>&1
  sed -n 's/^key //p' "$keylog" 2>/dev/null | head -1
}
entry_dir() { echo "$work/cache/objects/$1"; }
# the entries the live driver stored (their keys, by name)
stored_keys() { ls "$work/cache/objects" 2>/dev/null | grep -v '\.tmp\.' ; }

pre_hit() {  # an entry under the key the frozen driver gives: the driver must copy it back
  local dir; dir=$(entry_dir "$(port_key)")
  mkdir -p "$dir"; printf 'CACHED\n' > "$dir/obj"; printf 'CACHED-TI\n' > "$dir/ti"; printf 'CACHED-II\n' > "$dir/ii"
}
check_hit() {
  grep -qx CACHED "$work/main.o" && grep -qx CACHED-TI "$work/main.ti" && grep -qx CACHED-II "$work/main.ii" \
    || bad "the driver did not copy the entry back"
}
pre_old_entry() {  # an entry under the key of the header as it is before the change (PRE_KEY)
  PRE_KEY=$(port_key); local dir; dir=$(entry_dir "$PRE_KEY"); mkdir -p "$dir"; printf 'OLD\n' > "$dir/obj"
}
mutate_header() { printf '// changed\n' >> "$work/local.h"; }
check_key_changed() {  # the change of a header makes a new entry (the driver stores it), and the entry before the change stays
  [ -n "$PRE_KEY" ] && [ "$(stored_keys | wc -l)" -ge 2 ] && grep -qx OLD "$(entry_dir "$PRE_KEY")/obj" \
    && [ "$(stored_keys | grep -cx "$PRE_KEY")" = 1 ] || bad "the key did not change with the header"
}
check_remote_hit() {  # the remote entry (the stub's object) was copied back as the output
  grep -qx 'OBJECT remote' "$work/main.o" || bad "the driver did not copy the remote entry back"
}
check_stored() {  # the driver stored the object and the records under a key
  local k; k=$(stored_keys)
  [ "$(echo "$k" | wc -l)" = 1 ] && [ -n "$k" ] || { bad "no single entry: $k"; return; }
  local dir; dir=$(entry_dir "$k")
  grep -qx 'OBJECT main.o' "$dir/obj" && [ -f "$dir/ti" ] && [ -f "$dir/ii" ] || bad "the entry $k lacks the object or the records"
}
check_bad_remote() {
  grep -qF "nfcxx: NFCXX_CACHE_REMOTE takes gha (got 's3')" "$scratch/new.err" && [ "$new_rc" = 2 ] \
    || bad "the driver did not refuse the remote value"
}
# The Path B route (CASE_BACKEND=pathb): its entry is the object alone, and its key differs from the gcc key of the same command.
pre_hit_pathb() {
  local dir; dir=$(entry_dir "$(port_key)"); mkdir -p "$dir"; printf 'CACHED\n' > "$dir/obj"
}
check_hit_pathb() {
  grep -qx CACHED "$work/main.o" && [ ! -e "$work/main.ti" ] && [ ! -e "$work/main.ii" ] \
    || bad "the driver did not copy the Path B entry back"
}
check_stored_pathb() {
  local k; k=$(stored_keys)
  [ -n "$k" ] || { bad "no Path B entry"; return; }
  local dir; dir=$(entry_dir "$k")
  grep -qx 'OBJECT main.o' "$dir/obj" && [ ! -e "$dir/ti" ] && [ ! -e "$dir/ii" ] || bad "the Path B entry is not the object alone"
}
pre_gcc_entry() {  # an entry under the key of the same command on the gcc backend: a Path B compile must not take it
  local keep=$CASE_BACKEND k dir
  CASE_BACKEND=gcc; k=$(port_key); CASE_BACKEND=$keep
  dir=$(entry_dir "$k"); mkdir -p "$dir"; printf 'GCC\n' > "$dir/obj"
}
check_not_gcc() { grep -qx GCC "$work/main.o" && bad "the Path B compile took the gcc entry" || true; }

run_all() {
  pass=0; fail=0
  set_case miss main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache"); EXPECT="RUN build main.o"; run_case

  set_case stored main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache"); CASE_TEST=(CACHE_TEST_RECORDS="ti ii")
  CHECK=check_stored; EXPECT="RUN build main.o"; run_case

  set_case cache-flag main.cpp main.o; CASE_ARGS=("--cache=$work/cache" -c main.cpp -o main.o); EXPECT="RUN build main.o"; run_case

  set_case hit main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache"); PRE=pre_hit; CHECK=check_hit; EXPECT="EXIT 0"; run_case

  set_case changed-header main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache"); PRE=pre_old_entry; MUTATE=mutate_header
  CHECK=check_key_changed; EXPECT="RUN build main.o"; run_case

  set_case cache-log main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_LOG=$work/cache.log")
  EXPECT="RUN build main.o"; run_case

  set_case gha-hit main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_REMOTE=gha")
  CASE_TEST=(CACHE_TEST_REMOTE=hit); CHECK=check_remote_hit; EXPECT="EXIT 0"; run_case

  set_case gha-miss main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_REMOTE=gha")
  CASE_TEST=(CACHE_TEST_REMOTE=miss); EXPECT="nfcxx-cache-io.rb remote-put"; run_case

  set_case gha-local-first main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_REMOTE=gha")
  CASE_TEST=(CACHE_TEST_REMOTE=hit); PRE=pre_hit; CHECK=check_hit; EXPECT="EXIT 0"; run_case

  set_case cache-log-flag main.cpp main.o; CASE_ARGS=("--cache-log=$work/cache.log" "--cache=$work/cache" -c main.cpp -o main.o)
  EXPECT="RUN build main.o"; run_case

  set_case cache-log-hit main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_LOG=$work/cache.log")
  PRE=pre_hit; CHECK=check_hit; EXPECT="EXIT 0"; run_case

  set_case cache-log-remote-hit main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_REMOTE=gha" "NFCXX_CACHE_LOG=$work/cache.log")
  CASE_TEST=(CACHE_TEST_REMOTE=hit); CHECK=check_remote_hit; EXPECT="EXIT 0"; run_case

  set_case cache-log-remote-miss main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_REMOTE=gha" "NFCXX_CACHE_LOG=$work/cache.log")
  CASE_TEST=(CACHE_TEST_REMOTE=miss); EXPECT="nfcxx-cache-io.rb remote-put"; run_case

  set_case bad-remote main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_REMOTE=s3"); CHECK=check_bad_remote
  run_case

  set_case headers-failed main_bad.cpp main_bad.o; CASE_ENV=("NFCXX_CACHE=$work/cache"); EXPECT="RUN build main_bad.o"
  run_case

  set_case no-cache main.cpp main.o; EXPECT="RUN build main.o"; run_case

  set_case pathb-miss main.cpp main.o; CASE_BACKEND=pathb; CASE_ENV=("NFCXX_CACHE=$work/cache"); EXPECT="RUN build main.o"; run_case

  set_case pathb-stored main.cpp main.o; CASE_BACKEND=pathb; CASE_ENV=("NFCXX_CACHE=$work/cache")
  CHECK=check_stored_pathb; EXPECT="RUN build main.o"; run_case

  set_case pathb-hit main.cpp main.o; CASE_BACKEND=pathb; CASE_ENV=("NFCXX_CACHE=$work/cache"); PRE=pre_hit_pathb
  CHECK=check_hit_pathb; EXPECT="EXIT 0"; run_case

  set_case pathb-not-gcc main.cpp main.o; CASE_BACKEND=pathb; CASE_ENV=("NFCXX_CACHE=$work/cache"); PRE=pre_gcc_entry
  CHECK=check_not_gcc; EXPECT="RUN build main.o"; run_case

  set_case pathb-changed-header main.cpp main.o; CASE_BACKEND=pathb; CASE_ENV=("NFCXX_CACHE=$work/cache")
  PRE=pre_old_entry; MUTATE=mutate_header; CHECK=check_key_changed; EXPECT="RUN build main.o"; run_case

  echo "$pass passed, $fail failed"
  [ "$fail" = 0 ]
}

if [ "${1:-}" = --mutate ]; then
  cp "$port" "$backup"
  sed -i 's/hexdigest(inputs + "\\n")\[0, 40\]/hexdigest(inputs + "\\n")[0, 39]/' "$port"
  cmp -s "$port" "$backup" && { echo "the mutation did not apply"; exit 1; }
  echo "mutated (key length 39):"
  if run_all > "$scratch/mut.out"; then echo "the mutation was not caught"; cat "$scratch/mut.out"; exit 1; fi
  tail -1 "$scratch/mut.out"
  cp "$backup" "$port"
  echo "restored; running again:"
fi
run_all

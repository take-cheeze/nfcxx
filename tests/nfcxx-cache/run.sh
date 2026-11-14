#!/usr/bin/env bash
# Checks the port of nfcxx's compile cache (scripts/nfcxx-cache.rb) against the bash (tests/nfcxx-cache/bash-decision.sh).
# Each case runs in one sandbox (a copy of fixtures/): the port's decision, then the bash's, from the same state. The printed
# lines (RUN, CP, EXIT) must match, and so must the stderr and the exit status; the key the port prints (KEY) must be the key
# the bash stores its entry under (CHECK); the cache log must match the file the bash writes; and the case's EXPECT line must
# be printed.
#   tests/nfcxx-cache/run.sh           runs the cases
#   tests/nfcxx-cache/run.sh --mutate  changes the key length in the port and checks that cases fail, then restores the port
#                                      and runs them again
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
port=$root/scripts/nfcxx-cache.rb
oracle=$here/bash-decision.sh
work=$(realpath "$(mktemp -d)")
scratch=$(realpath "$(mktemp -d)")
backup=$scratch/nfcxx-cache.rb.orig
trap 'cp "$backup" "$port" 2>/dev/null; rm -rf "$work" "$scratch"' EXIT

# A stand-in EDG build: nfcxx's setup needs bin/eccp (the build itself is stubbed). The key lists its files on both sides.
mkdir -p "$scratch/edg/bin" && printf '#!/bin/sh\nexit 1\n' > "$scratch/edg/bin/eccp" && chmod +x "$scratch/edg/bin/eccp"
base_env=("EDG_BUILD=$scratch/edg")
# The backend of a case is CASE_BACKEND (set_case: gcc, or pathb with the stubbed Path B compile); it is passed as --backend=
# on both sides, so it is part of the key on both sides.

norm() { sed -e "s#$work#SANDBOX#g" -e "s#$root#ROOT#g" -e 's/\.\(tmp\|remote\)\.[0-9][0-9]*/.\1.PID/g'; }

reset() {  # reset: the sandbox holds the fixtures and nothing else
  rm -rf "$work"; mkdir -p "$work"; cp -r "$here/fixtures/." "$work/"
}

run_port() {  # run_port: the port's output for the case, in the sandbox (the -M output is the real one)
  local opts=() e v a mdeps=$scratch/mdeps.txt
  if (cd "$work" && g++ -M -std=c++23 "$CASE_SRC" > "$mdeps" 2>/dev/null); then opts+=("--mdeps=$mdeps"); else opts+=(--mdeps-failed); fi
  # the setup exports NFCXX_CC for --backend=gcc (nfcxx's case on the backend): the port is given it as the setup leaves it
  for e in "${base_env[@]}" "${CASE_ENV[@]}" "NFCXX_CC=$root/scripts/gcc-cc"; do opts+=("--env=$e"); done
  for v in compile_only=1 ncpp=1 outset=1 nobj=0 modules=0 preprocess=0 stdin_src=0 depmode= cfiles_n=0 cu_n=0 cpp2_n=0 "out=$CASE_OUT"; do
    opts+=("--var=$v")
  done
  opts+=("--var=backend=$CASE_BACKEND")
  for a in "--backend=$CASE_BACKEND" "${CASE_ARGS[@]}"; do opts+=("--arg=$a"); done
  opts+=("--src=$CASE_SRC")
  (cd "$work" && env -i PATH="$PATH" ruby "$port" "${opts[@]}" "${CASE_PORT[@]}")
}

run_bash() {  # run_bash: the bash's output for the case, in the sandbox
  (cd "$work" && env -i PATH="$PATH" HOME="$HOME" "${base_env[@]}" "${CASE_ENV[@]}" "${CASE_TEST[@]}" \
     bash "$oracle" "--backend=$CASE_BACKEND" "${CASE_ARGS[@]}")
}

prepare() {  # prepare: the sandbox as the case starts (the fixtures, then PRE and MUTATE)
  reset
  [ -z "$PRE" ] || $PRE
  [ -z "$MUTATE" ] || $MUTATE
}

bad() { echo "      $*"; bad_case=1; }

run_case() {  # run_case: runs the case set up by set_case, and prints ok or FAIL
  bad_case=0; PORT_KEY=""
  prepare
  run_port > "$scratch/port.raw" 2> "$scratch/port.err"; PORT_RC=$?
  PORT_KEY=$(sed -n 's/^KEY //p' "$scratch/port.raw")
  prepare
  run_bash > "$scratch/bash.raw" 2> "$scratch/bash.err"; bash_rc=$?

  sed -e '/^KEY /d' -e '/^CAT /,/^END$/d' "$scratch/port.raw" | norm > "$scratch/port.dec"
  norm < "$scratch/bash.raw" > "$scratch/bash.dec"
  if ! diff -u "$scratch/bash.dec" "$scratch/port.dec" > "$scratch/dec.diff"; then bad "decisions differ:"; sed 's/^/      /' "$scratch/dec.diff"; fi
  [ "$PORT_RC" = "$bash_rc" ] || bad "exit status: port $PORT_RC, bash $bash_rc"
  norm < "$scratch/port.err" > "$scratch/port.errn"; norm < "$scratch/bash.err" > "$scratch/bash.errn"
  if ! diff -u "$scratch/bash.errn" "$scratch/port.errn" > "$scratch/err.diff"; then bad "stderr differs:"; sed 's/^/      /' "$scratch/err.diff"; fi
  if [ "$CASE_LOG" = 1 ]; then
    sed -n '/^CAT /,/^END$/p' "$scratch/port.raw" | sed '1d;$d' | norm > "$scratch/port.log"
    norm < "$work/cache.log" > "$scratch/bash.log" 2>/dev/null || bad "the bash wrote no cache log"
    if ! diff -u "$scratch/bash.log" "$scratch/port.log" > "$scratch/log.diff"; then bad "cache log differs:"; sed 's/^/      /' "$scratch/log.diff"; fi
  fi
  [ -z "$EXPECT" ] || grep -qF -- "$EXPECT" "$scratch/port.dec" || bad "EXPECT not printed: $EXPECT"
  [ -z "$CHECK" ] || $CHECK
  if [ "$bad_case" = 0 ]; then pass=$((pass + 1)); echo "ok    $CASE"; else fail=$((fail + 1)); echo "FAIL  $CASE"; fi
}

# set_case NAME SRC OUT: a case with no environment, no extra options and no checks; the case then sets what it needs.
set_case() {
  CASE=$1; CASE_SRC=$2; CASE_OUT=$3; CASE_ARGS=(-c "$2" -o "$3"); CASE_ENV=(); CASE_TEST=(); CASE_PORT=(); CASE_BACKEND=gcc
  CASE_LOG=0; PRE=""; MUTATE=""; CHECK=""; EXPECT=""
}

entry_dir() { echo "$work/cache/objects/$1"; }

pre_hit() {  # an entry under the key the port gives: the bash must copy it back
  local dir; dir=$(entry_dir "$(port_key)")
  mkdir -p "$dir"; printf 'CACHED\n' > "$dir/obj"; printf 'CACHED-TI\n' > "$dir/ti"; printf 'CACHED-II\n' > "$dir/ii"
}
check_hit() {
  grep -qx CACHED "$work/main.o" && grep -qx CACHED-TI "$work/main.ti" && grep -qx CACHED-II "$work/main.ii" \
    || bad "the bash did not copy the entry back"
}
port_key() { run_port | sed -n 's/^KEY //p'; }

pre_old_entry() {  # an entry under the key of the header as it is before the change
  PRE_KEY=$(port_key); local dir; dir=$(entry_dir "$PRE_KEY"); mkdir -p "$dir"; printf 'OLD\n' > "$dir/obj"
}
mutate_header() { printf '// changed\n' >> "$work/local.h"; }
check_key_changed() { [ -n "$PORT_KEY" ] && [ "$PORT_KEY" != "$PRE_KEY" ] || bad "the key did not change with the header"; }

check_stored() {  # the bash stored the object and the records under the key the port gives
  local dir; dir=$(entry_dir "$PORT_KEY")
  [ -n "$PORT_KEY" ] && grep -qx 'OBJECT main.o' "$dir/obj" && [ -f "$dir/ti" ] && [ -f "$dir/ii" ] \
    || bad "no entry under the port's key $PORT_KEY"
}
check_bad_remote() {
  grep -qF "nfcxx: NFCXX_CACHE_REMOTE takes gha (got 's3')" "$scratch/port.err" && [ "$PORT_RC" = 2 ] \
    || bad "the port did not refuse the remote value"
}
# The Path B route (CASE_BACKEND=pathb): its entry is the object alone, and its key differs from the gcc key of the same command.
pre_hit_pathb() {  # an entry under the Path B key: the object only
  local dir; dir=$(entry_dir "$(port_key)"); mkdir -p "$dir"; printf 'CACHED\n' > "$dir/obj"
}
check_hit_pathb() {  # the bash copied the object back, and no records (Path B writes none)
  grep -qx CACHED "$work/main.o" && [ ! -e "$work/main.ti" ] && [ ! -e "$work/main.ii" ] \
    || bad "the bash did not copy the Path B entry back"
}
check_stored_pathb() {  # the bash stored the object under the Path B key the port gives, and no records
  local dir; dir=$(entry_dir "$PORT_KEY")
  [ -n "$PORT_KEY" ] && grep -qx 'OBJECT main.o' "$dir/obj" && [ ! -e "$dir/ti" ] && [ ! -e "$dir/ii" ] \
    || bad "no Path B entry under the port's key $PORT_KEY"
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
  CASE_PORT=(--records=ti,ii); CHECK=check_stored; EXPECT="RUN mv"; run_case

  set_case cache-flag main.cpp main.o; CASE_ARGS=("--cache=$work/cache" -c main.cpp -o main.o); EXPECT="RUN build main.o"; run_case

  set_case hit main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache"); PRE=pre_hit; CHECK=check_hit; EXPECT="EXIT 0"; run_case

  set_case changed-header main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache"); PRE=pre_old_entry; MUTATE=mutate_header
  CHECK=check_key_changed; EXPECT="RUN build main.o"; run_case

  set_case cache-log main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_LOG=$work/cache.log"); CASE_LOG=1
  EXPECT="RUN build main.o"; run_case

  set_case gha-hit main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_REMOTE=gha")
  CASE_TEST=(CACHE_TEST_REMOTE=hit); CASE_PORT=(--remote=hit); EXPECT="EXIT 0"; run_case

  set_case gha-miss main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_REMOTE=gha")
  CASE_TEST=(CACHE_TEST_REMOTE=miss); CASE_PORT=(--remote=miss); EXPECT="nfcxx-cache-gha.py put"; run_case

  set_case bad-remote main.cpp main.o; CASE_ENV=("NFCXX_CACHE=$work/cache" "NFCXX_CACHE_REMOTE=s3"); CHECK=check_bad_remote
  run_case

  set_case headers-failed main_bad.cpp main_bad.o; CASE_ENV=("NFCXX_CACHE=$work/cache"); EXPECT="RUN build main_bad.o"
  run_case

  set_case no-cache main.cpp main.o; EXPECT="RUN build main.o"; run_case

  set_case pathb-miss main.cpp main.o; CASE_BACKEND=pathb; CASE_ENV=("NFCXX_CACHE=$work/cache"); EXPECT="RUN build main.o"; run_case

  set_case pathb-stored main.cpp main.o; CASE_BACKEND=pathb; CASE_ENV=("NFCXX_CACHE=$work/cache")
  CHECK=check_stored_pathb; EXPECT="RUN mv"; run_case

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

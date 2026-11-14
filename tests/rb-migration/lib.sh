#!/bin/bash
# Shared by tests/rb-migration/<name>/run.sh: a differential test of scripts/setup-<name>.rb (the port) against the bash it
# replaced, tests/rb-migration/<name>/oracle.sh. Each case runs both in a fresh sandbox, with the external commands replaced
# by the stubs of stub.sh on PATH, and compares the stub log, stdout, stderr and exit status. The sandbox's root holds the
# script under test in root/scripts/ (and root/tests/bc2cpp/fetch.sh, which bc2cpp sources).
#
# A run.sh sets NAME, defines prep SB WORDS (the fixtures of a case: SB is the sandbox, WORDS the case's variables with
# @SB@ expanded), and passes its cases on stdin, one per line: LABEL|VARIABLES. VARIABLES are NAME=VALUE words for the
# environment of both runs (@SB@ is the sandbox's path); RB_OMIT=NAME leaves the stub NAME off the PATH.
#   bash tests/rb-migration/<name>/run.sh
RBM_STUBS="curl git tar unzip python3 cargo uname mktemp sha256sum rake ninja c++ cxxfail rtcc mkdir rm install ln mv"
rbm_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
rbm_repo=$(cd "$rbm_here/../.." && pwd -P)
rbm_ruby=$(command -v ruby)
rbm_tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$rbm_tmp"' EXIT
rbm_pass=0
rbm_fail=0
rbm_failed=""

# rbm_build SB SIDE: the sandbox's stubs and directories, and the script of SIDE (bash: the oracle; ruby: the port)
rbm_build() {
  local sb=$1 side=$2 c
  mkdir -p "$sb/bin" "$sb/root/scripts" "$sb/root/build" "$sb/root/tests/bc2cpp" "$sb/work"
  for c in $RBM_STUBS; do ln -s "$rbm_here/stub.sh" "$sb/bin/$c"; done
  cp "$rbm_repo/tests/bc2cpp/fetch.sh" "$sb/root/tests/bc2cpp/fetch.sh"
  if [ "$side" = bash ]; then
    cp "$rbm_here/$NAME/oracle.sh" "$sb/root/scripts/setup-$NAME.sh"
  else
    cp "$rbm_repo/scripts/setup-$NAME.rb" "$rbm_repo/scripts/setup-common.rb" "$sb/root/scripts/"
  fi
}

# rbm_run SIDE SB WORDS: runs the script; its stdout, stderr, stub log and exit status go to SB/out, SB/err, SB/log, SB/status
rbm_run() {
  local side=$1 sb=$2 words=${3//@SB@/$2} w
  local -a envw=() cmd
  for w in $words; do
    case $w in
      RB_OMIT=*) rm -f "$sb/bin/${w#RB_OMIT=}" ;;
      *) envw+=("$w") ;;
    esac
  done
  if [ "$side" = bash ]; then cmd=(bash "$sb/root/scripts/setup-$NAME.sh")
  else cmd=("$rbm_ruby" "$sb/root/scripts/setup-$NAME.rb"); fi
  : > "$sb/log"
  (cd "$sb/work" && env -i PATH="$sb/bin:/usr/bin:/bin" RB_STUB_LOG="$sb/log" RB_SB="$sb" \
     "${envw[@]}" "${cmd[@]}" > "$sb/out" 2> "$sb/err")
  echo $? > "$sb/status"
}

# rbm_norm FILE SB: the file's text with the sandbox's path as @SB@
rbm_norm() {
  local t
  t=$(cat "$1")
  printf '%s\n' "${t//"$2"/@SB@}"
}

# rbm_case LABEL WORDS: one case, both sides; a mismatch is listed with both texts
rbm_case() {
  local label=$1 words=$2 sbb sbr f a b diffs="" ok=1
  sbb=$(cd "$(mktemp -d "$rbm_tmp/b.XXXX")" && pwd -P)
  sbr=$(cd "$(mktemp -d "$rbm_tmp/r.XXXX")" && pwd -P)
  rbm_build "$sbb" bash
  rbm_build "$sbr" ruby
  prep "$sbb" "${words//@SB@/$sbb}"
  prep "$sbr" "${words//@SB@/$sbr}"
  rbm_run bash "$sbb" "$words"
  rbm_run ruby "$sbr" "$words"
  for f in log out err status; do
    a=$(rbm_norm "$sbb/$f" "$sbb")
    b=$(rbm_norm "$sbr/$f" "$sbr")
    if [ "$a" != "$b" ]; then
      ok=0
      diffs+="--- $f differs
bash:
$a
ruby:
$b
"
    fi
  done
  if [ $ok = 1 ]; then
    rbm_pass=$((rbm_pass + 1))
  else
    rbm_fail=$((rbm_fail + 1))
    rbm_failed+="== $label
$diffs"
  fi
  rm -rf "$sbb" "$sbr"
}

# rbm_cases: the cases on stdin, LABEL|VARIABLES
rbm_cases() {
  local label words
  while IFS='|' read -r label words; do
    case $label in ""|"#"*) continue ;; esac
    rbm_case "$label" "$words"
  done
}

# rbm_finish: the failures and the count; the status is 0 when every case matches
rbm_finish() {
  [ -z "$rbm_failed" ] || printf '%s' "$rbm_failed"
  echo "$NAME: passed $rbm_pass, failed $rbm_fail"
  [ "$rbm_fail" = 0 ]
}

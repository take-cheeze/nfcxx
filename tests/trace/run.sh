#!/bin/bash
# Differential test of scripts/trace.rb against scripts/trace.sh. Each case runs the same spans (or the driver's begin and
# finish) once through the bash functions and once through the Ruby module, with the same environment, in a fresh
# directory each. The two trace files and time logs must match after the clock readings and process ids are replaced by
# placeholders (their values differ between any two runs; their presence and order do not).
#
#   bash tests/trace/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# the same placeholders for both sides
normalize() {
  sed -e 's/"ts":[0-9]*/"ts":N/g' -e 's/"dur":[0-9]*/"dur":N/g' -e 's/"pid":[0-9]*/"pid":P/g' \
      -e 's/^[0-9][0-9]*\.[0-9][0-9][0-9][0-9][0-9][0-9]\t/S.SSSSSS\t/' "$1"
}

# the cases: "NAME | ENVIRONMENT | BASH SNIPPET | RUBY SNIPPET"; the snippets use $OUT (the trace file) and $LOG (the log)
cases=(
  "off | | t=\$(trace_start); trace_end \"\$t\" x driver | t = start; span(t, 'x', 'driver')"
  "log-only | NFCXX_TRACE_UNIT=u.c | t=\$(trace_start); trace_end \"\$t\" 'compile a' pathb | t = start; span(t, 'compile a', 'pathb')"
  "trace-only | NFCXX_TRACE=@OUT@ | t=\$(trace_start); trace_end \"\$t\" 'say \"hi\" \\ x' cat | t = start; span(t, 'say \"hi\" \\ x', 'cat')"
  "both-with-unit | NFCXX_TRACE=@OUT@ NFCXX_TIME_LOG=@LOG@ NFCXX_TRACE_UNIT=src/a.cc | t=\$(trace_start); trace_end \"\$t\" 'EH shim' driver; trace_end \"\$t\" 'link' pathb | t = start; span(t, 'EH shim', 'driver'); span(t, 'link', 'pathb')"
  "driver-begin-finish | NFCXX_TRACE_UNIT=a.c NFCXX_TRACE_UNIT=a.c | trace_begin @OUT@; t=\$(trace_start); trace_end \"\$t\" 'front end' frontend; trace_finish | t0 = begin_trace('@OUT@'); t = start; span(t, 'front end', 'frontend'); finish_trace(t0)"
  "nested-no-brackets | NFCXX_TRACE_OWNER=4242 | trace_begin @OUT@; t=\$(trace_start); trace_end \"\$t\" 'inner' driver; trace_finish | t0 = begin_trace('@OUT@'); t = start; span(t, 'inner', 'driver'); finish_trace(t0)"
  "finish-without-begin | NFCXX_TRACE=@OUT@ | trace_finish; echo done | finish_trace(nil); puts 'done'"
)

pass=0; fail=0
for c in "${cases[@]}"; do
  IFS='|' read -r name envs bsnip rsnip <<< "$c"
  name=${name// /}
  # the placeholders: the trace file and the time log, in one directory per side
  for side in bash ruby; do
    d=$work/$name-$side; mkdir -p "$d"
    e=${envs//@OUT@/$d/out.json}; e=${e//@LOG@/$d/log.txt}
    s=${bsnip//@OUT@/$d/out.json}; r=${rsnip//@OUT@/$d/out.json}
    if [ "$side" = bash ]; then
      (cd "$d" && env -i PATH="$PATH" HOME="$d" $e bash -c "source '$repo/tests/host-sys/oracle.sh'; source '$repo/scripts/trace.sh'; $s" \
         > "$d/stdout" 2>&1)
    else
      (cd "$d" && env -i PATH="$PATH" HOME="$d" $e ruby -e "require '$repo/scripts/trace'; include NfccxxTrace; $r" > "$d/stdout" 2>&1)
    fi
    echo $? > "$d/status"
  done
  ok=1
  for f in out.json log.txt stdout status; do
    a=$work/$name-bash/$f; b=$work/$name-ruby/$f
    [ -e "$a" ] || [ -e "$b" ] || continue
    if ! diff <(if [ -e "$a" ]; then normalize "$a"; fi) <(if [ -e "$b" ]; then normalize "$b"; fi) > "$work/$name.diff.$f" 2>&1; then
      ok=0
      echo "FAIL $name ($f)"; sed 's/^/  /' "$work/$name.diff.$f" | head -20
    fi
  done
  if [ $ok = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
done
echo "trace: $pass passed, $fail failed"
[ $fail = 0 ]

#!/bin/bash
# Differential test of nfcxx's cache configuration (cache_dir, cache_log_file, cache_remote, and the NFCXX_CACHE_REMOTE refusal):
# the bash lines verbatim (from the frozen driver, tests/driver-body/nfcxx-bash) against scripts/nfcxx-cache-config.rb plan as the
# driver runs it (cfg_sh=$(...) || exit $?; eval "$cfg_sh"). Each case runs both under env -i with the same environment: stdout
# (the three variables), standard error and exit status must match.
#   bash tests/driver-cacheconfig/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
sed -n '/^cache_dir=\${NFCXX_CACHE:-}; cache_log_file=\${NFCXX_CACHE_LOG:-}/,/^\[ -n "\$cache_dir" \] || \[ -z "\$cache_remote" \] || cache_dir=/p' \
  "$repo/tests/driver-body/nfcxx-bash" > "$work/lines.sh"
[ "$(wc -l < "$work/lines.sh")" = 6 ] || { echo "driver-cacheconfig: the bash lines are not in the frozen driver" >&2; exit 2; }
dump='printf "cache_dir=[%s]\ncache_log_file=[%s]\ncache_remote=[%s]\n" "$cache_dir" "$cache_log_file" "$cache_remote"'
{ cat "$work/lines.sh"; echo "$dump"; } > "$work/bash.sh"
cat > "$work/plan.sh" <<'PLAN'
cfg_sh=$("${RUBY:-ruby}" "$ROOT/scripts/nfcxx-cache-config.rb" plan) || exit $?
eval "$cfg_sh"
PLAN
{ cat "$work/plan.sh"; echo "$dump"; } > "$work/plan-run.sh"
ruby_bin=$(command -v ruby)

# case_ NAME [VAR=VALUE ...]: both sides under the same environment (env -i: only these variables, and PATH)
case_() {
  local name=$1; shift
  env -i PATH="$PATH" "$@" bash "$work/bash.sh" > "$work/b.out" 2> "$work/b.err"; local b_rc=$?
  env -i PATH="$PATH" ROOT="$repo" RUBY="$ruby_bin" "$@" bash "$work/plan-run.sh" > "$work/p.out" 2> "$work/p.err"; local p_rc=$?
  local ok=1
  cmp -s "$work/b.out" "$work/p.out" || ok=0
  cmp -s "$work/b.err" "$work/p.err" || ok=0
  [ "$b_rc" = "$p_rc" ] || ok=0
  if [ "$ok" = 1 ]; then
    pass=$((pass + 1)); echo "ok   $name (rc $b_rc; $(tr '\n' ' ' < "$work/b.out")$(tr '\n' ' ' < "$work/b.err"))"
  else
    fail=$((fail + 1)); echo "FAIL $name (rc bash $b_rc, planner $p_rc)"
    echo "  bash out:  $(cat "$work/b.out")"; echo "  plan out:  $(cat "$work/p.out")"
    echo "  bash err:  $(cat "$work/b.err")"; echo "  plan err:  $(cat "$work/p.err")"
  fi
}

case_ "nothing set"
case_ "NFCXX_CACHE set" NFCXX_CACHE=/var/cache/nf
case_ "NFCXX_CACHE empty" NFCXX_CACHE=
case_ "NFCXX_CACHE_REMOTE=gha alone" NFCXX_CACHE_REMOTE=gha
case_ "NFCXX_CACHE_REMOTE=gha with NFCXX_CACHE" NFCXX_CACHE_REMOTE=gha NFCXX_CACHE=/c/dir
case_ "NFCXX_CACHE_REMOTE=gha with NFCXX_CACHE empty" NFCXX_CACHE_REMOTE=gha NFCXX_CACHE=
case_ "NFCXX_CACHE_REMOTE empty" NFCXX_CACHE_REMOTE=
case_ "NFCXX_CACHE_REMOTE=empty with NFCXX_CACHE" NFCXX_CACHE_REMOTE= NFCXX_CACHE=/c/dir
case_ "NFCXX_CACHE_REMOTE=bogus (refusal)" NFCXX_CACHE_REMOTE=bogus
case_ "NFCXX_CACHE_REMOTE=bogus with NFCXX_CACHE (refusal)" NFCXX_CACHE_REMOTE=bogus NFCXX_CACHE=/c/dir
case_ "NFCXX_CACHE_REMOTE=GHA (refusal, case sensitive)" NFCXX_CACHE_REMOTE=GHA
case_ "NFCXX_CACHE_REMOTE=gha with TMPDIR" NFCXX_CACHE_REMOTE=gha TMPDIR=/scratch/t
case_ "NFCXX_CACHE_REMOTE=gha with TMPDIR empty" NFCXX_CACHE_REMOTE=gha TMPDIR=
case_ "TMPDIR set, no remote" TMPDIR=/scratch/t
case_ "TMPDIR empty, no remote" TMPDIR=
case_ "NFCXX_CACHE_LOG set" NFCXX_CACHE_LOG=/tmp/log.txt
case_ "NFCXX_CACHE_LOG set with remote" NFCXX_CACHE_LOG=/tmp/log.txt NFCXX_CACHE_REMOTE=gha
case_ "NFCXX_CACHE with a space and a quote" "NFCXX_CACHE=/my dir/it's here"
case_ "NFCXX_CACHE with shell metacharacters" 'NFCXX_CACHE=$HOME `id` \ "q" ; x*'
case_ "TMPDIR with a space and a quote, remote gha" "TMPDIR=/t x'y" NFCXX_CACHE_REMOTE=gha
case_ "NFCXX_CACHE_LOG with a quote" "NFCXX_CACHE_LOG=/l/it's.log" NFCXX_CACHE=/c

echo "driver-cacheconfig: $pass passed, $fail failed"
[ "$fail" = 0 ]

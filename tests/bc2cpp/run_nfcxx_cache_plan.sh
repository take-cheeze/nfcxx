#!/usr/bin/env bash
# bc2cpp world: scripts/nfcxx-cache-plan.rb, the compile cache's lookup arguments (NfcxxCachePlan), as a script world
# (tests/bc2cpp/leaf.sh). The entry reads the records on stdin and prints the options, as the driver's cache_check does. The
# cases are record files: every record kind, an empty record list, an unknown kind (status 2), and a short list.
# Needs Ruby with the Gemfile's gems (prism 1.9.0, rbs 4.0.0, installed by bundle); without them it prints a skip.
cd "$(dirname "$0")/../.." || exit 1
root=$PWD
command -v ruby >/dev/null || { echo "SKIP bc2cpp nfcxx-cache-plan: ruby not installed"; exit 0; }
. tests/bc2cpp/leaf.sh
leaf_prepare; status=$?
[ "$status" = 2 ] && exit 0 # a fetch failure is a network fault, not a result (fetch.sh printed why)
[ "$status" = 0 ] || { echo "FAIL bc2cpp nfcxx-cache-plan: preparing the world failed"; exit 1; }

work=build/bc2cpp/nfcxx-cache-plan
mkdir -p "$work"
# records: a kind letter and its payload, each NUL-terminated (scripts/nfcxx-cache-plan.rb)
printf 'ocache-dir=/x\0vFOO=bar\0a--foo\0a--cache=/c\0a--trace=t\0sc++17\0f-O2\0pinc.h\0d/usr/inc\0' > "$work/full.rec"
: > "$work/empty.rec"
printf 'ocache-dir=/x\0zbogus\0' > "$work/bad.rec"
printf 'oout=o.bin\0a--arg-with-space x\0' > "$work/small.rec"
cases="$work/cases.txt"
for f in full empty bad small; do echo "<$root/$work/$f.rec"; done > "$cases"

# the world: the script without its main guard, then the entry the harness calls in place of the tail
world="$work/world.rb"
leaf_world "$world" scripts/nfcxx-cache-plan.rb
cat >> "$world" <<'RUBY'
module NfcxxCachePlanWorld
  def self.main_stdin
    options = NfcxxCachePlan.plan(NfcxxCachePlan.records_of($stdin.read))
    return 2 if options.nil?

    options.each { |opt| $stdout.write(opt + "\0") }
    0
  end
end
rc = NfcxxCachePlanWorld.main_stdin
exit(rc) if rc != 0
RUBY
tail=$'rc = NfcxxCachePlanWorld.main_stdin\nexit(rc) if rc != 0\n'

if leaf_run nfcxx-cache-plan "$world" "$tail" NfcxxCachePlanWorld.main_stdin "$cases"; then
  echo "PASS bc2cpp nfcxx-cache-plan"
else
  echo "FAIL bc2cpp nfcxx-cache-plan: the compiled and interpreted runs differ (build/bc2cpp/nfcxx-cache-plan.log)"
  exit 1
fi

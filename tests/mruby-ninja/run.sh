#!/usr/bin/env bash
# Generic mrbgem.rake support of scripts/mruby-ninja.rb. A gem whose build step generates a header: its file task runs
# as a ninja edge and the interpreter gets the value. A gem with a rake call the generator refuses (rule): the
# generation fails with that message. Needs the mruby checkout of scripts/setup-mruby.sh (MRUBY_SRC, default
# build/mruby-tool/src); builds into a temporary directory.
cd "$(dirname "$0")/../.."
root=$PWD
src=${MRUBY_SRC:-$root/build/mruby-tool/src}
[ -d "$src/mrbgems" ] || { echo "run.sh: no mruby checkout at $src (run scripts/setup-mruby.sh)" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# The tool config with one more gem: its MRuby::Build block gets a conf.gem line before the final end.
config_with() { # config_with <gem dir> <out file>
  ruby -e 'File.write(ARGV[1], File.read("scripts/mruby-tool-config.rb").sub(/\nend\s*\z/, "\n  conf.gem #{ARGV[0].inspect}\nend\n"))' \
    "$1" "$2"
}

config_with "$root/tests/mruby-ninja/gem" "$tmp/config.rb"
if ! NFCXX_ROOT=$root ruby scripts/mruby-ninja.rb generate "$src" "$tmp/config.rb" "$tmp/out" > "$tmp/gen.log" 2>&1; then
  echo "FAIL generate with tests/mruby-ninja/gem: $(tail -1 "$tmp/gen.log")"; fail=1
elif ! ninja -C "$tmp/out" "$tmp/out/host/bin/mruby" > "$tmp/ninja.log" 2>&1; then
  echo "FAIL ninja: $(grep -m1 -E 'error|Error' "$tmp/ninja.log")"; fail=1
else
  got=$("$tmp/out/host/bin/mruby" -e 'p GeneratedDemo.value' 2>&1)
  if [ "$got" = 42 ] && grep -q '^#define DEMO_VALUE 42$' "$tmp/out/host/mrbgems/mruby-generated-demo/demo_value.h"; then
    echo "ok   generated header: GeneratedDemo.value = 42 from the gem's file task"
  else
    echo "FAIL generated header: GeneratedDemo.value printed '$got'"; fail=1
  fi
fi

config_with "$root/tests/mruby-ninja/rule" "$tmp/rule.rb"
if NFCXX_ROOT=$root ruby scripts/mruby-ninja.rb generate "$src" "$tmp/rule.rb" "$tmp/rule-out" > "$tmp/rule.log" 2>&1; then
  echo "FAIL rule: the generation accepted a rule task"; fail=1
elif grep -q 'rule is not supported' "$tmp/rule.log"; then
  echo "ok   rule: refused with 'rule is not supported'"
else
  echo "FAIL rule: refused, but not with the expected message: $(tail -1 "$tmp/rule.log")"; fail=1
fi
exit $fail

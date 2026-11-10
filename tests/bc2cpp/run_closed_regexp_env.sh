#!/usr/bin/env bash
# bc2cpp world: tests/bc2cpp/closed/regexp_env.rb, a check of the two gems the script-world closed build adds (the regexp
# gem and an ENV that reads the process environment). The sealed executable's stdout, stderr and exit status are
# byte-identical to the mruby interpreter's on the same script.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp closed-regexp-env: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp closed-regexp-env: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp closed-regexp-env: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp closed-regexp-env: rake not installed"; exit 0; }

bc2cpp_fetch; status=$?
[ "$status" = 2 ] && exit 0
[ "$status" = 0 ] || exit 1
tree=$root/bc2cpp
export BC2CPP_TREE_ROOT=$tree BC2CPP_WORLD_ROOT=$bc2cpp_root
mkdir -p build/bc2cpp
jobs=$(nproc 2>/dev/null || echo 4)
(cd "$bc2cpp_root/3rd/mruby" && env -u LD MRUBY_CONFIG="$tree/tools/optcarrot_probe/mruby_build_config.rb" \
  rake -j"$jobs") > build/bc2cpp/mrbc.log 2>&1 ||
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp closed-regexp-env: building the probe mrbc failed"; exit 1; }

cases=build/bc2cpp/closed_regexp_env.cases
{
  echo "tests/bc2cpp/closed/regexp_env.rb"
  echo "--bogus tests/bc2cpp/closed/regexp_env.rb"
} > "$cases"
log=build/bc2cpp/closed_regexp_env.log
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script tests/bc2cpp/closed/regexp_env.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" \
  --bench tests/bc2cpp/closed/regexp_env.rb --repeat 1 --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp closed-regexp-env: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp closed-regexp-env: the cases differ"; exit 1; }
echo "PASS bc2cpp closed-regexp-env"

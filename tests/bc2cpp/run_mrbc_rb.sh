#!/usr/bin/env bash
# The mrbc_rb golden comparison (bc2cpp/tools/mrbc_rb/golden_test.rb): the Ruby RITE emitter's bytes against the fork's
# `mrbc -g`, built here from the pinned world's 3rd/mruby with its own build config (the default one, as the emitter was
# checked). Then the other two checks that need that oracle: cli_test.rb (bin/mrbc_rb, every output format of mrbc, also on
# the several-file gem sets with -g -S), codedump_test.rb (the instruction listing of mrbc -v) integration_test.rb (bc2cpp's own loader through the emitter), lib_test.rb (MrbcRb::Cli and the tree-based CDump) and structured_test.rb (the emitter's irep tree equals the parsed image). Fails if the
# oracle does not build or any comparison differs. Runs with the root Gemfile (Prism 1.9.0).
#   BC2CPP_RPG_DIR=dir        use an existing rpg-maker-clone checkout (tests/bc2cpp/fetch.sh)
#   MRBC_RB_CLI_SAMPLE=n      cli_test.rb, codedump_test.rb: check only every n-th single file of bc2cpp/ (default: all; ~2 min)
set -eu
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
bc2cpp_fetch || exit 1

mkdir -p build/bc2cpp
jobs=$(nproc 2>/dev/null || echo 4)
mruby=$bc2cpp_root/3rd/mruby
# BUNDLE_GEMFILE: the fork has a Gemfile of its own, which must not be the one bundler picks up here.
(cd "$mruby" && env -u LD BUNDLE_GEMFILE="$root/Gemfile" bundle exec rake -j"$jobs") > build/bc2cpp/mrbc_rb-oracle.log 2>&1 ||
  { tail -20 build/bc2cpp/mrbc_rb-oracle.log; echo "FAIL mrbc_rb: building the fork's mrbc failed"; exit 1; }

echo "mrbc_rb: oracle $mruby/bin/mrbc (world rpg-maker-clone $(git -C "$bc2cpp_root" rev-parse --short HEAD), fork $(git -C "$mruby" rev-parse --short HEAD))"
export MRBC="$mruby/bin/mrbc"
bundle exec ruby bc2cpp/tools/mrbc_rb/golden_test.rb
bundle exec ruby bc2cpp/tools/mrbc_rb/cli_test.rb
bundle exec ruby bc2cpp/tools/mrbc_rb/codedump_test.rb
bundle exec ruby bc2cpp/tools/mrbc_rb/integration_test.rb
bundle exec ruby bc2cpp/tools/mrbc_rb/lib_test.rb
bundle exec ruby bc2cpp/tools/mrbc_rb/structured_test.rb

#!/usr/bin/env bash
# The mrbc_rb golden comparison (bc2cpp/tools/mrbc_rb/golden_test.rb): the Ruby RITE emitter's bytes against the fork's
# `mrbc -g`, built here from the pinned world's 3rd/mruby with its own build config (the default one, as the emitter was
# checked). Fails if the oracle does not build or the comparison differs. Runs with the root Gemfile (Prism 1.9.0).
#   BC2CPP_RPG_DIR=dir   use an existing rpg-maker-clone checkout (tests/bc2cpp/fetch.sh)
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
MRBC="$mruby/bin/mrbc" bundle exec ruby bc2cpp/tools/mrbc_rb/golden_test.rb

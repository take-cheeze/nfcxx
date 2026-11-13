#!/usr/bin/env bash
# bc2cpp world: scripts/response-file.rb, the Ruby port of nfcc's @file expansion (tests/nfcc/response-file.sh checks
# it against the bash code), compiled by bc2cpp as a closed world (the script-world build kind, bc2cpp/tools/script_world/)
# on the mruby fork of the pinned rpg-maker-clone (tests/bc2cpp/fetch.sh). For each case of tests/nfcc/response/ (one
# response file, the full argument list, the loop), the stdout, stderr and exit status of the sealed executable must be
# byte-identical to the mruby interpreter's and to CRuby's on the same script.
# Needs Ruby 4.0 with the Gemfile's gems (prism 1.9.0, rbs 4.0.0, rake 13.4.2; `bundle install` with BUNDLE_GEMFILE set to
# this tree's Gemfile), a C/C++ compiler, bison and make. Without them it prints a skip.
#   BC2CPP_RPG_DIR=dir   an existing rpg-maker-clone checkout instead of the pinned one
#   BC2CPP_RUBY=ruby     the Ruby 4.0 to run the world with (default: ruby on PATH)
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
ruby_bin=${BC2CPP_RUBY:-ruby}
command -v "$ruby_bin" >/dev/null || { echo "SKIP bc2cpp response-file: no $ruby_bin"; exit 0; }
"$ruby_bin" -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp response-file: needs Ruby 4.0, have $("$ruby_bin" -e 'print RUBY_VERSION')"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp response-file: rake not installed"; exit 0; }

bc2cpp_fetch; status=$?
[ "$status" = 2 ] && exit 0 # a fetch failure is a network fault, not a result (fetch.sh printed why)
[ "$status" = 0 ] || exit 1
echo "bc2cpp: this tree, world rpg-maker-clone $(git -C "$bc2cpp_root" rev-parse --short HEAD), mruby fork $(git -C "$bc2cpp_root/3rd/mruby" rev-parse --short HEAD)"
tree=$root/bc2cpp
export BC2CPP_TREE_ROOT=$tree BC2CPP_WORLD_ROOT=$bc2cpp_root

mkdir -p build/bc2cpp
jobs=$(nproc 2>/dev/null || echo 4)
# The world's host mrbc, from the optcarrot probe's build config (as run_pathb_borrowck.sh does).
(cd "$bc2cpp_root/3rd/mruby" && env -u LD MRUBY_CONFIG="$tree/tools/optcarrot_probe/mruby_build_config.rb" \
  rake -j"$jobs") > build/bc2cpp/mrbc.log 2>&1 ||
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp response-file: building the probe mrbc failed"; exit 1; }

# The cases, one command line each (shell words, relative to this tree).
corpus=tests/nfcc/response
cases=build/bc2cpp/response_file.cases
{
  for f in $(ls "$corpus" | LC_ALL=C sort); do
    echo "@$corpus/$f"
  done
  echo "-c x.c @$corpus/ws.rsp -o @$corpus/quotes.rsp @$corpus/backslash.rsp @$corpus/crlf.rsp @$corpus/empty.rsp @$corpus/emptyquotes.rsp @$corpus/nest1.rsp @$corpus/unterm.rsp @$corpus/tailbs.rsp @$corpus/utf8.rsp @$corpus/dbl.rsp @$corpus/nope.rsp @$corpus/dir.rsp '' @ -x"
  echo "@$corpus/loop.rsp"
} > "$cases"

log=build/bc2cpp/response_file.log
(env -u LD "$ruby_bin" "$tree/tools/script_world/compiled_run.rb" --script scripts/response-file.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" \
  --bench "@$corpus/ws.rsp" --repeat 1 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp response-file: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp response-file: the cases differ"; exit 1; }
echo "PASS bc2cpp response-file"

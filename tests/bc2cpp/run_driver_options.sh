#!/usr/bin/env bash
# bc2cpp world: scripts/driver-options.rb, nfcc's option parsing (parse_wp_option so far), compiled by bc2cpp as a closed
# world (the script-world build kind, bc2cpp/tools/script_world/) on the mruby fork of the pinned rpg-maker-clone
# (tests/bc2cpp/fetch.sh). For each -Wp option of tests/nfcc/wp-options.txt, the stdout, stderr and exit status of the
# sealed executable must be byte-identical to the mruby interpreter's and to CRuby's on the same script. The bash side of
# the same check is tests/nfcc/wp-option.sh.
# Needs Ruby 4.0 with the Gemfile's gems (prism 1.9.0, rbs 4.0.0, rake 13.4.2), a C/C++ compiler, bison and make.
# Without them it prints a skip.
#   BC2CPP_RPG_DIR=dir   an existing rpg-maker-clone checkout instead of the pinned one
#   BC2CPP_RUBY=ruby     the Ruby 4.0 to run the world with (default: ruby on PATH)
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
ruby_bin=${BC2CPP_RUBY:-ruby}
command -v "$ruby_bin" >/dev/null || { echo "SKIP bc2cpp driver-options: no $ruby_bin"; exit 0; }
"$ruby_bin" -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp driver-options: needs Ruby 4.0, have $("$ruby_bin" -e 'print RUBY_VERSION')"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp driver-options: rake not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp driver-options: building the probe mrbc failed"; exit 1; }

# The cases: one -Wp option per line of tests/nfcc/wp-options.txt, quoted as shell words (the runner reads them so).
cases=build/bc2cpp/driver_options.cases
{
  while IFS= read -r option; do
    case $option in ''|'#'*) continue ;; esac
    printf '%q\n' "$option"
  done < tests/nfcc/wp-options.txt
} > "$cases"

log=build/bc2cpp/driver_options.log
(env -u LD "$ruby_bin" "$tree/tools/script_world/compiled_run.rb" --script scripts/driver-options.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" \
  --bench "-Wp,-MD,dep.d,-MT,tgt" --repeat 1 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp driver-options: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp driver-options: the cases differ"; exit 1; }

# The sealed executable, for nfcc: build/driver-options (nfcc takes -Wp options from it when it exists, else from bash).
compiled=build/bc2cpp/rpg-maker-clone/3rd/mruby/build/scriptcompiled/bin/script
[ -x "$compiled" ] || { echo "FAIL bc2cpp driver-options: no executable at $compiled"; exit 1; }
install -m 755 "$compiled" build/driver-options
echo "installed build/driver-options"
echo "PASS bc2cpp driver-options"

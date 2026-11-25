# Shared by the nfcxx leaf worlds (tests/bc2cpp/run_nfcxx_*.sh): one of nfcxx's own Ruby driver scripts, built as a bc2cpp
# script world (bc2cpp/tools/script_world/compiled_run.rb) on the pinned world (tests/bc2cpp/fetch.sh). The harness builds the
# script interpreted and sealed, and checks that both give the same stdout, stderr and exit status over every case.
# Source this file from a runner that has already cd'd to the repository root.
#
#   leaf_prepare           fetch the world, build its probe mrbc, install the Gemfile's gems (prism 1.9.0, rbs 4.0.0)
#   leaf_world OUT SRC     write OUT: a prelude (mruby has no Kernel#warn), SRC without its `if $PROGRAM_NAME == __FILE__`
#                          block, then the tail the runner appends; the tail is the script's final statements
#   leaf_run NAME WORLD TAIL ENTRY CASES
#                          run the harness on the cases (no timing); the log is build/bc2cpp/NAME.log
#
# Returns 2 from leaf_prepare when the world cannot be fetched (a network fault, not a result), like the other worlds.

leaf_prepare() {
  . tests/bc2cpp/fetch.sh
  bc2cpp_fetch; local status=$?
  [ "$status" = 2 ] && return 2 # a fetch failure is a network fault, not a result (fetch.sh printed why)
  [ "$status" = 0 ] || return 1
  export BC2CPP_TREE_ROOT=$PWD/bc2cpp BC2CPP_WORLD_ROOT=$bc2cpp_root
  leaf_root=$PWD
  mkdir -p build/bc2cpp
  local jobs; jobs=$(nproc 2>/dev/null || echo 4)
  (cd "$bc2cpp_root/3rd/mruby" && env -u LD MRUBY_CONFIG="$BC2CPP_TREE_ROOT/tools/optcarrot_probe/mruby_build_config.rb" \
    rake -j"$jobs") > build/bc2cpp/mrbc.log 2>&1 || { tail -20 build/bc2cpp/mrbc.log; return 1; }
  MRBC=$bc2cpp_root/3rd/mruby/bin/mrbc
  export MRBC
  BUNDLE_GEMFILE=$leaf_root/Gemfile bundle install --quiet >/dev/null 2>&1 || { echo "leaf: bundle install failed" >&2; return 1; }
  export BUNDLE_GEMFILE=$leaf_root/Gemfile
}

leaf_world() { # leaf_world OUT SRC
  local out=$1 src=$2
  {
    cat <<'PRELUDE'
module Kernel
  # mruby has no Kernel#warn; CRuby prints the message and returns nil.
  def warn(message)
    $stderr.write(message.to_s + "\n")
    nil
  end
end
PRELUDE
    sed '/^if \$PROGRAM_NAME == __FILE__$/,$d' "$src"
  } > "$out"
}

leaf_run() { # leaf_run NAME WORLD TAIL ENTRY CASES
  local name=$1 world=$2 tail=$3 entry=$4 cases=$5
  env -u LD timeout 3000 bundle exec ruby bc2cpp/tools/script_world/compiled_run.rb --script "$world" --tail "$tail" \
    --entry "$entry" --cases "$cases" --chdir "$leaf_root" > "build/bc2cpp/$name.log" 2>&1
  local status=$?
  grep -v '^\s*from ' "build/bc2cpp/$name.log" | tail -n 12
  return $status
}

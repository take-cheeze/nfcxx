#!/bin/bash
# Differential test: scripts/setup-bc2cpp.rb against the bash it replaced (oracle.sh here, which sources the world's fetch.sh
# copied into the sandbox). See ../lib.sh. The sandbox has a world (world/3rd/mruby) and a checkout (rpg/3rd/mruby), and
# the checkout's submodule script (build/bc2cpp/rpg-maker-clone/scripts/checkout-submodules.bash) logs its SKIP_SUBMODULES.
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/../lib.sh"
NAME=bc2cpp

prep() {
  local rc="$1/root/build/bc2cpp/rpg-maker-clone"
  mkdir -p "$rc/scripts" "$1/world/3rd/mruby" "$1/rpg/3rd/mruby"
  cat > "$rc/scripts/checkout-submodules.bash" <<'EOF'
#!/bin/bash
echo "SUBMODULES ${SKIP_SUBMODULES-unset}" >> "$RB_STUB_LOG"
EOF
  chmod +x "$rc/scripts/checkout-submodules.bash"
}

rbm_cases <<'EOF'
world root|BC2CPP_WORLD_ROOT=@SB@/world
rpg dir|BC2CPP_RPG_DIR=@SB@/rpg
fetch the world|
fetch the world at the pin|RB_STUB_GIT_HEAD=f2cc1cad69a4058951e9669e90a2b7e0650a334e
fetch fails|RB_STUB_GIT_FAIL=fetch
submodules fail|RB_STUB_GIT_FAIL=submodule
full checkout|BC2CPP_WORLD_FULL=1
rake fails|BC2CPP_WORLD_ROOT=@SB@/world RB_STUB_RAKE_FAIL=2
jobs, backend and runner|BC2CPP_WORLD_ROOT=@SB@/world BC2CPP_BUILD_JOBS=3 NFCXX_BACKEND=cil BC2CPP_RUNNER_CXX=@SB@/cxx
build dir|BC2CPP_WORLD_ROOT=@SB@/world BC2CPP_RUNNER_BUILD_DIR=@SB@/out
EOF
rbm_finish

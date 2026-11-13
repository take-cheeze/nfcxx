#!/usr/bin/env bash
# The world bc2cpp (bc2cpp/, docs/notes/bc2cpp-migration.md) compiles: a shallow checkout of rpg-maker-clone at the pin
# below, in build/bc2cpp/rpg-maker-clone. Sourced by the world scripts (tests/bc2cpp/run_*.sh, tests/bc2cpp/world.sh);
# sets $bc2cpp_root. Re-running reuses the checkout and only moves it when the pin changes.
# rpg-maker-clone takes bc2cpp from its 3rd/nfcxx submodule (tools/bc2cpp etc. are symlinks into it), so that path is
# pointed at this checkout: the world's own commands (`ruby scripts/bc2cpp/...`) then run the bc2cpp under test.
#   BC2CPP_RPG_DIR=dir      use an existing rpg-maker-clone checkout instead (its own commit and submodules are kept)
#   BC2CPP_WORLD_FULL=1     every submodule the fixture checks read (the world's scripts/checkout-submodules.bash),
#                           not only the ones the optcarrot world needs
# Bumping the pin is a one-line change here; the mruby fork commit (3rd/mruby) comes with it.
rpg_pin=1b2fd7cce5f2201821f47bde66524ed3dbadb269 # take-cheeze/rpg-maker-clone master (Game::State? / Game::Rng? nilable constructor declarations, #3258)
rpg_url=https://github.com/take-cheeze/rpg-maker-clone
# The submodules the optcarrot world reads: the mruby fork, the gems of the probe's closed world and optcarrot itself.
bc2cpp_submodules=(3rd/mruby 3rd/mruby-onig-regexp 3rd/mruby-stringio 3rd/mruby-marshal 3rd/optcarrot)
# What the fixture checks leave out (as rpg-maker-clone's own bc2cpp jobs did), and 3rd/nfcxx, which is this checkout.
bc2cpp_skip_full="3rd/effekseer 3rd/gflags 3rd/ng-log 3rd/inicpp 3rd/nfcxx"

bc2cpp_fetch() {
  if [ -n "${BC2CPP_RPG_DIR:-}" ]; then
    bc2cpp_root=$(cd "$BC2CPP_RPG_DIR" && pwd) || return 1
    return 0
  fi
  bc2cpp_root=$root/build/bc2cpp/rpg-maker-clone
  if [ ! -d "$bc2cpp_root/.git" ]; then
    mkdir -p "$bc2cpp_root" && git -C "$bc2cpp_root" init -q && git -C "$bc2cpp_root" remote add origin "$rpg_url" || return 1
  fi
  if [ "$(git -C "$bc2cpp_root" rev-parse -q --verify HEAD 2>/dev/null)" != "$rpg_pin" ]; then
    # A symlinked 3rd/nfcxx from an earlier run is not the world's; git refuses to fetch or check out over it, and the
    # checkout puts the gitlink back.
    rm -f "$bc2cpp_root/3rd/nfcxx"
    git -C "$bc2cpp_root" fetch -q --depth 1 origin "$rpg_pin" || { echo "bc2cpp: fetching $rpg_url $rpg_pin failed"; return 2; }
    git -C "$bc2cpp_root" checkout -q -f "$rpg_pin" || return 1
  fi
  # A shallow submodule fetch of the exact gitlink; GitHub serves a commit by hash.
  if [ "${BC2CPP_WORLD_FULL:-}" = 1 ]; then
    (cd "$bc2cpp_root" && SKIP_SUBMODULES="$bc2cpp_skip_full" ./scripts/checkout-submodules.bash) >/dev/null ||
      { echo "bc2cpp: fetching the submodules failed"; return 2; }
  else
    git -C "$bc2cpp_root" submodule update -q --init --depth 1 --force "${bc2cpp_submodules[@]}" ||
      { echo "bc2cpp: fetching the submodules failed"; return 2; }
  fi
  if [ ! -L "$bc2cpp_root/3rd/nfcxx" ]; then
    rm -rf "$bc2cpp_root/3rd/nfcxx" && ln -s "$root" "$bc2cpp_root/3rd/nfcxx" || return 1
  fi
}

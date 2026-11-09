#!/usr/bin/env bash
# The world bc2cpp (bc2cpp/, docs/notes/bc2cpp-migration.md) compiles: a shallow checkout of rpg-maker-clone at the pin
# below, with only the submodules the worlds read, in build/bc2cpp/rpg-maker-clone. Sourced by the world scripts
# (tests/bc2cpp/run_*.sh); sets $bc2cpp_root. Re-running reuses the checkout and only moves it when the pin changes.
# The pin needs rpg-maker-clone's tools/bc2cpp_tree.rb, which lets its build take bc2cpp from BC2CPP_TREE_ROOT.
#   BC2CPP_RPG_DIR=dir   use an existing rpg-maker-clone checkout instead (its own commit and submodules are kept)
# Bumping the pin is a one-line change here; the mruby fork commit (3rd/mruby) comes with it.
rpg_pin=17fc04f434070df63e915636a75fc2ea37d07cca # take-cheeze/rpg-maker-clone#3203 (bc2cpp's tree and world roots)
rpg_url=https://github.com/take-cheeze/rpg-maker-clone
# The submodules the worlds read: the mruby fork, the gems of the probe's closed world and optcarrot itself.
bc2cpp_submodules=(3rd/mruby 3rd/mruby-onig-regexp 3rd/mruby-stringio 3rd/mruby-marshal 3rd/optcarrot)

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
    git -C "$bc2cpp_root" fetch -q --depth 1 origin "$rpg_pin" || { echo "bc2cpp: fetching $rpg_url $rpg_pin failed"; return 2; }
    git -C "$bc2cpp_root" checkout -q -f "$rpg_pin" || return 1
  fi
  # A shallow submodule fetch of the exact gitlink; GitHub serves a commit by hash.
  git -C "$bc2cpp_root" submodule update -q --init --depth 1 --force "${bc2cpp_submodules[@]}" ||
    { echo "bc2cpp: fetching the submodules failed"; return 2; }
}

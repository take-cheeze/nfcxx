# frozen_string_literal: true

# WORLD_ROOT: bc2cpp's two roots.
# - BC2CPP_TREE_ROOT is the checkout bc2cpp's own files are in: tools/bc2cpp, scripts/bc2cpp, tools/optcarrot_probe.
# - BC2CPP_WORLD_ROOT is the repository whose program it compiles: 3rd/mruby, the engine gems, build_config.rb and
#   sig/bc2cpp.
# The world is BC2CPP_WORLD_ROOT when set. Otherwise it is the nearest directory at or above the tree that holds a
# build_config.rb and a 3rd/mruby: the tree itself in rpg-maker-clone, and rpg-maker-clone when bc2cpp is its
# 3rd/nfcxx submodule (nfcxx's docs/notes/bc2cpp-migration.md). With neither, it is the tree. Read once at load, so
# a cached scan never reads ENV (ScanCache).
BC2CPP_TREE_ROOT = File.expand_path('../..', __dir__)
BC2CPP_WORLD_ROOT = if (world = ENV.fetch('BC2CPP_WORLD_ROOT', nil))
                      File.expand_path(world)
                    else
                      dir = BC2CPP_TREE_ROOT
                      dir = File.dirname(dir) until File.file?(File.join(dir, 'build_config.rb')) &&
                                                    File.directory?(File.join(dir, '3rd/mruby')) || dir == '/'
                      dir == '/' ? BC2CPP_TREE_ROOT : dir
                    end

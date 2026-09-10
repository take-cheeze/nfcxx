# Single source of truth for every bc2cpp-generated gem's own target
# owners and OUT_SYMBOL -- both mruby-lcf-compiled/mrbgem.rake and
# mruby-rpg2k-compiled/mrbgem.rake `require` this instead of hardcoding
# each other's owner list (real drift risk otherwise) or `target_owners`
# duplicated between files.
#
# Also what makes cross-gem devirtualization (docs/adr/0139's own
# follow-up) possible at all: each mrbgem.rake computes its own
# OTHER_OWNERS/OTHER_DECLS_HEADER from every *other* entry here, so a
# devirtualized call from one compiled gem into another's target class can
# reference a real, externally-linked _impl declared via that other gem's
# own *_decls.h (see bc2cpp.rb's own emit_decls_header comment) -- without
# either gem's own bc2cpp codegen step needing to read the other's
# generated output (that would be a circular Rake dependency; only the
# final C++ compile of register.cxx needs both gems' generated files to
# already exist, which mrbgem.rake wires as a `file` dependency, not this).
BC2CPP_COMPILED_GEMS = {
  'mruby-lcf-compiled' => {
    owners: %w[LCF::File LCF::Database LCF::MapTree LCF::MapUnit LCF::SaveData],
    out_symbol: 'lcf_compiled',
  },
  'mruby-rpg2k-compiled' => {
    owners: %w[Game::Picture],
    out_symbol: 'rpg2k_compiled',
  },
}.freeze

# mruby's own core (3rd/mruby/src/*.c) and every core mrbgem
# build_config.rb actually turns on (`conf.gem core: 'mruby-xxx'`) --
# real, closed-world NATIVE_SRCS input alongside mruby-rgss/src/*.cxx.
# Without this, bc2cpp's registry stays unsound with respect to mruby's
# *own* C-defined methods, not just RGSS's -- confirmed for real:
# mruby 4.0 registers most of its own core methods (Array/Hash/String/
# Kernel/Numeric/...) through a declarative ROM method-table macro
# (`MRB_MT_ENTRY(fn, MRB_SYM(name), flags)`, e.g.
# 3rd/mruby/src/symbol.c's own `symbol_rom_entries` -- the exact source of
# the earlier-caught Game::Shop#name bug, Symbol#name/Class#name being two
# of the names that table form registers), a wholly different native-
# registration idiom than mruby-rgss's own literal-string
# `mrb_define_method(M, klass, "name", ...)` calls -- see bc2cpp.rb's own
# extract_native_method_names comment for both patterns it recognizes.
# Scanning the real project closed world with this list added (on top of
# mruby-rgss/src/*.cxx) found 8 further real collisions beyond the 6 RGSS
# ones already fixed (:<<, :delete, :print, :puts, :resume, :start,
# :ungetbyte, :write) -- e.g. LCF::Array1D#delete vs. core Array#delete/
# Hash#delete, exactly the same unsoundness class, just against mruby's
# own standard library instead of RGSS.
#
# The core mrbgem list mirrors build_config.rb's own `conf.gem core:
# 'mruby-xxx'` calls exactly -- keep it in sync if that list changes.
# `mruby-fiber`'s Fiber#resume/#start don't collide with either compiled
# gem's own current target classes, but a class outside today's two
# compiled gems already collided with them (RPG2k::Scene::Menu/Battle),
# which is exactly the kind of program-wide fact only a real closed-world
# scan like this can catch.
def core_native_srcs(mruby_root)
  Dir["#{mruby_root}/src/*.c"] +
    Dir["#{mruby_root}/mrbgems/mruby-{array-ext,hash-ext,enum-ext,io,dir," \
        "numeric-ext,range-ext,fiber,exit,sprintf,kernel-ext,random,math,time,bigint}/**/*.c"]
end

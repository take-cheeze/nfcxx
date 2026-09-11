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
    # Game::EnemyAction (docs/adr/0139) added alongside the original
    # Game::Picture target -- both real mruby-rpg2k classes, so both live
    # in this one gem rather than a separate one per class. Game::Screen
    # and RPG2k::Window (docs/adr/0139's own array-literal/LOADSELF/MUL/
    # AREF opcode follow-up) join them here too. Screen's own #initialize
    # takes zero arguments and compiles clean, so it's the first shipped
    # target whose ivars actually get embedded into a real RData struct
    # (see register.cxx's own MRB_SET_INSTANCE_TT comment); Window's own
    # #initialize stays interpreted (optional args), same as Picture's.
    # Game::Transition (docs/adr/0139's own follow-up) is the second real
    # target with an embedding #initialize -- purely mandatory-arity (5
    # required args, no opts), the same shape as Screen's. Game::Actor
    # (docs/adr/0139's own GETIDX/SETIDX/GETGV opcode follow-up) is the
    # biggest real target at that time -- 76 of its own real bytecode-
    # defined methods (up from 75 -- #set_exp, unblocked by SUBILV, a
    # Game::Party-round opcode, see below) across mruby-rpg2k/mrblib/
    # game.rb and game/battle_support.rb's own reopening of the class; its
    # own #initialize stays interpreted (BLOCK/SENDB/GETIDX), same shape as
    # Picture's/Window's, so its own provably-Fixnum ivars stay unembedded
    # too -- confirmed for real after fixing a real, live memory-safety bug
    # in bc2cpp.rb's own drop_unsafe_embeddings (arity-only, not compile-
    # clean-checked, had let them through anyway; see register.cxx's own
    # top comment for the real fix and its own confirmed-safe
    # re-verification).
    #
    # Game::Party (docs/adr/0139's own Game::Party follow-up) -- party-wide
    # item/skill usability rules, equip/swap logic, skill damage formulas,
    # state/status application, battle placement. 85 of its own 128 real
    # bytecode-defined methods, needing six more new opcodes (NOP, ADDILV/
    # SUBILV, RANGE_INC/RANGE_EXC, RETURN_BLK -- see bc2cpp.rb's own
    # compile_insn comments on each). Its own #initialize stays interpreted
    # (two optional arguments, `ids = nil, roster = nil`), same shape as
    # Picture's/Window's/Actor's, so its own two provably-Fixnum ivars
    # (@gold, @revision) stay unembedded too.
    #
    # RPG2k::Scene::MapViewer (docs/adr/0139's own GETIDX0 opcode
    # follow-up) is the F9 debug-menu map overview/editor scene,
    # mruby-rpg2k/mrblib/scene/map_viewer.rb -- 34 of its own 42 real
    # methods, the same unembedded shape as Picture/Window/Actor (its own
    # #initialize takes only optional keyword args).
    #
    # Game::Battle (docs/adr/0139's own Game::Battle follow-up,
    # mruby-rpg2k/mrblib/game/battle.rb) -- the headless turn-based/gauge
    # combat-resolution engine (turn order, command resolution, hit/damage/
    # state-infliction formulas, enemy AI action selection). 75 of its own
    # 141 real bytecode-defined methods compile clean, needing no new
    # opcode work at all -- every gap here is either #initialize's own
    # (and 14 other real methods') non-mandatory arguments (the same
    # calling-convention gap as Picture's/Window's/Actor's/Party's/
    # MapViewer's own #initialize) or a genuine Ruby block (BLOCK/SENDB/
    # SSENDB), the same established out-of-scope shape those classes'
    # own block-using methods already document. Its own #initialize stays
    # interpreted, so its two provably-Fixnum ivars (@battle_type,
    # @rounds) stay unembedded too, same shape as every other
    # non-embedding target above.
    #
    # RPG2k::Scene::ItemMenu (docs/adr/0139's own RANGE_INC/RANGE_EXC
    # opcode follow-up, mruby-rpg2k/mrblib/scene/item_menu.rb -- this class
    # lives in mruby-rpg2k's own mrblib, same closed_world_srcs glob as
    # every other owner in this gem, so it belongs here rather than a new
    # gem) -- the field/battle item-use menu. 41 of its own 47 real
    # bytecode-defined methods compile clean; #initialize stays interpreted
    # (a real `super parent` call -- SUPER, out of this compiler's opcode
    # scope), so its own provably-Fixnum/Symbol ivars stay unembedded too,
    # same shape as Picture's/Window's/Actor's.
    #
    # RPG2k::Scene::SkillMenu (mruby-rpg2k/mrblib/scene/skill_menu.rb) is
    # the field/battle skill-use menu -- 39 of its own 46 real
    # bytecode-defined methods, needing no new opcode work at all. Its own
    # #initialize (`actor_index = 0`, one optional argument) doesn't
    # compile, so -- same unembedded shape as Picture/Window/Actor/Party/
    # MapViewer above -- drop_unsafe_embeddings refuses to embed any of its
    # 6 real provably-Fixnum ivars (@caster_index, @skill_index, @top_row,
    # @arrow_anim, @target_index, @teleport_index). The 7 methods that stay
    # interpreted are all genuinely out of this prototype's scope, not a
    # missing opcode: #load_face_bitmap/#play_skill_sound_effect each have
    # a real `rescue` clause (RESCUE/RAISEIF/EXCEPT), and
    # #draw_skill_rows/#build_target_window/#teleport_targets/
    # #build_teleport_window each use a real Ruby block (BLOCK/SENDB).
    #
    # RPG2k::Scene::MapViewer's own sibling, RPG2k::Scene::DebugMenu
    # (mruby-rpg2k/mrblib/scene/debug_menu.rb) -- the F9 debug menu itself
    # (switch/variable block-and-row editing, plus the Map/Chipset/
    # Animation tool pages). 33 of its own 39 real bytecode-defined
    # methods compile clean, needing no new opcode work at all.
    # #initialize (`super parent` as its own first statement, then two
    # purely-mandatory arguments) is the first target whose own
    # #initialize is blocked by a real `super` call (OP_SUPER) rather than
    # non-mandatory arity, a Ruby block, or an exception clause -- a
    # genuine class-hierarchy method-dispatch feature, not a narrow
    # single-opcode mechanical translation, so it stays out of scope the
    # same way BLOCK/SENDB and RESCUE/RAISEIF/EXCEPT already do;
    # drop_unsafe_embeddings correctly refuses to embed any of this
    # class's own provably-typed ivars as a result. 5 more stay
    # interpreted for the same established out-of-scope shapes: #max_id
    # and #refresh_switch_or_variable each use two real Ruby blocks
    # (Enumerable#each, BLOCK/SENDB); #digits_of uses one
    # (Integer#downto); #editor_value uses one (Enumerable#reduce); and
    # #open_map_viewer has a real `begin ... rescue StandardError => e
    # ... end` (RESCUE/RAISEIF/EXCEPT).
    #
    # RPG2k::Scene::EquipMenu (docs/adr/0139's own follow-up,
    # mruby-rpg2k/mrblib/scene/equip_menu.rb) -- the field equip screen:
    # weapon/armor/accessory slot selection, a two-column bag-item
    # candidate grid, per-stat before/after deltas. 29 of its own 36 real
    # bytecode-defined methods compile clean, needing no new opcode work at
    # all (every gap here is #initialize's own non-mandatory
    # `actor_index = 0` argument, or a genuine Ruby block -- each_with_index/
    # reduce/Integer#times -- confirmed against each one's own generated
    # #error line, not assumed). #initialize stays interpreted, so its own
    # provably-Fixnum/Symbol ivars (@actor_index/@slot_index/@cand_index/
    # @cand_top/@arrow_anim/@mode) stay unembedded too, same shape as
    # Picture's/Window's/Actor's/ItemMenu's.
    #
    # RPG2k::Scene::Menu (docs/adr/0139's own follow-up,
    # mruby-rpg2k/mrblib/scene/menu.rb) -- the field main menu (top-level
    # party navigation hub: Item/Skill/Equip/Status/Save/Quit). 28 of its
    # own 35 real bytecode-defined methods compile clean, needing no new
    # opcode work: #initialize (`super parent`, SUPER) and
    # #load_face_bitmap (a real `rescue StandardError` clause) match
    # ItemMenu's own pair of gaps exactly (both classes share the
    # #load_face_bitmap name -- POLY, never MONO, at any call site);
    # #build_commands/#build_windows/#draw_command_labels/
    # #build_end_game_confirm_windows all end in a genuine Ruby block
    # (BLOCK/SENDB); #draw_status_row's own `line = ->(n) { ... }` hits a
    # LAMBDA opcode (checked, not assumed) but is the same permanently-
    # out-of-scope closure-creation gap as a block, just different
    # syntax, so it was left interpreted rather than chased. Its own
    # #initialize never compiles, so its provably-typed ivars stay
    # unembedded too, same shape as Picture's/Window's/Actor's/Battle's/
    # ItemMenu's.
    owners: %w[Game::Picture Game::EnemyAction Game::Screen RPG2k::Window
               Game::Transition Game::Actor Game::Party
               RPG2k::Scene::MapViewer Game::Battle RPG2k::Scene::ItemMenu
               RPG2k::Scene::SkillMenu RPG2k::Scene::DebugMenu
               RPG2k::Scene::EquipMenu RPG2k::Scene::Menu],
    out_symbol: 'rpg2k_compiled',
  },
  'mruby-rgss-compiled' => {
    # RGSS::Sprite (docs/adr/0139): the JMPNIL/LOADL opcode work this same
    # ADR added gets all 17 of its real bytecode-defined accessor methods
    # (mruby-rgss/mrblib/lib.rb's own reopening of the natively-defined
    # Sprite class) to 100% clean compilation.
    owners: %w[RGSS::Sprite],
    out_symbol: 'rgss_compiled',
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

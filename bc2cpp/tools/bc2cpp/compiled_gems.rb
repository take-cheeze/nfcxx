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
    #
    # Game::State (mruby-rpg2k/mrblib/game.rb, reopened by mruby-rpg2k/
    # mrblib/game/lsd_io.rb) -- the whole-program root save/session object
    # (party, switches, variables, map position, pictures, both timers, the
    # message window config, screen-transition defaults, vehicle placement,
    # and the Marshal/`.lsd` (de)serialisers). 23 of its own 32 real
    # bytecode-defined methods compile clean, needing no new opcode work.
    # #initialize takes 4 purely mandatory arguments -- the third target
    # after Game::Screen/Game::Transition above whose own #initialize
    # compiles, and by far the largest: 13 of its own ivars (all provably
    # Fixnum) get real RData struct embedding. See register.cxx's own top
    # comment for the full gap breakdown of the other 9 (3 non-mandatory
    # arity, 4 genuine Ruby blocks, 2 that combine a block with a real
    # `rescue StandardError` clause).
    #
    # RPG2k::Scene::StatusMenu (mruby-rpg2k/mrblib/scene/status_menu.rb) --
    # the field per-character status detail screen (stats, equipped gear,
    # and EXP progress for one selected party member, drawn across five
    # windows). 13 of its own 21 real bytecode-defined methods compile
    # clean, needing no new opcode work at all. #initialize
    # (`actor_index = 0`, one optional argument, plus a `super parent`
    # call) stays interpreted, the
    # same non-mandatory-arity gap as Picture/Window/Actor/Party/MapViewer/
    # SkillMenu's own #initialize above, so drop_unsafe_embeddings refuses
    # to embed this class's own one real provably-Fixnum ivar (@actor_index)
    # -- confirmed directly against the real generated output: StatusMenu
    # does not appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic. The 7 other methods that stay interpreted are all
    # genuinely out of this prototype's scope, not a missing opcode,
    # confirmed against each one's own real generated #error marker:
    # #update and #dispose each call `windows.each { |w| ... }` (a real
    # Ruby block, BLOCK/SENDB); #draw_actor_panel, #draw_params and
    # #draw_equipment each use `.each_with_index do |...| ... end` (also
    # BLOCK/SENDB); #draw_value_row has one optional argument
    # (`can_knockout = nil`, the same non-mandatory-arity gap as
    # #initialize); and #load_face_bitmap has a real
    # `rescue StandardError => e` clause (RESCUE/RAISEIF/EXCEPT), the same
    # established shape SkillMenu's own #load_face_bitmap already
    # documents above.
    #
    # Game::MoveRoute (docs/adr/0139's own follow-up, mruby-rpg2k/mrblib/
    # game.rb) -- the RPG2000 "Set Move Route" event-command engine: a
    # character's programmed queue of move/turn/wait/jump/effect
    # sub-commands, plus its repeat/skip-if-blocked flags. 18 of its own 19
    # real bytecode-defined methods compile clean, needing no new opcode
    # work at all. #initialize (`commands, repeat: true, skippable: false`)
    # stays interpreted -- real keyword arguments, the same non-mandatory-
    # arguments gap as every other unembedded target above, just via
    # keyword syntax rather than optional positional args this time
    # (confirmed against its own generated #error line). Two more real
    # methods, .from_page and .same_route?, are singleton (`def self.`)
    # methods, structurally invisible to bc2cpp's own build_registry (its
    # CLASS/MODULE/TDEF walk never recognizes an SCLASS-opened body the way
    # it does a CLASS/MODULE one, so a `def self.foo` method's own TDEF is
    # never reached at all) -- an existing, program-wide gap, not new here,
    # just the first target whose own singleton methods carry real logic
    # worth naming. #initialize never compiles, so its one provably-Fixnum
    # ivar (@index) stays unembedded too, same shape as every other
    # non-embedding target above.
    #
    # This round's own full-sweep re-check also caught and fixed a real,
    # live correctness bug in bc2cpp.rb itself, not this gem's own owners:
    # extract_native_method_names was missing mruby core's own
    # MRB_SYM_Q/MRB_SYM_B/MRB_SYM_E macros ("name?"/"name!"/"name="),
    # leaving ~75 real native predicate/bang/setter names invisible to the
    # whole-program registry -- surfaced as Game::MoveRoute#empty? getting
    # wrongly devirtualized into calling itself. See bc2cpp.rb's own
    # comment and register.cxx's own top comment for the full story.
    #
    # RPG2k::Scene::ChipsetEditor (docs/adr/0139's own follow-up,
    # mruby-rpg2k/mrblib/scene/chipset_editor.rb) -- the F9 debug menu's
    # Chipset page: a Lower/Upper tile-passability grid editor. 17 of its
    # own 20 real bytecode-defined methods compile clean, needing no new
    # opcode work at all. #initialize (a `quit_on_close:` keyword argument
    # plus a real `super parent` call) matches ItemMenu's/DebugMenu's/
    # Menu's own SUPER gap, just paired with non-mandatory arity too;
    # #save_to_disk has a real `rescue StandardError => e` clause
    # (RESCUE/RAISEIF/EXCEPT), the same established gap as ItemMenu's own
    # #load_face_bitmap; #draw_grid ends in a genuine Ruby block
    # (`(0...cell_count).each do |i| ... end`, BLOCK/SENDB). #initialize
    # never compiles, so its own provably-typed ivars (@chipset_id/@idx,
    # Fixnum; @tab, Symbol) stay unembedded too, same shape as Picture's/
    # Window's/Actor's/Battle's/ItemMenu's/EquipMenu's/Menu's.
    #
    # RPG2k::Scene::Base (docs/adr/0139's own follow-up, mruby-rpg2k/
    # mrblib/scene/base.rb, reopened by mruby-rpg2k/mrblib/scene/
    # battle_support.rb) -- the common superclass every other
    # RPG2k::Scene::* class inherits from. 17 of its own 29 real
    # bytecode-defined methods compile clean, needing no new opcode work
    # at all. #initialize (`def initialize parent`) compiles clean -- pure
    # mandatory arity, and (being the root of the hierarchy) no `super`
    # call to block it, unlike every subclass built on top of it; its own
    # 3 ivars are all opaque object references, never provably Fixnum, so
    # it does not appear in bc2cpp's own "classes needing
    # MRB_SET_INSTANCE_TT" diagnostic and stays a plain, non-embedding
    # registration. The 12 other methods that stay interpreted are all
    # genuinely out of this prototype's scope, not a missing opcode: 4
    # have a real `rescue` clause, 3 have a non-mandatory argument, 4 call
    # a real Ruby block, and 1 (#play_animation_se) combines a block with
    # its own `rescue StandardError` clause -- see register.cxx's own
    # comment for the full per-method breakdown. Notably, since
    # RPG2k::Scene::ItemMenu, RPG2k::Scene::DebugMenu and
    # RPG2k::Scene::Menu's own #initialize are each blocked purely by
    # their own `super parent` call into this now-clean-compiling
    # #initialize (no other non-mandatory arguments), real SUPER opcode
    # support could unlock all three in a future round -- out of scope
    # here (whole-program coordination across every already-shipped
    # scene class's own registration block), but flagged for later.
    #
    # Game::Character (docs/adr/0139's own follow-up, mruby-rpg2k/mrblib/
    # game.rb) -- the shared moving-on-map-entity state/movement protocol
    # Game::Vehicle and the player/event drivers build on (position,
    # facing, move-speed/frequency, jump/diagonal-move geometry, the
    # move-route Face/Turn sub-command helpers). Not itself subclassed
    # anywhere in this codebase -- Game::Vehicle is deliberately plain
    # data, not a Character -- and every real construction site goes
    # through the plain constructor. 14 of its own 16 real
    # bytecode-defined methods compile clean, needing no new opcode work
    # at all. The 2 gaps are both the same established non-mandatory-
    # arity shape as every other non-embedding target above: #initialize
    # (`x = 0, y = 0, direction = 2`, three optional arguments) and
    # #front_tile (`dir = @direction`, one optional argument reading an
    # ivar as its own default). #initialize never compiling means this
    # class's own provably-typed ivars stay unembedded too -- including
    # @last_move_direction, whose own #move_diagonal site
    # (`@last_move_direction = [horizontal, vertical]`) writes a real
    # Array, not a Fixnum, so even the raw per-ivar EMBED analysis (before
    # this class-level gate) never actually reaches codegen here.
    #
    # This same round also found and fixed a real, live bug in
    # bc2cpp.rb's own IvarLayout.join, the fixed-point per-ivar type-join
    # the whole embedding analysis is built on: a SETIV site whose own
    # value traced to UNKNOWN used to have that contribution silently
    # discarded whenever an earlier-processed site for the same ivar name
    # had already joined in a concrete type, instead of poisoning to
    # UNKNOWN the way a sound join has to. Caught building Game::Character
    # (#move_diagonal's own Array-typed @last_move_direction write was
    # getting silently masked by #initialize's own earlier :fixnum join)
    # but confirmed live and already-shipped elsewhere too: a fresh
    # whole-program diagnostic taken before and after the fix shows
    # Game::Screen losing 11 of its own previously-"embeddable" ivars and
    # Game::State losing one (@map_id) -- both still keep several
    # genuinely-sound embedded ivars each, so neither drops out of
    # "classes needing MRB_SET_INSTANCE_TT" entirely. Every embedded-field
    # SETIV this codegen emits already carries its own runtime
    # `mrb_integer_p` guard (a real TypeError on a non-Integer write,
    # never silent corruption), so this was never the Game::Actor-shaped
    # undefined-behavior class of bug -- it was an over-permissive
    # embedding decision that would have turned a legitimate non-Integer
    # assignment (one the plain interpreter handles fine) into a crash
    # the first time a real game session hit it. See register.cxx's own
    # top comment and docs/adr/0139's own Game::Character follow-up for
    # the full writeup.
    #
    # RPG2k::Scene::SaveLoad (mruby-rpg2k/mrblib/scene/save_load.rb) -- the
    # file-select screen shared by Scene::Menu's own Save command and
    # Scene::Title's Continue entry. 12 of its own 22 real bytecode-defined
    # methods compile clean, needing no new opcode work at all. #initialize
    # (`initialize parent, state, mode`) has a real `super parent` call
    # (SUPER) into RPG2k::Scene::Base, matching ItemMenu's/DebugMenu's/
    # Menu's/ChipsetEditor's own gap, plus its own `(1..SLOT_COUNT).map {
    # |slot| ... }` block (BLOCK/SENDB); #dispose/#update each have their
    # own `&:symbol`-block-pass call (`@slot_windows.each(&:dispose)`/
    # `(&:update)`, SENDB); #draw_arrow_fallback, #initial_index,
    # #build_slot_windows, #refresh_slot_windows and #draw_slot_faces each
    # end in a genuine Ruby block (BLOCK/SENDB); #load_face_bitmap and
    # #slot_timestamp each have a real `rescue` clause (RESCUE/RAISEIF/
    # EXCEPT), the same established gap as ItemMenu's own
    # #load_face_bitmap/ChipsetEditor's own #save_to_disk. #initialize
    # never compiles, so its own provably-typed ivars (@mode, Symbol;
    # @arrow_anim, Fixnum) stay unembedded too, same shape as every other
    # non-embedding target above.
    #
    # RPG2k::Scene::Order (mruby-rpg2k/mrblib/scene/order.rb) -- the field
    # Order screen (RPG2003 main menu -> Order): a pick-and-place party
    # reorder UI, a left (remaining)/right (picked) column pair plus a
    # Confirm/Redo prompt once every member is picked. 12 of its own 16 real
    # bytecode-defined methods compile clean, needing no new opcode work at
    # all. #initialize (`super parent`, SUPER) matches DebugMenu's/Menu's/
    # ChipsetEditor's/SaveLoad's own SUPER gap exactly; the other 3
    # (#build_windows, #refresh_left_window, #refresh_right_window) each use
    # a genuine Ruby block (`each_with_index`, BLOCK/SENDB). #initialize
    # never compiles, so its own provably-typed ivars (@counter/
    # @cursor_index/@confirm_index, Fixnum; @focus, Symbol) stay unembedded
    # too, same shape as every other SUPER-blocked target above.
    #
    # This same round's own adversarial bug hunt across every already-shipped
    # class (not new-class coverage) found a second real, live bug in
    # bc2cpp.rb's own compile_send: a bare `/n=(\d+)/` regex parsing a SEND/
    # SSEND call site's own argument count silently misparsed two other real
    # disassembly shapes instead of rejecting them -- a keyword-argument call
    # site ("n=3|nk=1") had its whole keyword-Hash argument silently dropped,
    # and a splat call site ("n=*") fell through `nil.to_i` to a silently-wrong
    # zero-argument call. Confirmed live in six already-shipped methods:
    # Game::Battle#enemy_basic_action/#enemy_fallback_attack's own
    # `deal_attack(..., charged: charged)` silently dropped `charged:`;
    # Game::Actor#knock_out!/Game::Battle#inflict_state's own
    # `Game::States.prune(ids, table, keep: permanent_states)` silently
    # dropped `keep:`, so a real permanently-protected state could be pruned
    # as if no exemption list existed; Game::Actor#restore_class's own
    # `set_level(@level, preserve_mod: false)` silently called with
    # `preserve_mod: true` instead (a real, load-bearing inversion); and
    # RPG2k::Scene::DebugMenu#play_animation's own call into three real
    # MANDATORY keyword arguments used to silently compile a call that would
    # raise a real ArgumentError at runtime. Unlike this same round's
    # IvarLayout.join fix (caught by a runtime type guard before it could
    # corrupt anything), this bug produced genuinely wrong behavior with no
    # safety net -- the generated C++ compiled and linked clean either way.
    # Fixed at the root: compile_send now recognizes both shapes and refuses
    # to compile either (the established #error-marker fallback every other
    # unmodeled shape already gets). All six affected methods are no longer
    # registered in register.cxx -- see docs/adr/0139's own follow-up for the
    # full writeup and real build/nm -C verification.
    #
    # Game::Shop (mruby-rpg2k/mrblib/game.rb) -- the RPG2000 buy/sell shop-
    # menu backing model: the stocked good list, buy/sell affordability and
    # the 99-item stack cap, half-price selling. 11 of its own 14 real
    # bytecode-defined methods compile clean, needing no new opcode work at
    # all. #initialize (`@goods = (goods || []).select { |id| id && id > 0
    # }`) ends in a genuine Ruby block (BLOCK/SENDB); #buy/#sell
    # (`def buy(id, n = 1)`/`def sell(id, n = 1)`) each have one
    # non-mandatory optional argument -- the same two already-established
    # out-of-scope shapes every earlier round's own gap breakdown already
    # documents. #initialize never compiling means drop_unsafe_embeddings
    # correctly refuses to embed any of this class's own ivars -- confirmed
    # directly against the real generated output: Game::Shop does not
    # appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic, so no MRB_SET_INSTANCE_TT call belongs in its own
    # registration block below, same shape as Game::Picture's/
    # RPG2k::Window's above. A real, concrete instance of the exact
    # Game::Shop#name native-name collision this file's own
    # core_native_srcs comment below already names by analogy
    # (Symbol#name/Class#name, registered via mruby core's own ROM
    # method-table macro): confirmed for real here, not just by analogy --
    # `:name` reports POLY (2 defs: Game::Shop, <native>) in this class's
    # own whole-program registry dump with NATIVE_SRCS set the same way
    # mrbgem.rake always does, so #name correctly stays ordinary
    # mrb_funcall dispatch below, never a direct call into
    # Game__Shop_name_impl from any other compiled call site in the whole
    # program.
    # Game::Map (mruby-rpg2k/mrblib/game.rb, reopened by mruby-rpg2k/mrblib/
    # game/battle_support.rb) -- one loaded map's own tile-layer data:
    # dimensions/chipset id, the lower/upper tile-id layer arrays, and Tile
    # Substitution's own per-layer old_id->new_id rewrite table. 12 of its
    # own 13 real bytecode-defined methods compile clean, needing no new
    # opcode work at all -- the opcode set fourteen rounds of this ADR had
    # already built up already covers every real shape this class's own
    # method bodies use. #substitute_tile is the one gap, confirmed against
    # its own real generated #error line, not assumed: it ends in two real
    # `@substitutions[idx].each { |k, v| ... }`/`rebuilt.each { |k, v| ... }`
    # blocks (BLOCK/SENDB), the same established out-of-scope shape every
    # other block-using method above already documents.
    #
    # #initialize (`initialize id, unit`) compiles clean -- pure mandatory
    # arity (2 required arguments, no super, no block). Checked directly
    # against the exact Game::Actor-shaped embedding bug several follow-ups
    # up, not assumed safe by analogy: this class's own single real
    # construction site (`Game::Map.new id, LCF::MapUnit.new(...)`,
    # mruby-rpg2k/mrblib/main.rb's own #load_map) always goes through it --
    # confirmed by grepping the whole closed world for `Game::Map.new`/
    # `.allocate`/a subclass, finding exactly that one plain `.new` call, no
    # bypass. 2 of its own ivars are real, provably-Fixnum fields on a new
    # `Game__Map_ivars` RData struct: @id (the annotated-fixnum first
    # argument) and @revision (a literal `0` in #initialize, then only ever
    # `+= 1`). @width/@height/@chipset_id (each `unit.<method>`, a method
    # call's return value -- this compiler never traces through an
    # arbitrary call's own return type) and @lower/@upper/@substitutions
    # (Array/Hash literals) all stay UNKNOWN, so they stay on the ordinary
    # dynamic iv_tbl, mixed safely with the two embedded fields on the same
    # object, the same mixed-embedding shape Game::Screen/Game::Transition/
    # Game::State already established. #set_tile/#tile are `private` (a
    # bare `private` mid-class-body in game.rb, in effect through the end
    # of that reopening); #initialize is forced private by mruby's own
    # interpreter (mrb_define_method_raw's own special case for the name,
    # not a source-level `private` call); every other method -- including
    # #sync_layers_to_unit, defined in the *separate* `class Map` reopening
    # in battle_support.rb, which starts its own fresh, default-public
    # visibility scope -- is public.
    #
    # Game::EnemyAi (mruby-rpg2k/mrblib/game/battle_support.rb) -- the
    # outside-world collaborator Game::Battle's own enemy action-pattern
    # logic reads through: skill-table/database lookups, casting-
    # eligibility/effectiveness formulas reused from Game::Party, switch
    # read/write, and the party's own average level. Never a database or
    # game-state owner itself -- every accessor tolerates a partial/absent
    # source. 9 of its own 10 real bytecode-defined methods compile clean,
    # needing no new opcode work at all, including #initialize itself (2
    # purely mandatory arguments, `db, state`, no super, no block). The one
    # gap, #party_level, ends in a real `actors.each { |a| ... }` block
    # (BLOCK/SENDB), the same established out-of-scope shape every other
    # block-using method above already documents -- confirmed directly
    # against the real whole-program diagnostic (SKIP_UNSUPPORTED=1
    # silently drops it, no generated entry point at all).
    #
    # Unlike every other #initialize-compiling target above, neither of
    # this class's own two ivars (@db, @state) ever gets embedded: both
    # are opaque object references (a database table and a Game::State
    # instance respectively), never provably Fixnum/Symbol. #initialize's
    # own real `# bc2cpp: (, Game::State)` class annotation (added several
    # follow-ups up, already present in the real source before this round)
    # confirms @state's real class for devirtualization purposes only --
    # ClassLayout/ClassAnnotations deliberately never feed IvarLayout's own
    # struct-field lattice, which models only Fixnum/Symbol primitives.
    # Confirmed directly against the real generated output: Game::EnemyAi
    # does not appear in bc2cpp's own "classes needing
    # MRB_SET_INSTANCE_TT" diagnostic, so no MRB_SET_INSTANCE_TT call
    # belongs in its own registration block.
    #
    # Every real construction site in the whole closed world goes through
    # a plain `Game::EnemyAi.new(db, state)` call -- mruby-rpg2k/mrblib/
    # scene/battle.rb's own Scene::Battle#initialize, plus 7 in scripts/
    # rpg2k_logic_check.rb's own CRuby test harness -- confirmed by
    # grepping the whole closed world for `Game::EnemyAi.new`/`.allocate`/
    # a subclass and finding no bypass and no subclass anywhere. Moot for
    # memory safety here specifically since nothing ends up embedded
    # either way, but checked anyway, the same construction-site
    # discipline every other embedding-candidate target above follows.
    #
    # A seventeenth, independent round adds Game::ChipSet (mruby-rpg2k/
    # mrblib/game.rb) -- one loaded chipset's own tile graphic name plus the
    # lower/upper passability tables, terrain table, and water-animation
    # parameters (chipset chunks 11/12), keyed by the tile-id-to-chip-index
    # math the RPG2000 BlockA/B/C/D chipset layout uses. ALL 9 of its own
    # real bytecode-defined instance methods compile clean, needing no new
    # opcode work at all: #initialize, #upper_flags (private), #elevated?,
    # #passable?, #landable?, #counter?, #passable_tile?, #landable_tile?,
    # #terrain. `.lower_index` is a real singleton (`def self.lower_index`)
    # -- the same pre-existing, program-wide structural gap Game::MoveRoute's
    # own class methods already documented (build_registry's CLASS/MODULE/
    # TDEF walk never recognizes an SCLASS-opened body), so it stays
    # interpreted regardless; every compiled method that calls it correctly
    # falls back to ordinary `mrb_funcall` rather than being devirtualized.
    #
    # Building this class's own #passable_tile?/#landable_tile? -- both do a
    # real `flags & DIR_BIT[dir]`/`flags & ALL_DIRS`/`flags & ABOVE_BIT`,
    # ordinary `Integer#&` sends -- surfaced a second real, live bug beyond
    # this file's own SUBILV/native-name-collision findings: compile_send's
    # (and three sibling copies') SEND-name-extraction charset omitted the
    # bitwise/modulo operator characters (`&|^~%`) and the unary-method
    # suffix `@`, so any operator SEND using one of them matched no method
    # name at all and silently compiled to `mrb_funcall(M, recv, "", ...)`
    # -- an empty-string method name, always a NoMethodError at runtime,
    # never caught by any #error-marker check. Confirmed LIVE in
    # already-shipped code, and far more widespread than this one new
    # target: a direct grep of the real generated `rpg2k_compiled_gen.cpp`
    # found 41 call sites across 32 already-registered compiled methods
    # spanning a dozen classes (RPG2k::Scene::ChipsetEditor's own
    # #toggled_byte/#cell_color_for, plus the `%`-for-cursor-wraparound
    # idiom shared by nearly every already-shipped menu's own scrolling-
    # cursor/blink-arrow logic -- RPG2k::Scene::Order/EquipMenu/ItemMenu/
    # SkillMenu/Menu/StatusMenu/DebugMenu/SaveLoad/Base, RPG2k::Window,
    # Game::Screen, Game::Transition). See bc2cpp.rb's own comment on
    # compile_send's own name-extraction line for the full accounting and
    # docs/adr/0139's own follow-up for the real before/after build and
    # runtime verification. Fixed at the root (one character class, reused
    # by every SEND-name extraction site in that file) -- every affected
    # class's own generated output regenerates correctly with the fix in
    # place, no hand-edit to any registration block needed beyond
    # ChipSet's own new one below, the same "fix bc2cpp.rb once, every
    # affected class regenerates automatically" shape this file's own
    # IvarLayout.join fix (Game::Character's own follow-up) already
    # established.
    #
    # #initialize (`initialize db, id`) compiles clean -- pure mandatory
    # arity (2 required arguments, no super, no block), the fifth target
    # after Game::Screen/Game::Transition/Game::State/Game::Map above whose
    # own ivars get real RData struct embedding. Checked directly against
    # the exact Game::Actor-shaped embedding bug several follow-ups up, not
    # assumed safe by analogy: grepping the whole closed world for
    # `ChipSet.new`/`Game::ChipSet.new`/`.allocate`/a subclass finds only
    # plain two-argument `.new(db, id)` call sites (mruby-rpg2k/mrblib/
    # scene/map.rb, scene/map_viewer.rb, game/lsd_io.rb, plus this project's
    # own scripts/*_check.rb harnesses) and no subclass anywhere, so every
    # real instance always goes through the compiled #initialize.
    # @animation_type and @animation_speed (each `c.animation_type || 0`/
    # `c.animation_speed || 0`, both real, provably-Fixnum) are real fields
    # on a new `Game__ChipSet_ivars` RData struct. The other 5 ivars
    # (@name/@graphic -- `c.name`/`c.chipset_name`, a method call's own
    # return value, never traced by this compiler's Fixnum-literal-only
    # inference, and both actually String-valued regardless; @passable_lower
    # /@passable_upper/@terrain -- each `c.<method>`, the schema's own
    # Array-typed passability/terrain tables) all stay UNKNOWN, so they stay
    # on the ordinary dynamic iv_tbl, mixed safely with the two embedded
    # fields on the same object, the same mixed-embedding shape Game::Screen/
    # Game::Transition/Game::State/Game::Map already established.
    #
    # #initialize and #upper_flags (a bare `private :upper_flags` right
    # after its own def) are both `private`; every other method is public,
    # confirmed directly against the real source (no other `private`/
    # `public` mode-switch anywhere in the class body).
    #
    # An eighteenth, independent round adds Game::Timer (mruby-rpg2k/mrblib/
    # game.rb) -- the RPG2000 Timer/Timer2 countdown backing model (both are
    # real instances of this one class, held as Game::State's own @timers
    # array -- there is no separate Timer2 class anywhere in the closed
    # world). 7 of its own 10 real bytecode-defined methods compile clean,
    # needing no new opcode work at all. #start/#tick/#drawn? each have one
    # non-mandatory optional argument, the same established out-of-scope
    # shape as every other unembedded target above. #initialize compiles
    # clean (zero arguments, pure mandatory arity), but the whole-program
    # EMBED diagnostic proposes nothing for this class: @running/@visible/
    # @in_battle are booleans (not modeled), and @frames -- despite a
    # literal-Fixnum source in #initialize/#set -- is poisoned back to
    # UNKNOWN by #load_h's own opaque `h[:frames] || 0` Hash#[] read, so no
    # MRB_SET_INSTANCE_TT call belongs in its own registration block. See
    # register.cxx's own top comment for the full writeup, including the
    # real full-sweep synergy this unlocks in already-shipped Game::State
    # (#timer_seconds/#timer2_seconds/#timer_display_text now devirtualize
    # straight into Game::Timer#seconds/#display_text, both MONO names).
    #
    # A nineteenth, independent round adds Game::Switches and
    # Game::Variables (both mruby-rpg2k/mrblib/game.rb) -- the 1-indexed
    # boolean/integer flag stores an event page's conditions read, each
    # backed by a plain Hash (`@data = {}`), not any real bit-array.
    # Re-checked both new classes specifically for the operator-regex bug
    # shape above -- neither one's own method bodies use a bitwise/modulo
    # operator at all (`Switches#flip`'s own `!self[id]` is a real SEND
    # too, to `!`, but that character was already in the charset before
    # that fix). Re-confirmed by grepping the freshly regenerated output
    # for the exact empty-name `mrb_funcall(M, <reg>, "", ` shape
    # project-wide: zero matches, same as every full-sweep re-check since
    # that fix landed.
    #
    # ALL 7 of Game::Switches's own real bytecode-defined methods compile
    # clean, needing no new opcode work at all: #initialize, #[], #[]=,
    # #flip, #to_h, #replace, #clear_dirty (#revision/#dirty are
    # attr_reader-generated, native, invisible to bc2cpp the same way every
    # other attr_reader/attr_writer in this codebase is). #initialize
    # (`initialize; @data = {}; @revision = 0; @dirty = {}; end`) compiles
    # clean -- zero arguments, no super, no block -- so its own provably-
    # Fixnum @revision (a literal `0`, then only ever `+= 1`) gets real
    # RData struct embedding, the sixth target after Game::Screen/
    # Game::Transition/Game::State/Game::Map/Game::ChipSet above. Checked
    # directly against the exact Game::Actor-shaped embedding bug several
    # follow-ups up, not assumed safe by analogy: grepping the whole closed
    # world for `Switches.new`/`Game::Switches.new`/`.allocate`/a subclass
    # finds exactly two real construction sites (mruby-rpg2k/mrblib/
    # game.rb's own Game::State#initialize, `@switches = Switches.new`, and
    # this project's own scripts/export_nano7_map.rb harness), both plain
    # zero-argument `.new` calls, no bypass and no subclass anywhere, so
    # every real instance always goes through the compiled #initialize.
    # @data and @dirty (each a Hash literal) stay UNKNOWN and remain on the
    # ordinary dynamic iv_tbl, mixed safely with the one embedded field.
    #
    # Game::Variables (same file, immediately below Switches) has 6 real
    # bytecode-defined methods, but #initialize (`initialize(rpg2003 =
    # false)`) has one non-mandatory optional argument -- the same
    # established out-of-scope shape every other unembedded target above
    # documents -- so drop_unsafe_embeddings correctly refuses to embed
    # this class's own provably-Fixnum @revision too (confirmed directly
    # against the real generated output: Game::Variables does not appear
    # in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic).
    # The other 5 methods (#[], #[]=, #to_h, #replace, #clear_dirty)
    # compile clean, needing no new opcode work at all -- #[]= additionally
    # clamps its own argument against @max/@min (opaque ivars set from
    # #initialize's own ternary), a plain pair of `>`/`<` comparisons
    # already covered by the existing EQ/LT/LE/GT/GE opcode work, no gap
    # here either. No bare `private`/`protected`/`public` anywhere in
    # either class body other than the interpreter's own unconditional
    # #initialize special case, so every other method in both classes is
    # public.
    #
    # A twentieth, independent round adds RPG2k::Scene::Title
    # (mruby-rpg2k/mrblib/scene/title.rb) -- the title screen's New Game/
    # Continue/Exit menu. Only 6 of its own 20 real bytecode-defined methods
    # compile clean, needing no new opcode work at all: #update/#dispose
    # (both public) plus 4 private methods (#refresh_cursor,
    # #move_selection, #auto_select?, #auto_new_game?). #move_selection's
    # own real `# bc2cpp: (fixnum)` annotation (already present in the real
    # source) lets its `% @menu_items.length` wraparound arithmetic compile
    # to a real, non-empty `mrb_funcall(M, r3, "%", 1, r4)` -- re-checked
    # directly against the real generated output given this exact
    # operator-name-extraction shape is this file's own most severe
    # previously-found bug. #auto_select?'s own real string-interpolated
    # `$stderr.puts` calls needed no new opcode either -- STRING/STRCAT
    # support already existed from an earlier round.
    #
    # The other 14 real methods split into the two already-established
    # out-of-scope shapes: 13 (#hide_title?, #preview_map_id,
    # #preview_animation_id, #load_windowskin, #new_game_flag?,
    # #auto_continue?, #battle_troop, #map_editor_flag?,
    # #chipset_editor_flag?, #continue_available?, #load_title_picture,
    # #play_cursor_se, #play_title_bgm) each have a real `rescue
    # StandardError` clause (RESCUE/RAISEIF/EXCEPT); #initialize itself hits
    # two separate gaps in the same body -- a real `super parent` call
    # (SUPER, the same gap ItemMenu/DebugMenu/Menu/ChipsetEditor/SaveLoad/
    # Order's own #initialize already document) and a real
    # `@menu_items.each_with_index do |item, index| ... end` block
    # (BLOCK/SENDB) later on -- confirmed directly against the real
    # generated output showing both #error markers in the same (unemitted)
    # body. #initialize never compiling means drop_unsafe_embeddings
    # correctly refuses to embed any of this class's own ivars -- confirmed
    # directly against the real generated output: RPG2k::Scene::Title does
    # not appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic, so no MRB_SET_INSTANCE_TT call belongs in its own
    # registration block (its own @title/@window ivars each get a
    # devirtualization-only CLASS_HINT, Sprite/Window respectively, never
    # embedded).
    #
    # A twenty-first, independent round adds RPG2k::Scene::MapWorld
    # (mruby-rpg2k/mrblib/scene/base.rb) -- the small adapter Scene::Map's
    # own #initialize builds (`@world = MapWorld.new(self, @rng)`) to
    # bridge Game::MoveRoute/Game::MoveType's own small `world` protocol
    # (passability, hero position, switch/sound side effects, randomness)
    # onto the owning scene and its Game::State. 7 of its own 8 real
    # bytecode-defined methods compile clean, needing no new opcode work at
    # all: #initialize, #passable?, #can_land?, #hero_position (an Array
    # literal off two chained sends), #in_sight?, #set_switch (SETIDX's own
    # real `mrb_funcall(..., "[]=", ...)` fallback, since the real receiver
    # -- Game::Switches -- is never a raw Array/Hash), and #random. The one
    # gap, #play_sound, has a real `rescue StandardError` clause -- the same
    # established out-of-scope shape every other rescue-using method in
    # this file already documents; confirmed directly against the real
    # whole-program diagnostic (SKIP_UNSUPPORTED=1 lists it under "skipped
    # (unsupported, left on the interpreter)", no generated entry point at
    # all). It already carries a real `# bc2cpp: (String, , , )` magic-
    # comment annotation in the source (predating this round), which
    # resolves to no actual type claim since this compiler's annotation
    # parser only recognizes fixnum/symbol tokens, never String -- moot
    # either way, since the rescue clause alone keeps this method
    # interpreted regardless of any annotation.
    #
    # #initialize (`initialize scene, rng`) compiles clean -- pure
    # mandatory arity, no super, no block -- but neither of this class's
    # own two ivars (@scene, @rng) ever gets embedded: both are opaque
    # object references (a RPG2k::Scene::Map and a Game::Rng instance
    # respectively), never provably Fixnum/Symbol. Confirmed directly
    # against the real generated output: RPG2k::Scene::MapWorld does not
    # appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic, so no MRB_SET_INSTANCE_TT call belongs in its own
    # registration block. Every real construction site in the whole closed
    # world goes through a plain `MapWorld.new(scene, rng)` call --
    # mruby-rpg2k/mrblib/scene/map.rb's own `@world = MapWorld.new(self,
    # @rng)`, plus one in this project's own scripts/rpg2k_scene_check.rb
    # CRuby test harness (`RPG2k::Scene::MapWorld.new(nil, nil)`,
    # exercising #play_sound only) -- confirmed by grepping the whole
    # closed world for `MapWorld.new`/`.allocate`/a subclass and finding no
    # bypass and no subclass anywhere.
    #
    # Every one of #passable?/#can_land?/#hero_position/#play_sound/
    # #random/#set_switch is a genuinely POLY name in the whole-program
    # registry -- RPG2k::Scene::VehicleWorld (the same file, "the same
    # `world` protocol... for a Move Event/Set Move Route driving a
    # vehicle") defines every one of them too, plus #passable? also
    # collides with Game::ChipSet, #random with Game::Rng, and #set_switch
    # with Game::Interpreter/Game::EnemyAi -- none of which blocks
    # registering MapWorld's own methods (POLY only affects whether some
    # *other* compiled call site devirtualizes into one of these, never
    # whether a class's own methods can be registered). No bare
    # `private`/`protected` anywhere in the class body, so every method is
    # `mrb_define_method` except #initialize itself, forced private by
    # mruby's own interpreter regardless of source. A real lead for a
    # future round: RPG2k::Scene::VehicleWorld's own identical protocol
    # shape.
    owners: %w[Game::Picture Game::EnemyAction Game::Screen RPG2k::Window
               Game::Transition Game::Actor Game::Party
               RPG2k::Scene::MapViewer Game::Battle RPG2k::Scene::ItemMenu
               RPG2k::Scene::SkillMenu RPG2k::Scene::DebugMenu
               RPG2k::Scene::EquipMenu RPG2k::Scene::Menu Game::State
               RPG2k::Scene::StatusMenu Game::MoveRoute
               RPG2k::Scene::ChipsetEditor RPG2k::Scene::Base
               Game::Character RPG2k::Scene::SaveLoad RPG2k::Scene::Order
               Game::Shop Game::Map Game::EnemyAi Game::ChipSet
               Game::Timer Game::Switches Game::Variables
               RPG2k::Scene::Title RPG2k::Scene::MapWorld],
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

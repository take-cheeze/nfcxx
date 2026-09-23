# Single source of truth for every bc2cpp-generated gem's owners and
# OUT_SYMBOL, plus the shared source sets below (closed_world_mrblib_srcs,
# core_native_srcs, ...). Every *-compiled mrbgem.rake requires this file, so
# no gem hand-copies another's list: a drifted copy fails silently, with two
# gems reaching different MONO/POLY conclusions for the same name.
#
# Cross-gem devirtualization (docs/adr/0139): each mrbgem.rake derives its
# OTHER_OWNERS/OTHER_DECLS_HEADER from the *other* entries here, so a direct
# call can reference another gem's _impl through its *_decls.h without either
# codegen step reading the other's output (that would be a circular Rake
# dependency; only the final register.cxx compile needs both).
#
# EMBED_WIRED: the classes whose embedded-ivar layout is actually wired at
# runtime. An embedded class keeps its ivars in an RData struct, so it is only
# sound when the class is MRB_TT_DATA and *every* method that touches those
# ivars is an installed compiled method, #initialize included (it allocates the
# struct). Otherwise an interpreted fallback reads the ordinary iv_tbl (always
# empty for an embedded ivar -- 3rd/mruby/include/mruby/data.h keeps `iv` and
# `data` as separate fields) and sees nil.
#
# bc2cpp.rb's driver generates that registration itself (OWNER_METHOD_
# REGISTRATION, emit_owner_registrations) for every entry of these classes in
# `compiled` -- by compile_all's #error partition, exactly the entries that
# compile clean -- so the equivalence holds by construction rather than by a
# hand-written register.cxx kept in sync (which drifted before: see ADR 0139).
# register.cxx calls it once, right after bc2cpp_set_instance_tts.
# scripts/bc2cpp_wired_embedding_check.rb verifies it against the generated
# output (a hand mrb_define_method for the same name/aspec counts too).
BC2CPP_WIRED_EMBEDDINGS = %w[
  Game::Screen Game::ChipSet Game::Switches RPG2k::Scene::VehicleWorld
  LCF::EventCommand LCF::MoveCommand Game::Interpreter Game::Transition Game::Map
  Game::State RPG2k RPG2k::Scene::Map::LRUBitmapCache Game::Timer LCF::Tree
  RPG2k::Window
  RPG2k::Scene::Map Game::Battle Game::Battle.singleton RPG2k::Scene::Battle
  RPG2k3::Scene::Battle Game::Actor Game::Party Game::Party.singleton
  Game::Actors Game::Shop Game::Enemy Game::Troop Game::EnemyAi
  Game::TextReveal Game::MessageConfig Game::NumberInput
  Game::States.singleton Game::Message.singleton Game::ChipsetLayout.singleton
  Game::EventPage.singleton Game::BattlePage.singleton Game::State.singleton
  RPG2k::Scene::Base RPG2k::Scene::ChipsetEditor RPG2k::Scene::DebugMenu
  RPG2k::Scene::EquipMenu RPG2k::Scene::GameOver RPG2k::Scene::ItemMenu
  RPG2k::Scene::MapViewer RPG2k::Scene::Menu RPG2k::Scene::Order
  RPG2k::Scene::SaveLoad RPG2k::Scene::SkillMenu RPG2k::Scene::StatusMenu
  RPG2k::Scene::Title
  LCF::Sections LCF::Array1D LCF::Array2D LCF::File
  RGSS::ErrorReport::Tee RGSS::Bitmap Array
  RGSS.singleton RGSS::ErrorReport.singleton RGSS::Input.singleton
  RGSS::Audio.singleton RGSS::Graphics.singleton
  # docs/adr/0215: the mruby-rpg2k record classes that replaced Structs.
  RPG2k::Scene::Map::MapEventState RPG2k::Scene::Map::MessageState
  RPG2k::Scene::Map::ShopState RPG2k::Scene::Map::ShopQuantity
  Game::Interpreter::NameInputRequest Game::Interpreter::InnRequest
  Game::Interpreter::ShopRequest Game::Interpreter::BattleRequest
  Game::Interpreter::KeyInputRequest Game::Interpreter::KeyInputAccepted
  Game::Interpreter::DiagnosticPosition Game::CommonEvent::CommonEventRecord
  Game::Message::Segment Game::Message::SpeedMarker Game::Message::PauseMarker
  Game::Message::ScanResult
].freeze

# EMBED_IVAR_LIMITS: a wired owner listed here embeds only these ivars. Game::State
# keeps the three it embedded before ADR 0202: its other ivars are written through
# attr writers from code IvarLayout does not type-check (load/from_lsd), so lift
# this only after a real save/load run.
BC2CPP_EMBED_IVAR_LIMITS = {
  'Game::State' => %w[bgm_looped encounter_total save_count]
}.freeze

BC2CPP_COMPILED_GEMS = {
  'mruby-lcf-compiled' => {
    # Owners are emission targets: every method of theirs that compiles clean is
    # emitted and registered; the rest (blocks, rescue, super, non-mandatory
    # arity, method_missing) stay interpreted. What each class compiles is in the
    # generated diagnostic (`== compiled entry points ==`), not listed here.
    #
    # Embedding is decided by bc2cpp.rb's drop_unsafe_embeddings, never here: an
    # ivar covered by a native attr_reader/attr_writer (natively_exposed?) never
    # embeds, since the native accessor reads iv_tbl, not the RData struct. That
    # is why LCF::MoveCommand/EventCommand/Tree embed nothing despite provably
    # Fixnum ivars. #initialize is always private in mruby, so it registers with
    # mrb_define_private_method.
    #
    # LCF::File#[]/#[]= dispatch on @root dynamically (an LCF::Sections or a
    # schema-typed instance, never a real Array/Hash), so no devirtualization of
    # @root is involved and subclass identity does not matter.
    #
    # StringIO is reopened, not defined, by this project (mruby-lcf/mrblib/lcf.rb
    # adds #ungetbyte). Its POLY collision with native IO#ungetbyte is by bare
    # name only, which the registry already treats as POLY. Load order is safe:
    # mruby-stringio loads before mruby-lcf, and `add_dependency 'mruby-lcf'` runs
    # the reopening before this gem installs the compiled override. #ungetbyte
    # touches no ivar.
    owners: %w[LCF::File LCF::Database LCF::MapTree LCF::MapUnit LCF::SaveData
               LCF::MoveCommand LCF::EventCommand LCF::Tree LCF::Sections
               LCF::Array1D LCF::Array2D StringIO],
    out_symbol: 'lcf_compiled',
  },
  'mruby-rpg2k-compiled' => {
    # Same rules as the mruby-lcf-compiled entry above. Points that are easy to
    # get wrong when adding an owner here:
    #
    # - `.singleton` owners are the `def self.x`/`class << self` methods of a
    #   class or module (ADR 0139, ".singleton owner support"); they register
    #   with mrb_define_class_method and never embed (class ivars live on a
    #   different object than any instance's iv_tbl).
    # - A compiled `#initialize` with pure mandatory arity is only the first gate
    #   of drop_unsafe_embeddings; every ivar-touching method must also compile
    #   (every_accessor_compiles?). The diagnostic's `== ivar embedding ==`
    #   section prints IvarLayout's raw proposal, before that filter -- trust the
    #   "classes needing MRB_SET_INSTANCE_TT" section instead.
    # - Only Fixnum/Symbol ivars embed; a GETCONST-fed or method-return-fed
    #   value stays UNKNOWN (a missed embedding, never an unsound one).
    # - A Struct's members are positional (mruby-struct), never iv_tbl, so
    #   Game::Battle::Combatant has nothing to embed. Its `half_sp_cost?`/
    #   `member?` sanitize to the same C name as the Struct-native writers, but
    #   those have irep nil and are never emitted, so no collision.
    # - A POLY name in the registry only stops other call sites devirtualizing
    #   into it; it never blocks registering the owner's own method.
    #
    # `LCF` (the bare module) is deliberately not an owner: its methods compile,
    # but every call site reaches them as `LCF.read_ber(...)` through the
    # module_function copy on the singleton class (irep nil, "LCF.singleton"), and
    # LCF is never included or extended, so an LCF-owned _impl would be
    # unreachable dead code.
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
               RPG2k::Scene::Title RPG2k::Scene::MapWorld Game::TextReveal
               RPG2k::Scene::VehicleWorld RPG2k::Scene::EventResolver
               Game::NumberInput RPG2k::Scene::GameOver Game::Actors
               Game::Rng Game::Weather Game::Troop Game::Vehicle
               Game::Enemy RPG2k3::Scene::Battle Game::MessageConfig
               Game::Interpreter RPG2k::Scene::Map RPG2k::Scene::Battle
               Game.singleton Game::States.singleton Game::States::BattleText.singleton
               Game::ChipsetLayout.singleton Game::EventGraphic.singleton
               Game::Battle.singleton Game::Transition.singleton
               Game::State.singleton Game::Party.singleton
               Game::Picture.singleton Game::Character.singleton
               Game::ChipSet.singleton RPG2k::Scene::Map.singleton
               Game::Battle::Combatant RPG2k
               Game::MoveType.singleton Game::MapAccess.singleton
               Game::Parallax.singleton Game::MessagePalette.singleton
               Game::MapBgm.singleton Game::BattlePage.singleton
               Game::WindowCursor.singleton Game::Message.singleton
               Game::EventPage.singleton Game::CharSet.singleton
               Game::Backdrop.singleton RPG2k::Scene.singleton
               RPG2k::Scene::Map::LRUBitmapCache
               # docs/adr/0215: the record classes that replaced Structs.
               RPG2k::Scene::Map::MapEventState RPG2k::Scene::Map::MessageState
               RPG2k::Scene::Map::ShopState RPG2k::Scene::Map::ShopQuantity
               Game::Interpreter::NameInputRequest Game::Interpreter::InnRequest
               Game::Interpreter::ShopRequest Game::Interpreter::BattleRequest
               Game::Interpreter::KeyInputRequest Game::Interpreter::KeyInputAccepted
               Game::Interpreter::DiagnosticPosition Game::CommonEvent::CommonEventRecord
               Game::Message::Segment Game::Message::SpeedMarker Game::Message::PauseMarker
               Game::Message::ScanResult],
    out_symbol: 'rpg2k_compiled',
  },
  'mruby-rgss-compiled' => {
    # Same rules as above. Notes specific to RGSS:
    #
    # - RGSS::Window runs `alias_method :_rgss1_initialize, :initialize`; that is
    #   an SSEND, not OP_ALIAS, so the aliased name never enters the registry
    #   under any owner. A call to an alias_method-defined name therefore always
    #   stays ordinary dispatch (safe, just never devirtualized).
    # - RGSS::Graphics.singleton#brightness_sprite is private and compiles, but
    #   mruby has no private class-method registration, so it stays out of
    #   register.cxx and is reached only through the devirtualized call in
    #   `brightness=`.
    # - Array is reopened by mruby-rgss/mrblib/array_include.rb (an index-loop
    #   #include?). Its POLY collision with native Module#include? is by bare
    #   name only, and `add_dependency 'mruby-rgss'` runs the reopening before
    #   the compiled override is installed -- the same reasoning as StringIO in
    #   mruby-lcf-compiled.
    owners: %w[RGSS::Sprite RGSS::Plane RGSS::Tilemap RGSS::Window RGSS::Bitmap RGSS::Bitmap.singleton
               RGSS.singleton RGSS::Audio.singleton RGSS::Input.singleton RGSS::ErrorReport.singleton
               RGSS::Graphics.singleton RGSS::Font.singleton RGSS::ErrorReport::Tee Array],
    out_symbol: 'rgss_compiled',
  },
}.freeze

# mruby's own core (3rd/mruby/src/*.c) and every core mrbgem active in the
# real build, as closed-world NATIVE_SRCS input alongside mruby-rgss/src/
# *.cxx. Without it the registry is unsound against mruby's own C methods:
# mruby 4.0 registers most core methods through the ROM method-table macro
# (`MRB_MT_ENTRY(fn, MRB_SYM(name), flags)`, e.g. symbol.c's
# symbol_rom_entries -- Symbol#name vs. Game::Shop#name), a different idiom
# from literal `mrb_define_method(M, klass, "name", ...)`; see bc2cpp.rb's
# extract_native_method_names for both.
#
# The list must cover every core mrbgem the running mrb_state loads -- direct
# `conf.gem core:` calls AND gems reached through add_dependency chains
# (mruby-lcf/mruby-rgss -> mruby-pack/mruby-string-ext; mruby-marshal ->
# mruby-struct/mruby-string-ext/mruby-metaprog; mruby-rpgxp -> mruby-eval ->
# mruby-binding, mruby-fiber, ...). A transitively loaded gem collides exactly
# like a direct one. Keep it in sync when build_config.rb or those chains
# change. Excluded: mruby-compiler (defines no runtime methods) and
# mruby-enumerator (Ruby-only; a bytecode-stdlib blind spot this scan cannot
# close).
def core_native_srcs(mruby_root)
  Dir["#{mruby_root}/src/*.c"] +
    Dir["#{mruby_root}/mrbgems/mruby-{array-ext,hash-ext,enum-ext,io,dir," \
        'numeric-ext,range-ext,fiber,exit,sprintf,kernel-ext,random,math,time,bigint,' \
        "binding,eval,metaprog,method,pack,proc-ext,string-ext,struct}/**/*.c"]
end

# The three external (non-`3rd/mruby/mrbgems`) mrbgems this project always
# loads: `mruby-marshal`/`mruby-onig-regexp` (explicit top-level gems in
# build_config.rb's `explicit_shared_names`) and `mruby-stringio` (a
# dependency of mruby-wolf, always in the desktop build). They live in their
# own `3rd/` submodules, outside `mruby_root`, so `core_native_srcs` cannot
# reach them. mruby-marshal's source is `.cpp`, not `.c`.
def external_gem_native_srcs(gems_root)
  Dir["#{gems_root}/3rd/mruby-marshal/src/*.cpp"] +
    Dir["#{gems_root}/3rd/mruby-onig-regexp/src/*.c"] +
    Dir["#{gems_root}/3rd/mruby-stringio/src/*.c"]
end

# The whole-program mrblib source set every *-compiled mrbgem.rake feeds into
# bc2cpp.rb as `closed_world_srcs`, so build_registry's MONO/POLY resolution
# sees every gem that could define a colliding name (e.g.
# `LCF::Database#rpg2003?` is MONO in isolation but not with Game::Actor/
# Party/Battle#rpg2003?). Shared here so the gems cannot drift apart: a
# drifted set fails silently, with different MONO/POLY conclusions per gem.
def closed_world_mrblib_srcs(gems_root)
  # Sorted: Dir[] returns filesystem order (ext4 vs APFS disagree), and
  # bc2cpp's capped fixed-point sweeps converge order-dependently, so ARGV order
  # changes devirtualization. A canonical order makes every consumer agree; the
  # analyses' own order-sensitivity is a separate bug, not fixed by this.
  (Dir["#{gems_root}/mruby-rpg2k/mrblib/**/*.rb"] +
    Dir["#{gems_root}/mruby-lcf/mrblib/*.rb"] +
    Dir["#{gems_root}/mruby-rgss/mrblib/*.rb"]).sort
end

# INTEGER_CONSTANT_PROOF: every Ruby source compiled into the same VM as the
# closed world but not part of it -- mruby core mrblib, every core mrbgem's
# mrblib, and the three external gems (see `external_gem_native_srcs`).
# `IntegerConstants` (bc2cpp.rb) proves "every definition of bare constant N
# assigns an integer literal", and a definition here is still one a compiled
# `GETCONST N` can resolve to (lexical scope, then ancestors -- e.g. an
# included Enumerable). Scanned for constant-assignment names only, never
# compiled. Real collision: 3rd/mruby/mrblib/enum.rb has `NONE = Object.new`
# while mruby-rpg2k/mrblib/game.rb has `NONE = 37`.
def foreign_mrblib_srcs(gems_root)
  Dir["#{gems_root}/3rd/mruby/mrblib/**/*.rb"] +
    Dir["#{gems_root}/3rd/mruby/mrbgems/*/mrblib/**/*.rb"] +
    Dir["#{gems_root}/3rd/mruby-marshal/mrblib/**/*.rb"] +
    Dir["#{gems_root}/3rd/mruby-onig-regexp/mrblib/**/*.rb"] +
    Dir["#{gems_root}/3rd/mruby-stringio/mrblib/**/*.rb"]
end

# CLOSED_WORLD (docs/adr/0210): the builds that ship RPG2000/2003 only
# (build_config.rb's single_format_only). Their games carry no Ruby, so the
# only Ruby that can run is the closed world plus the build's own gems.
BC2CPP_CLOSED_WORLD_BUILDS = %w[psp wio maix].freeze
# Gems that load or define Ruby at runtime; any of them opens the world.
BC2CPP_OPEN_WORLD_GEMS = %w[
  mruby-rpgxp mruby-rpgvx mruby-wolf mruby-mvjs mruby-eval mruby-binding mruby-proc-binding
  mruby-bin-mirb mruby-bin-mruby mruby-bin-debugger
].freeze
# The gems whose mrblib is the closed world itself.
BC2CPP_CLOSED_WORLD_GEMS = %w[mruby-rpg2k mruby-lcf mruby-rgss].freeze
# Each closed-world target's own native host sources (the firmware/executable).
BC2CPP_CLOSED_WORLD_HOST_SRCS = { 'wio' => 'app/wio/src', 'maix' => 'app/wio/src', 'psp' => 'app/psp' }.freeze
# mruby-compiler entry points that turn a string or file into running Ruby.
BC2CPP_SOURCE_LOADER_CALL = /\b(?:mrb_load_n?string(?:_cxt)?|mrb_load_file(?:_cxt)?|mrb_load_exec|
                               mrb_parse_n?string|mrb_parse_file|mrb_load_detect_file_cxt)\s*\(([^;]*)/mx
BC2CPP_NATIVE_GLOB = '*.{c,cc,cpp,cxx,h,hh,hpp,hxx,inc}'

# Opt-in from build_config.rb (`conf.gem ... { enable_bc2cpp_closed_world }`).
module Bc2cppClosedWorldOption
  def enable_bc2cpp_closed_world
    @bc2cpp_closed_world = true
  end

  def bc2cpp_closed_world?
    @bc2cpp_closed_world == true
  end
end

# The top-level arguments of a C call, given the text after its `(`.
def bc2cpp_c_call_args(text)
  args = [+'']
  depth = 0
  text.scan(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[()\[\]{}]|,|[^"'()\[\]{},]+/m) do |tok|
    depth += 1 if '([{'.include?(tok)
    depth -= 1 if ')]}'.include?(tok)
    break if depth.negative?

    tok == ',' && depth.zero? ? args << +'' : args.last << tok
  end
  args
end

def bc2cpp_host_native_srcs(build_name, repo_root)
  host = BC2CPP_CLOSED_WORLD_HOST_SRCS[build_name]
  host ? Dir["#{repo_root}/#{host}/**/#{BC2CPP_NATIVE_GLOB}"].sort : []
end

# Why `gems` ({name => dir}, the build's real gem list) cannot be treated as a
# closed world; empty when it can.
def bc2cpp_closed_world_violations(build_name, gems, repo_root, host_srcs: bc2cpp_host_native_srcs(build_name, repo_root))
  errors = []
  unless BC2CPP_CLOSED_WORLD_BUILDS.include?(build_name)
    errors << "build '#{build_name}' is not one of #{BC2CPP_CLOSED_WORLD_BUILDS.join('/')}"
  end
  missing = BC2CPP_CLOSED_WORLD_GEMS - gems.keys
  errors << "gem list lacks #{missing.join(', ')}" unless missing.empty?
  (gems.keys & BC2CPP_OPEN_WORLD_GEMS).each { |name| errors << "#{name} loads or defines Ruby at runtime" }
  # Without mruby-compiler no source string can be compiled at all; with it,
  # every host call must compile a fixed literal that defines nothing.
  if gems.key?('mruby-compiler')
    host_srcs.each do |path|
      text = File.read(path, encoding: 'BINARY')
      text.scan(BC2CPP_SOURCE_LOADER_CALL) do |(args)|
        source = bc2cpp_c_call_args(args)[1].to_s.strip
        literal = source[/\A"((?:[^"\\]|\\.)*)"\z/m, 1] ||
                  (source.match?(/\A\w+\z/) && text[/\bchar\s+#{source}\s*\[\s*\]\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/, 1])
        next if literal && !literal.match?(/\b(?:def|class|module|alias|undef|define_\w+|attr\w*|include|extend|
                                                 prepend|\w*eval|send|__send__|load|require|Struct|const_set|
                                                 remove_const|method_missing)\b/x)

        errors << "#{path.delete_prefix("#{repo_root}/")} runs a non-literal Ruby source (#{source})"
      end
    end
  end
  errors
end

# The native and Ruby sources outside the closed world that share its VM on a
# closed-world build: mruby core, every other gem's src and mrblib, the
# closed-world gems' own native src, and the target's host sources.
def bc2cpp_closed_world_outside_srcs(build_name, gems, repo_root)
  native = Dir["#{repo_root}/3rd/mruby/src/**/#{BC2CPP_NATIVE_GLOB}"] +
           Dir["#{repo_root}/include/**/#{BC2CPP_NATIVE_GLOB}"] +
           bc2cpp_host_native_srcs(build_name, repo_root)
  ruby = Dir["#{repo_root}/3rd/mruby/mrblib/**/*.rb"]
  gems.each do |name, dir|
    next if BC2CPP_COMPILED_GEMS.key?(name)

    native += Dir["#{dir}/{src,core}/**/#{BC2CPP_NATIVE_GLOB}"]
    ruby += Dir["#{dir}/mrblib/**/*.rb"] unless BC2CPP_CLOSED_WORLD_GEMS.include?(name)
  end
  [native.map { |p| File.expand_path(p) }.uniq.sort, ruby.map { |p| File.expand_path(p) }.uniq.sort]
end

# The extra bc2cpp environment for `spec`'s build: the closed-world switch and
# its gem list when build_config.rb enabled it, {} otherwise. Called from the
# codegen task, once every gem (dependencies included) is in the build.
def bc2cpp_closed_world_env(spec, repo_root)
  return {} unless spec.bc2cpp_closed_world?

  require 'shellwords'
  gems = spec.build.gems.to_h { |g| [g.name, File.expand_path(g.dir)] }
  errors = bc2cpp_closed_world_violations(spec.build.name, gems, repo_root)
  unless errors.empty?
    raise "#{spec.name}: BC2CPP_CLOSED_WORLD refused for build '#{spec.build.name}':\n  #{errors.join("\n  ")}"
  end

  { 'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => spec.build.name,
    'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |name, dir| "#{name}=#{dir}" }) }
end

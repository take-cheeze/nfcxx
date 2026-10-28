# Single source of truth for every bc2cpp-generated gem's owners (derived from its
# base gem's mrblib: bc2cpp_gem_owners) and OUT_SYMBOL, plus the shared source sets below (closed_world_mrblib_srcs,
# core_native_srcs, ...). Every *-compiled mrbgem.rake requires this file, so
# no gem hand-copies another's list: a drifted copy fails silently, with two
# gems reaching different MONO/POLY conclusions for the same name.
#
# Cross-gem devirtualization: each mrbgem.rake derives its
# OTHER_OWNERS/OTHER_DECLS_HEADER from the *other* entries here, so a direct
# call can reference another gem's _impl through its *_decls.h without either
# codegen step reading the other's output (that would be a circular Rake
# dependency; only the final link needs both).
#
# mruby's own Ruby that joins the closed world as compiled input --
# 3rd/mruby/mrblib/*.rb plus the mrblib of these gems, in interpreter load order
# (core mrblib, then gems). A class is spread over several gems' mrblib, so the
# registry must see every definition of a name before a call to it can
# resolve; a file only joins when its gem is in the build's gem list
# (core_compiled_mrblib_srcs), or the compiled body would replace a method of a
# class that is never loaded.
BC2CPP_CORE_MRBLIB_GEMS = %w[
  mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-numeric-ext mruby-range-ext mruby-symbol-ext mruby-string-ext
  mruby-compar-ext
  mruby-sprintf mruby-struct mruby-io mruby-dir mruby-enumerator
].freeze
# Core mrblib files that stay outside the world (foreign sources):
# - mruby-io's kernel.rb defines Kernel#puts/print/printf/gets with `(...)`
#   forwarding, whose call sites bc2cpp models separately
#   (codegen_send.rb, IO_PUTS_MODEL); and mrbc's multi-file parse leaves the
#   `(...)` state set, so a file after it fails to parse.
# - 10error.rb only gives NameError/NoMethodError their accessors; visible, they
#   would add two exact-class arms to every `.name` call chain for nothing.
BC2CPP_CORE_MRBLIB_EXCLUDED = %w[mrbgems/mruby-io/mrblib/kernel.rb mrblib/10error.rb].freeze
# Core mrblib gems whose Ruby is analysed as program, so their method names are known callers and not outside tokens
# Only their C sources stay outside. Files in BC2CPP_CORE_MRBLIB_EXCLUDED stay foreign.
BC2CPP_PROGRAM_CORE_MRBLIB_GEMS = BC2CPP_CORE_MRBLIB_GEMS
# FAIL_FAST_TYPE (compile-time): true defines BC2CPP_FAIL_FAST_TYPE in the compiled gems, so each closed-world
# fallback (bc2cpp_nomethod) raises TypeError instead of dispatching by name. Off in every shipped build.
BC2CPP_FAIL_FAST_TYPE = false
# Same, from 3rd/<name>/mrblib. mruby-marshal has no mrblib.
BC2CPP_EXTERNAL_MRBLIB_GEMS = %w[mruby-stringio mruby-onig-regexp].freeze
# The gem set the canonical (script, coverage report) world assumes: the closed build's,
# which has neither mruby-dir nor the Onigmo regexp gem (build_config.rb).
BC2CPP_CANONICAL_CORE_GEMS = (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS -
                              %w[mruby-dir mruby-onig-regexp]).freeze
# The classes core sources define methods on: the owners mruby-core-compiled
# emits, except Object (mruby-rpg2k/mrblib/main.rb defines engine methods on it
# that no compiled gem emits, so an Object owner would claim them). A class
# also owned by an engine gem (Array, StringIO) is split per definition by
# source file: see emit_unit in bc2cpp.rb.
# The classes core sources define methods on, read from the sources: the Ruby defs of the core and
# external mrblib files (the owners mruby-core-compiled emits), and the C definitions of mruby's src/
# and the core mrbgems' C, literal registrations and ROM tables alike. Object is left out:
# mruby-rpg2k/mrblib/main.rb defines engine methods on it that no compiled gem emits, so an Object owner
# would claim them. A class also owned by an engine gem (Array, StringIO) is split per definition by
# source file: see emit_unit in bc2cpp.rb.
require 'prism'
require_relative 'scan_cache'
BC2CPP_OWNER_SOURCE_ROOT = File.expand_path('../../3rd', __dir__).freeze
# mrb->X_class fields that core binds to a named class.
BC2CPP_STATE_CLASS_FIELDS = {
  'object_class' => 'Object', 'basic_class' => 'BasicObject', 'module_class' => 'Module', 'class_class' => 'Class',
  'kernel_module' => 'Kernel', 'comparable_module' => 'Comparable', 'enumerable_module' => 'Enumerable',
  'proc_class' => 'Proc', 'string_class' => 'String', 'array_class' => 'Array', 'hash_class' => 'Hash',
  'float_class' => 'Float', 'integer_class' => 'Integer', 'symbol_class' => 'Symbol', 'range_class' => 'Range',
  'nil_class' => 'NilClass', 'true_class' => 'TrueClass', 'false_class' => 'FalseClass',
  'exception_class' => 'Exception', 'numeric_class' => 'Numeric', 'fiber_class' => 'Fiber',
}.freeze

def bc2cpp_mrblib_files(gem)
  roots = [File.join(BC2CPP_OWNER_SOURCE_ROOT, 'mruby/mrbgems', gem), File.join(BC2CPP_OWNER_SOURCE_ROOT, gem)]
  roots.flat_map { |root| Dir[File.join(root, '**/mrblib/**/*.rb')] }.sort
end

# Owners of Ruby definitions: a `def` directly in a class, module or `class << self` body, or `def self.`.
def bc2cpp_ruby_definition_owners
  owners = Set.new
  (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem|
    bc2cpp_mrblib_files(gem).each do |path|
      next if BC2CPP_CORE_MRBLIB_EXCLUDED.any? { |excluded| path.end_with?(excluded) }

      walk = lambda do |node, scope, singleton|
        next unless node

        case node
        when Prism::ClassNode, Prism::ModuleNode
          walk.(node.body, scope + [node.constant_path.slice], false)
        when Prism::SingletonClassNode
          walk.(node.body, scope, true) if node.expression.is_a?(Prism::SelfNode) && !scope.empty?
        when Prism::DefNode
          if node.receiver.nil?
            owners << (singleton ? "#{scope.join('::')}.singleton" : scope.join('::')) unless scope.empty?
          elsif node.receiver.is_a?(Prism::SelfNode) && !scope.empty?
            owners << "#{scope.join('::')}.singleton"
          elsif node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
            owners << "#{node.receiver.slice}.singleton"
          end
        else
          node.compact_child_nodes.each { |child| walk.(child, scope, singleton) }
        end
      end
      walk.(Prism.parse(File.read(path)).value, [], false)
    end
  end
  owners
end

# Owners of C definitions: the class each mrb_define_method* / mrb_define_class_method* / ROM table
# (MRB_MT_INIT_ROM) is bound to, resolved through the variable that holds the class. Every generator process
# loads this file, so the scan is cached on its inputs (the C sources).
def bc2cpp_c_definition_owners
  c_files = Dir[File.join(BC2CPP_OWNER_SOURCE_ROOT, 'mruby/src/*.c')] +
            BC2CPP_CORE_MRBLIB_GEMS.flat_map { |gem| Dir[File.join(BC2CPP_OWNER_SOURCE_ROOT, 'mruby/mrbgems', gem, '**/*.c')] }
  Set.new(ScanCache.fetch('compiled_gems.c_definition_owners', c_files) { scan_c_definition_owners(c_files).to_a })
end

def scan_c_definition_owners(c_files)
  owners = Set.new
  c_files.reject { |path| path =~ %r{test|\.orig} }.sort.each do |path|
    src = File.read(path, encoding: 'BINARY')
    bound = {}
    src.scan(/\b(\w+)\s*=\s*mrb_define_(?:class|module)(?:_id|_under|_under_id)?\s*\(\s*mrb\s*,\s*(?:\w+\s*,\s*)?(?:"(\w+)"|MRB_SYM\((\w+)\))/) do |var, literal, sym|
      bound[var] = literal || sym
    end
    src.scan(/\b(\w+)\s*=\s*mrb_(?:class|module)_get(?:_id)?\s*\(\s*mrb\s*,\s*"(\w+)"/) { |var, name| bound[var] ||= name }
    resolve = lambda do |ref|
      field = ref[/\Amrb->(\w+)\z/, 1]
      field ? BC2CPP_STATE_CLASS_FIELDS[field] : bound[ref]
    end
    src.scan(/MRB_MT_INIT_ROM\(\s*mrb\s*,\s*([\w>-]+)\s*,/) do |(ref)|
      owners << resolve.(ref) if resolve.(ref)
    end
    src.scan(/mrb_define_(?:method|method_id|method_raw|module_function|module_function_id)\s*\(\s*mrb\s*,\s*([\w>-]+)\s*,/) do |(ref)|
      owners << resolve.(ref) if resolve.(ref)
    end
    src.scan(/mrb_define_(?:class_method|class_method_id)\s*\(\s*mrb\s*,\s*([\w>-]+)\s*,/) do |(ref)|
      owners << "#{resolve.(ref)}.singleton" if resolve.(ref)
    end
  end
  owners
end

# Sorted, so the list does not depend on the order the sources happen to be read in.
BC2CPP_CORE_OWNERS = (bc2cpp_ruby_definition_owners + bc2cpp_c_definition_owners - %w[Object]).to_a.sort.freeze

# OWNER_METHOD_REGISTRATION / REGISTRATION_SPLIT (codegen_emit.rb, emit_owner_registrations): [every owner a gem
# registers, the core half of them]. Only core owners go in the core half: it must resolve no program class, and an
# engine gem runs both halves back to back in its gem_init, so where an embedding program class registers in it
# changes nothing.
def bc2cpp_registration_owners(compiled_owners)
  core = BC2CPP_CORE_OWNERS
  [(core + compiled_owners).uniq, core.to_set]
end
BC2CPP_CORE_REFUSED_PATH = File.expand_path('core_refused.txt', __dir__)

require 'prism'
require_relative '../rgss_tts_config'
require_relative 'mrblib_stubs'
require_relative 'gem_owners'

# GEM_OWNERS: a compiled gem's owners are every engine owner with a plain def in its base gem's mrblib (every
# variant: a build that leaves a file out only has fewer defs), and the core classes the gem reopens.
def bc2cpp_gem_owners(base_gem, reopened: [])
  GemOwners.owners(Dir[File.expand_path("../../#{base_gem}/mrblib*/**/*.rb", __dir__)].sort, reopened: reopened)
end

# `native_namespaces`: the namespaces whose native (C/C++) registrations this gem's registration removes when the
# closed list leaves them out (NATIVE_CANDIDATES, static_dispatch_registrations.rb).
BC2CPP_COMPILED_GEMS = {
  'mruby-lcf-compiled' => {
    # Owners are emission targets: every method of theirs that compiles clean is
    # emitted and registered; the rest (blocks, rescue, super, non-mandatory
    # arity, method_missing) stay interpreted. What each class compiles is in the
    # generated diagnostic (`== compiled entry points ==`), not listed here.
    #
    # Embedding is decided by bc2cpp.rb's drop_unsafe_embeddings, never here.
    # Plain native attr readers/writers can be replaced by direct slot accessors.
    # #initialize is always private in mruby, so it registers with
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
    owners: bc2cpp_gem_owners('mruby-lcf', reopened: %w[StringIO]),
    out_symbol: 'lcf_compiled',
    native_namespaces: %w[LCF],
  },
  'mruby-rpg2k-compiled' => {
    # Same rules as the mruby-lcf-compiled entry above. Points that are easy to
    # get wrong about the owners:
    #
    # - `.singleton` owners are the `def self.x`/`class << self` methods of a
    #   class or module; they register
    #   with mrb_define_class_method and never embed (class ivars live on a
    #   different object than any instance's iv_tbl).
    # - A compiled `#initialize` is required to allocate the RData payload. The
    #   diagnostic's `== ivar embedding ==`
    #   section prints IvarLayout's raw proposal, before that filter -- trust the
    #   "classes needing MRB_SET_INSTANCE_TT" section instead.
    # - Every statically named ivar on an embedding owner uses an mrb_value slot;
    #   dynamic names keep the ordinary iv_tbl fallback.
    # - A Struct's members are positional (mruby-struct), never iv_tbl, so
    #   Game::Battle::Combatant has nothing to embed. Its `half_sp_cost?`/
    #   `member?` sanitize to the same C name as the Struct-native writers, but
    #   those have irep nil and are never emitted, so no collision.
    # - A POLY name in the registry only stops other call sites devirtualizing
    #   into it; it never blocks registering the owner's own method.
    #
    # A module_function module owns its singleton too (GemOwners): compile_all
    # emits the shared bodies as the module's entries, which register on the module
    # and, when the body never observes self, on its singleton class too
    # (MODULE_FUNCTION_COPY).
    owners: bc2cpp_gem_owners('mruby-rpg2k'),
    out_symbol: 'rpg2k_compiled',
    native_namespaces: %w[Game RPG2k RPG2k3],
  },
  'mruby-rgss-compiled' => {
    # Same rules as above. Notes specific to RGSS:
    #
    # - RGSS::Window runs `alias_method :_rgss1_initialize, :initialize`; that is
    #   an SSEND, not OP_ALIAS, so the aliased name never enters the registry
    #   under any owner. A call to an alias_method-defined name therefore always
    #   stays ordinary dispatch (safe, just never devirtualized).
    # - RGSS::Graphics.singleton#brightness_sprite is private and compiles. mruby
    #   has no private class-method registration, so the generated
    #   bc2cpp_define_private_class_method installs it.
    # - Array is reopened by mruby-rgss/mrblib/array_include.rb (an index-loop
    #   #include?). Its POLY collision with native Module#include? is by bare
    #   name only, and `add_dependency 'mruby-rgss'` runs the reopening before
    #   the compiled override is installed -- the same reasoning as StringIO in
    #   mruby-lcf-compiled.
    owners: bc2cpp_gem_owners('mruby-rgss', reopened: %w[Array]),
    out_symbol: 'rgss_compiled',
    native_namespaces: %w[RGSS],
  },
  'mruby-core-compiled' => {
    # mruby's own Ruby (BC2CPP_CORE_MRBLIB_GEMS) compiled by the same
    # pipeline. Every eligible method (CoreMethods: not Fiber-naming, lambda-building,
    # conditional, shadowed or refused; the root-context guard covers the block-taking ones) is
    # emitted, and registered through the
    # generated bc2cpp_register_owner_methods
    # after the core gems that define the bytecode it replaces. Array and
    # StringIO are also engine owners: each gem emits the definitions of its own
    # source files (CodeGen#emit_unit_allows?).
    owners: BC2CPP_CORE_OWNERS,
    out_symbol: 'core_compiled',
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
  # Never built: mruby compiles only each gem's src/ (gem.rb srcs_to_objs)
  # into libmruby.a; test/ holds the mrbtest runner's helpers (ProcExtTest,
  # DirTest, binding_in_c, instance_exec_from_c on Kernel), which no shipped
  # VM contains. Scanning them registers phantom definers that can only flip
  # MONO to POLY or defeat a proof, never enable one.
  Dir["#{mruby_root}/src/*.c"] +
    Dir["#{mruby_root}/mrbgems/mruby-{array-ext,hash-ext,enum-ext,io,dir," \
        'numeric-ext,range-ext,symbol-ext,fiber,exit,sprintf,kernel-ext,random,math,time,bigint,' \
        "binding,eval,metaprog,method,pack,proc-ext,string-ext,struct}/**/*.c"]
      .reject { |path| path =~ %r{/(test|tools|bench|examples?|demos?|samples?)/} }
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

# The closed-world sources one build's codegen reads: the core mrblib of the gems the build really has, so an Array#each
# defined by mruby's own Ruby is in the registry and a proof can name it. Called from a codegen task, when the
# gem list is complete.
def bc2cpp_closed_world_srcs(spec, gems_root)
  core_gems = spec.build.gems.map(&:name)
  closed_world_mrblib_srcs(gems_root, core_gems: core_gems, tts: RgssTtsConfig.backend_possible?(spec.build.name))
end

# mruby-rgss's native sources as the build compiles them: tts.cxx only where a
# RGSS::Tts backend can exist; the other builds compile
# tts_off.cxx, which registers nothing. A native registration
# the build does not have must not shape the registry (bare-name POLY
# collisions on `stop`/`speak`/`available?`), so it is left out of NATIVE_SRCS.
def bc2cpp_rgss_native_srcs(gems_root, build_name)
  srcs = Dir["#{gems_root}/mruby-rgss/src/*.cxx"]
  return srcs if RgssTtsConfig.backend_possible?(build_name)

  srcs.reject { |path| path.end_with?("/#{File.basename(RgssTtsConfig::RGSS_TTS_CXX)}") }
end

# Every file bc2cpp_closed_world_srcs can name, for make prerequisites (fixed
# before the gem list is complete).
def bc2cpp_closed_world_prerequisites(gems_root)
  core = BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS
  (closed_world_mrblib_srcs(gems_root, core_gems: core, tts: true) +
    closed_world_mrblib_srcs(gems_root, core_gems: core, tts: false)).uniq
end

# The whole-program mrblib source set every *-compiled mrbgem.rake feeds into
# bc2cpp.rb as `closed_world_srcs`, so build_registry's MONO/POLY resolution
# sees every gem that could define a colliding name (e.g.
# `LCF::Database#rpg2003?` is MONO in isolation but not with Game::Actor/
# Party/Battle#rpg2003?). Shared here so the gems cannot drift apart: a
# drifted set fails silently, with different MONO/POLY conclusions per gem.
#
# `tts`: whether the build can have a RGSS::Tts backend (RgssTtsConfig). The canonical world is the closed build's, which cannot: Scene::Map#speak_message is
# then mruby-rpg2k/mrblib_limited/map_tts_off.rb, which mruby-rpg2k/mrbgem.rake
# also swaps in for that build, and no Ruby names RGSS::Tts. A desktop world
# keeps scene/map_tts.rb.
def closed_world_mrblib_srcs(gems_root, core_gems: :canonical, tts: false)
  # Sorted: Dir[] returns filesystem order (ext4 vs APFS disagree), and
  # bc2cpp's capped fixed-point sweeps converge order-dependently, so ARGV order
  # changes devirtualization. A canonical order makes every consumer agree; the
  # analyses' own order-sensitivity is a separate bug, not fixed by this.
  #
  # The core files come first (core_compiled_mrblib_srcs): the interpreter
  # defines them before any gem's mrblib, and a reopening gem (mruby-rgss's
  # Array#include?) must follow the file it reopens. `core_gems`: the build's
  # gem names, :canonical, or nil for a build that compiles no core Ruby.
  # RITE carries these filenames; gem/.. aliases must not give identical worlds different cache keys.
  rpg2k = Dir["#{gems_root}/mruby-rpg2k/mrblib/**/*.rb"]
  unless tts
    rpg2k.reject! { |path| path.end_with?("/#{RgssTtsConfig::RPG2K_TTS_RB.delete_prefix('mruby-rpg2k/')}") }
    # After every mrblib/ file, as mrbgem.rake appends it (the sort below keeps it there).
    rpg2k << "#{gems_root}/#{RgssTtsConfig::RPG2K_TTS_OFF_RB}"
  end
  (core_compiled_mrblib_srcs(gems_root, core_gems) +
    (rpg2k + Dir["#{gems_root}/mruby-lcf/mrblib/*.rb"] +
      Dir["#{gems_root}/mruby-rgss/mrblib/*.rb"]).sort).map { |path| File.expand_path(path) }
end

# `gem_names`: names of the gems in the build (:canonical: BC2CPP_CANONICAL_CORE_GEMS,
# nil: none). Order is the interpreter's: mrblib/*.rb sorted, then each gem's
# mrblib/**/*.rb sorted, gems in BC2CPP_CORE_MRBLIB_GEMS order.
def core_compiled_mrblib_srcs(gems_root, gem_names = :canonical)
  return [] if gem_names.nil?

  gem_names = BC2CPP_CANONICAL_CORE_GEMS if gem_names == :canonical
  srcs = Dir["#{gems_root}/3rd/mruby/mrblib/*.rb"].sort
  BC2CPP_CORE_MRBLIB_GEMS.each do |name|
    srcs += Dir["#{gems_root}/3rd/mruby/mrbgems/#{name}/mrblib/**/*.rb"].sort if gem_names.include?(name)
  end
  srcs.reject! { |path| BC2CPP_CORE_MRBLIB_EXCLUDED.any? { |tail| path.end_with?("/3rd/mruby/#{tail}") } }
  BC2CPP_EXTERNAL_MRBLIB_GEMS.each do |name|
    srcs += Dir["#{gems_root}/3rd/#{name}/mrblib/**/*.rb"].sort if gem_names.include?(name)
  end
  srcs
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
    Dir["#{gems_root}/3rd/mruby/mrbgems/*/mrblib/**/*.rb"].reject do |path|
      BC2CPP_PROGRAM_CORE_MRBLIB_GEMS.any? { |gem| path.include?("/mrbgems/#{gem}/mrblib/") } &&
        BC2CPP_CORE_MRBLIB_EXCLUDED.none? { |tail| path.end_with?("/3rd/mruby/#{tail}") }
    end +
    Dir["#{gems_root}/3rd/mruby-marshal/mrblib/**/*.rb"] +
    Dir["#{gems_root}/3rd/mruby-onig-regexp/mrblib/**/*.rb"] +
    Dir["#{gems_root}/3rd/mruby-stringio/mrblib/**/*.rb"]
end

# CORE_COMPARE: every core mrbgem's mrblib, program core included. foreign_mrblib_srcs leaves out
# mruby-hash-ext, but its Hash subset tests are the other Ruby definers of `< <= > >=` the operator model expects.
def core_mrbgem_mrblib_srcs(gems_root)
  Dir["#{gems_root}/3rd/mruby/mrbgems/*/mrblib/**/*.rb"]
end

# CLOSED_WORLD: the builds that ship RPG2000/2003 only
# (build_config.rb's single_format_only). Their games carry no Ruby, so the
# only Ruby that can run is the closed world plus the build's own gems.
# The standalone Optcarrot benchmark seals its host separately.
# bc2cpp compiles these builds only; every other build, and any
# build with a gem below, is the plain mruby build.
# `closed` is the closed world built natively for CI (build_config.rb).
BC2CPP_CLOSED_WORLD_BUILDS = %w[closed optcarrot-probe wio].freeze
# Gems that load or define Ruby at runtime; any of them opens the world.
BC2CPP_OPEN_WORLD_GEMS = %w[
  mruby-rpgxp mruby-rpgvx mruby-wolf mruby-mvjs mruby-eval mruby-binding mruby-proc-binding
  mruby-bin-mirb mruby-bin-mruby mruby-bin-debugger
].freeze
# The gems whose mrblib is the closed world itself, read from build_config.rb's
# rpg_maker_gems (the unconditional maker-gem lines; see bc2cpp_build_config_closed_world_gems).
BC2CPP_BUILD_CONFIG = File.expand_path('../../build_config.rb', __dir__).freeze

# The build_config.rb text, read at load time; a missing file is an error, never an empty list.
def bc2cpp_build_config_text(path = BC2CPP_BUILD_CONFIG)
  raise "bc2cpp: #{path} is missing; the closed-world gem list is derived from it" unless File.file?(path)

  File.read(path, encoding: 'UTF-8')
end

# Top-level (2-space) `conf.gem "#{MRUBY_ROOT}/../../mruby-X"` lines of rpg_maker_gems. Lines under
# `unless single_format_only` are indented 4 and the `-compiled` opt-ins end in `&closed_world`, so neither matches.
def bc2cpp_build_config_closed_world_gems(text)
  body = text[/^def rpg_maker_gems\(.*?\n(?=^end$)/m]
  raise "bc2cpp: no rpg_maker_gems definition in #{BC2CPP_BUILD_CONFIG}" if body.nil?

  gems = body.scan(/^  conf\.gem "\#\{MRUBY_ROOT\}\/\.\.\/\.\.\/(mruby-[a-z0-9-]+)"\s*$/).flatten
  raise "bc2cpp: found no closed-world gem lines in #{BC2CPP_BUILD_CONFIG}" if gems.empty?

  gems.freeze
end

BC2CPP_CLOSED_WORLD_GEMS = bc2cpp_build_config_closed_world_gems(bc2cpp_build_config_text).freeze

BC2CPP_GEMS_ROOT = File.expand_path('../..', __dir__)

# CLOSED_CORE_GEMS (nomethod_reviewed_probe.rb) is derived, not listed: the core gems the closed build loads. Inputs are
# rpg_maker_gems' conf.gem lines for 'closed' (build_config.rb, as a Prism AST), the compiled gems, and each reached
# gem's non-test add_dependency edges, transitively. Every condition is evaluated or raises; nothing is guessed.
def bc2cpp_find_def(node, name)
  return node if node.is_a?(Prism::DefNode) && node.name == name

  node.compact_child_nodes.each do |child|
    found = bc2cpp_find_def(child, name)
    return found if found
  end
  nil
end

def bc2cpp_gem_call_in?(node)
  return true if node.is_a?(Prism::CallNode) && node.name == :gem

  node.compact_child_nodes.any? { |child| bc2cpp_gem_call_in?(child) }
end

# A condition of rpg_maker_gems for build `name`: `locals` maps a local to its value node, or to a plain value
# (bc2cpp, which the caller sets). Any shape not listed raises, so a misread condition cannot select gems silently.
def bc2cpp_rpg_maker_pred(node, name, locals)
  case node
  when Prism::ParenthesesNode
    bc2cpp_rpg_maker_pred(node.body.body.first, name, locals)
  when Prism::AndNode
    bc2cpp_rpg_maker_pred(node.left, name, locals) && bc2cpp_rpg_maker_pred(node.right, name, locals)
  when Prism::LocalVariableReadNode
    value = locals.fetch(node.name) { raise "bc2cpp: rpg_maker_gems reads unknown local #{node.name}" }
    value.is_a?(Prism::Node) ? bc2cpp_rpg_maker_pred(value, name, locals) : value
  when Prism::CallNode
    receiver = node.receiver
    arg = node.arguments&.arguments&.first
    includes_build_name = node.name == :include? && receiver.is_a?(Prism::ArrayNode) &&
                          arg.is_a?(Prism::CallNode) && arg.name == :name
    if includes_build_name
      receiver.elements.map(&:unescaped).include?(name)
    elsif %i[== !=].include?(node.name) && receiver.is_a?(Prism::CallNode) && receiver.name == :name
      (name == node.arguments.arguments.first.unescaped) == (node.name == :==)
    else
      raise "bc2cpp: unsupported rpg_maker_gems condition call #{node.name}"
    end
  else
    raise "bc2cpp: unsupported rpg_maker_gems condition #{node.class}"
  end
end

# The conf.gem lines of rpg_maker_gems that build `name` gets, as { gem name => dir } in source order.
# bc2cpp is off here: the compiled gems come from BC2CPP_COMPILED_GEMS, the caller's list.
def bc2cpp_rpg_maker_gem_lines(text, name, root)
  defn = bc2cpp_find_def(Prism.parse(text).value, :rpg_maker_gems)
  raise "bc2cpp: no rpg_maker_gems definition in #{BC2CPP_BUILD_CONFIG}" unless defn

  locals = {}
  (defn.body&.body || []).each { |s| locals[s.name] = s.value if s.is_a?(Prism::LocalVariableWriteNode) }
  locals[:bc2cpp] = false
  out = {}
  walk = lambda do |stmts|
    stmts&.body&.each do |s|
      if s.is_a?(Prism::IfNode) || s.is_a?(Prism::UnlessNode)
        next unless bc2cpp_gem_call_in?(s)

        if s.is_a?(Prism::IfNode)
          sub = s.subsequent
          raise 'bc2cpp: elsif in rpg_maker_gems is unsupported' if sub.is_a?(Prism::IfNode)

          walk.call(bc2cpp_rpg_maker_pred(s.predicate, name, locals) ? s.statements : sub&.statements)
        else
          walk.call(bc2cpp_rpg_maker_pred(s.predicate, name, locals) ? s.else_clause&.statements : s.statements)
        end
      elsif s.is_a?(Prism::CallNode) && s.name == :gem && s.receiver.is_a?(Prism::LocalVariableReadNode) &&
            s.receiver.name == :conf
        arg = s.arguments.arguments.first
        if arg.is_a?(Prism::KeywordHashNode)
          core = arg.elements.find { |e| e.key.unescaped == 'core' }
          raise 'bc2cpp: conf.gem core: without a name in rpg_maker_gems' unless core

          out[core.value.unescaped] = File.join(root, '3rd/mruby/mrbgems', core.value.unescaped)
        elsif arg.is_a?(Prism::InterpolatedStringNode)
          text = arg.parts.map { |p| p.is_a?(Prism::EmbeddedStatementsNode) ? '3rd/mruby' : p.unescaped }.join
          path = File.expand_path(text, root)
          out[File.basename(path)] = path
        else
          raise "bc2cpp: unsupported conf.gem argument #{arg.class} in rpg_maker_gems"
        end
      end
    end
  end
  walk.call(defn.body)
  raise "bc2cpp: rpg_maker_gems yields no gem for build '#{name}'" if out.empty?

  out
end

# The non-test add_dependency names of a mrbgem.rake. add_test_dependency is not built, so it is not followed.
# A `Dir.exist?` modifier (mruby-marshal's metaprog) is evaluated, and an `unless %w[...].include?(build.name)`
# modifier drops the gem for the closed build; any other modifier raises.
def bc2cpp_rake_dependencies(dir, root)
  rake = File.join(dir, 'mrbgem.rake')
  raise "bc2cpp: #{rake} is missing; the closed-world gem closure is derived from it" unless File.file?(rake)

  File.read(rake, encoding: 'UTF-8').each_line.filter_map do |line|
    match = line.match(/^\s*(?:spec\.)?add_dependency[ (]\s*['"](mruby-[\w-]+)['"]/) or next
    if (cond = line[/\bif\s+Dir\.exist\?\s+"\#\{MRUBY_ROOT\}\/mrbgems\/([\w-]+)"/, 1])
      next unless File.directory?(File.join(root, '3rd/mruby/mrbgems', cond))
    elsif (excluded = line[/\bunless\s+%w\[([^\]]*)\]\.include\?\(build\.name\)/, 1])
      # The closure is always the closed build's, so a gem its list names is left out.
      next if excluded.split.include?('closed')
    elsif line.match?(/\b(?:if|unless)\b/)
      raise "bc2cpp: unsupported add_dependency condition in #{rake}: #{line.strip}"
    end
    match[1]
  end
end

def bc2cpp_gem_dir(name, root)
  dirs = [File.join(root, '3rd/mruby/mrbgems', name), File.join(root, name), File.join(root, '3rd', name)]
  dirs.find { |d| File.file?(File.join(d, 'mrbgem.rake')) } ||
    raise("bc2cpp: no mrbgem.rake for #{name} (is its submodule initialised?)")
end

# { name => dir } of `roots` and everything they reach. `extra` adds the edges a rake builds in Ruby.
def bc2cpp_gem_closure(roots, root, extra = {})
  table = {}
  queue = roots.to_a
  until queue.empty?
    name, dir = queue.shift
    next if table.key?(name)

    table[name] = dir
    (bc2cpp_rake_dependencies(dir, root) + extra.fetch(name, [])).each do |dep|
      queue << [dep, bc2cpp_gem_dir(dep, root)]
    end
  end
  table
end

# mruby-core-compiled names its deps in two loops, not literal add_dependency lines. Both loops must be present,
# so a rewritten loop raises here rather than drifting from this mirror. dir and onig count only if the build has them.
def bc2cpp_core_compiled_edges(root, build_names)
  text = File.read(File.join(root, 'mruby-core-compiled/mrbgem.rake'), encoding: 'UTF-8')
  literal = text[/%w\[([^\]]+)\]\.each \{ \|gem_name\| add_dependency gem_name \}/, 1]
  raise 'bc2cpp: mruby-core-compiled/mrbgem.rake lost its add_dependency loop' unless literal
  unless text.include?('(BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem_name|') &&
         text.include?('next if %w[mruby-dir mruby-onig-regexp].include?(gem_name) && spec.build.gems.none?')
    raise 'bc2cpp: mruby-core-compiled/mrbgem.rake lost its mrblib loop'
  end

  literal.split + (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).reject do |gem|
    %w[mruby-dir mruby-onig-regexp].include?(gem) && !build_names.include?(gem)
  end
end

# The core gems (3rd/mruby/mrbgems) the closed build loads. Its build_config conf.gem lines and compiled gems are roots.
def bc2cpp_closed_core_gems(root = BC2CPP_GEMS_ROOT)
  lines = bc2cpp_rpg_maker_gem_lines(bc2cpp_build_config_text, 'closed', root)
  roots = lines.merge(BC2CPP_COMPILED_GEMS.keys.to_h { |g| [g, File.join(root, g)] })
  edges = { 'mruby-core-compiled' => bc2cpp_core_compiled_edges(root, lines.keys) }
  core = bc2cpp_gem_closure(roots, root, edges).select { |_, dir| dir.start_with?("#{root}/3rd/mruby/mrbgems/") }.keys
  raise 'bc2cpp: the closed build derives no core gems' if core.empty?

  core.freeze
end
# The closed world's own native host sources: the sealed desktop host's (src/main.cxx and its engine).
BC2CPP_CLOSED_WORLD_HOST_SRCS = { 'closed' => 'src' }.freeze
# mruby-compiler entry points that turn a string or file into running Ruby.
BC2CPP_SOURCE_LOADER_CALL = /\b(?:mrb_load_n?string(?:_cxt)?|mrb_load_file(?:_cxt)?|mrb_load_exec|
                               mrb_parse_n?string|mrb_parse_file|mrb_load_detect_file_cxt)\s*\(([^;]*)/mx
BC2CPP_NATIVE_GLOB = '*.{c,cc,cpp,cxx,h,hh,hpp,hxx,inc}'

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

# A host source as a sealed build compiles it: the `#else` arm of `#ifdef RPG2K_SEALED_HOST` is dropped, so
# a loader call there (the desktop `--script` path) is unreachable. Only that macro is honoured; every other
# conditional is kept, so the guard still sees its code.
def bc2cpp_sealed_host_text(text)
  stack = []
  text.each_line.reject do |line|
    case line
    when /\A\s*#\s*ifdef\s+RPG2K_SEALED_HOST\b/ then stack.push(:sealed); false
    when /\A\s*#\s*if/ then stack.push(:other); false
    when /\A\s*#\s*else\b/ then stack[-1] = :sealed_dead if stack.last == :sealed; stack.last == :sealed_dead
    when /\A\s*#\s*endif\b/ then stack.pop; false
    else stack.include?(:sealed_dead)
    end
  end.join
end

def bc2cpp_host_native_srcs(build_name, repo_root)
  host = BC2CPP_CLOSED_WORLD_HOST_SRCS[build_name]
  host ? Dir["#{repo_root}/#{host}/**/#{BC2CPP_NATIVE_GLOB}"].sort : []
end

# Why `gems` ({name => dir}, the build's real gem list) cannot be treated as a
# closed world; empty when it can.
def bc2cpp_closed_world_violations(build_name, gems, repo_root, host_srcs: bc2cpp_host_native_srcs(build_name, repo_root), compiled_srcs: [])
  errors = []
  unless BC2CPP_CLOSED_WORLD_BUILDS.include?(build_name)
    errors << "build '#{build_name}' is not one of #{BC2CPP_CLOSED_WORLD_BUILDS.join('/')}"
  end
  required = build_name == 'optcarrot-probe' ? %w[optcarrot-benchmark optcarrot-compiled] : BC2CPP_CLOSED_WORLD_GEMS
  missing = required - gems.keys
  errors << "gem list lacks #{missing.join(', ')}" unless missing.empty?
  (gems.keys & BC2CPP_OPEN_WORLD_GEMS).each { |name| errors << "#{name} loads or defines Ruby at runtime" }
  if build_name == 'optcarrot-probe'
    errors << 'optcarrot-probe cannot include mruby-compiler' if gems.key?('mruby-compiler')
    benchmark = gems['optcarrot-benchmark']
    if benchmark
      ruby = Dir["#{benchmark}/mrblib/**/*.rb"].map { |p| File.expand_path(p) }
      inputs = compiled_srcs.map { |p| File.expand_path(p) }
      if ruby.empty? || !(ruby - inputs).empty?
        errors << 'optcarrot benchmark Ruby must be complete compiled input'
      end
      host = Dir["#{benchmark}/src/**/#{BC2CPP_NATIVE_GLOB}"]
      errors << 'optcarrot benchmark lacks a fixed native host' if host.empty?
      host.each do |path|
        if File.read(path).match?(/\bmrb_(?:load|parse)_\w*\s*\(/)
          errors << "#{path} loads Ruby at runtime; the benchmark must initialize fixed gem bytecode"
        end
      end
    end
  end
  # Without mruby-compiler no source string can be compiled at all; with it,
  # every host call must compile a fixed literal that defines nothing.
  if gems.key?('mruby-compiler')
    host_srcs.each do |path|
      text = bc2cpp_sealed_host_text(File.read(path, encoding: 'BINARY'))
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
  # The probe's program is its bundle alone (OptcarrotSealedBuild.bc2cpp_world): the core gems' mrblib, which a game
  # build compiles into its program (closed_world_mrblib_srcs), stays outside Ruby there.
  probe = build_name == 'optcarrot-probe'
  gems.each do |name, dir|
    next if BC2CPP_COMPILED_GEMS.key?(name)

    native += Dir["#{dir}/{src,core}/**/#{BC2CPP_NATIVE_GLOB}"]
    native.reject! { |path| path.end_with?("/#{RgssTtsConfig::RGSS_TTS_CXX}") } unless RgssTtsConfig.backend_possible?(build_name)
    ruby += Dir["#{dir}/mrblib/**/*.rb"] unless BC2CPP_CLOSED_WORLD_GEMS.include?(name) ||
                                               (!probe && BC2CPP_PROGRAM_CORE_MRBLIB_GEMS.include?(name)) ||
                                               (probe && name == 'optcarrot-benchmark')
  end
  [native.map { |p| File.expand_path(p) }.uniq.sort, ruby.map { |p| File.expand_path(p) }.uniq.sort]
end

# The bc2cpp environment for `spec`'s build: its name and gem list. bc2cpp is
# closed-world only, so a build that is not a closed world is
# an error here; build_config.rb adds the compiled gems to closed-world builds
# only. Called from the codegen task, once every gem (dependencies included) is
# in the build.
def bc2cpp_closed_world_env(spec, repo_root)
  require 'shellwords'
  gems = spec.build.gems.to_h { |g| [g.name, File.expand_path(g.dir)] }
  errors = bc2cpp_closed_world_violations(spec.build.name, gems, repo_root)
  unless errors.empty?
    raise "#{spec.name}: build '#{spec.build.name}' is not a closed world, and bc2cpp compiles closed-world " \
          "builds only (docs/adr/0466):\n  #{errors.join("\n  ")}"
  end

  { 'BC2CPP_BUILD_NAME' => spec.build.name, 'BC2CPP_COLLECTION_EXPORTS' => '1',
    'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |name, dir| "#{name}=#{dir}" }) }
end

# SHARED_GENERATION: the bc2cpp.rb run of compiled gem `spec` -- [environment, sources, generated file],
# exactly what each *-compiled/mrbgem.rake used to build inline. Called from a codegen task, once the gem list is
# complete.
def bc2cpp_compiled_gem_job(spec, gems_root)
  require 'shellwords'
  this_gem = BC2CPP_COMPILED_GEMS.fetch(spec.name)
  other_gems = BC2CPP_COMPILED_GEMS.reject { |name, _| name == spec.name }
  native_srcs = bc2cpp_rgss_native_srcs(gems_root, spec.build.name) + core_native_srcs("#{gems_root}/3rd/mruby") +
                external_gem_native_srcs(gems_root)
  env = {
    'MRBC' => spec.build.mrbcfile.to_s,
    'OUT_SYMBOL' => this_gem[:out_symbol],
    'OUT_DIR' => spec.build_dir,
    'ONLY_OWNERS' => this_gem[:owners].join(','),
    # Every other compiled gem's owners and declarations: a direct call here may reference their `_impl`s.
    'OTHER_OWNERS' => other_gems.values.flat_map { |g| g[:owners] }.join(','),
    'OTHER_DECLS_HEADER' => Shellwords.join(other_gems.map { |name, g| "#{spec.build.build_dir}/mrbgems/#{name}/#{g[:out_symbol]}_decls.h" }),
    'NATIVE_SRCS' => Shellwords.join(native_srcs),
    'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(gems_root)),
    # A `#error` the toolchain compiles halts the build: a method bc2cpp cannot compile is not emitted and keeps
    # running interpreted.
    'SKIP_UNSUPPORTED' => '1',
    # BC2CPP_ENTRY: <symbol>_entry.h also goes to the build's include directory (the include path every host of this
    # libmruby already has), so `#include <bc2cpp_entry.hxx>` finds it with `__has_include`.
    'BC2CPP_ENTRY_INCLUDE_DIR' => "#{spec.build.build_dir}/include"
  }.merge(bc2cpp_closed_world_env(spec, gems_root))
  env['BC2CPP_SHARDS'] = bc2cpp_gem_shards.to_s
  env['BC2CPP_LOAD_WORLD'] = bc2cpp_load_world(spec) if ENV.fetch('BC2CPP_LOAD_COMPILE', 'defs') != 'off'
  [env, bc2cpp_closed_world_srcs(spec, gems_root), "#{spec.build_dir}/#{this_gem[:out_symbol]}_gen.cpp"]
end

# LOAD_COMPILE: {out_symbol => mrblib files} of the compiled gems in `spec`'s build whose base gem recorded its sources
# (bc2cpp_stub_mrblib), as JSON: the program a load plan splits. A gem that left them out takes no part.
def bc2cpp_load_world(spec)
  require 'json'
  world = spec.build.gems.each_with_object({}) do |gem, all|
    compiled = BC2CPP_COMPILED_GEMS["#{gem.name}-compiled"] or next
    next unless spec.build.gems.any? { |g| g.name == "#{gem.name}-compiled" }

    files = gem.instance_variable_get(:@bc2cpp_mrblib_sources) or next
    all[compiled[:out_symbol]] = files.map { |f| File.expand_path(f) }
  end
  JSON.generate(world)
end

# BC2CPP_SHARDS (docs/bc2cpp-shards.md): translation units per compiled gem, default 4 (the CI runners' cores). A
# gem with too little code for that many keeps fewer (ShardOutput::MIN_SHARD_BYTES); the rest are empty files.
def bc2cpp_gem_shards
  require_relative 'shard_output'
  ShardOutput.count(ENV.to_h.merge('BC2CPP_SHARDS' => ENV.fetch('BC2CPP_SHARDS', '4')))
end

# Adds shards 1...N-1 of `generated` to `spec`'s objects. The bc2cpp run that writes `generated` writes them, and
# each includes `generated`, so they depend on it and on `prereqs` (what `generated` includes). `generated` depends
# on a stamp holding N, so a changed BC2CPP_SHARDS regenerates instead of leaving a shard file missing.
def bc2cpp_compiled_gem_shards(spec, generated, prereqs)
  require 'fileutils'
  shards = bc2cpp_gem_shards
  stamp = File.join(spec.build_dir, 'bc2cpp_shards')
  FileUtils.mkdir_p(spec.build_dir)
  File.write(stamp, "#{shards}\n") unless File.exist?(stamp) && File.read(stamp) == "#{shards}\n"
  Rake::Task[generated].enhance([stamp])
  symbol = File.basename(generated).delete_suffix('_gen.cpp')
  (1...shards).each do |index|
    src = ShardOutput.shard_path(spec.build_dir, symbol, index)
    file src => [generated, *prereqs] do |t|
      raise "#{t.name} is missing after #{generated} was written (docs/bc2cpp-shards.md)" unless File.exist?(t.name)
    end
    spec.objs << src.ext(spec.build.exts.object)
  end
end

# Generates `spec`'s file together with every other compiled gem of the same build whose file is out of date, in one
# bc2cpp.rb process per group of gems that analyse the same program (same sources, same environment but for
# SharedGeneration::UNIT_KEYS). Rake -m runs the gems' codegen tasks concurrently: the first to arrive generates the
# group, the others find their file done.
module Bc2cppCompiledGemGeneration
  @mutex = Mutex.new
  @done = {}

  module_function

  def generate(spec, gems_root)
    require 'rake'
    require 'json'
    require_relative 'shared_generation'
    extend Rake::FileUtilsExt unless singleton_class.include?(Rake::FileUtilsExt)
    _, _, generated = bc2cpp_compiled_gem_job(spec, gems_root)
    @mutex.synchronize do
      next if @done[generated]

      specs = spec.build.gems.select do |g|
        next true if g.equal?(spec)
        next false unless BC2CPP_COMPILED_GEMS.key?(g.name)

        task = Rake::Task.task_defined?(bc2cpp_compiled_gem_job(g, gems_root)[2]) &&
               Rake::Task[bc2cpp_compiled_gem_job(g, gems_root)[2]]
        task && task.needed? && !@done[task.name]
      end
      jobs = specs.map { |g| bc2cpp_compiled_gem_job(g, gems_root) }
      jobs.group_by { |env, srcs, _| [env.reject { |k, _| SharedGeneration::UNIT_KEYS.include?(k) }, srcs] }
          .each { |(common, srcs), group| run_group(common, srcs, group, gems_root) }
    end
  end

  # GC_TUNING: one generation keeps about 6 million live objects, and Ruby's default heap grows in small steps, so
  # GC ran about 250 times (35 of them major) for ~21 s of a ~140 s run. Starting larger with higher malloc limits
  # halves the count for ~45 MB more peak memory; the generated code is unchanged. A RUBY_GC_* the caller set wins.
  GC_ENV = {
    'RUBY_GC_HEAP_0_INIT_SLOTS' => '4000000', 'RUBY_GC_HEAP_1_INIT_SLOTS' => '1000000',
    'RUBY_GC_HEAP_2_INIT_SLOTS' => '500000', 'RUBY_GC_HEAP_GROWTH_FACTOR' => '2.0',
    'RUBY_GC_MALLOC_LIMIT' => '268435456', 'RUBY_GC_MALLOC_LIMIT_MAX' => '1073741824',
    'RUBY_GC_OLDMALLOC_LIMIT' => '1073741824', 'RUBY_GC_OLDMALLOC_LIMIT_MAX' => '4294967296'
  }.freeze

  def gc_env
    GC_ENV.reject { |key, _| ENV.key?(key) }
  end

  def run_group(common, srcs, group, gems_root)
    bc2cpp = File.join(gems_root, 'tools/bc2cpp/bc2cpp.rb')
    group.each { |env, _, _| FileUtils.mkdir_p(env.fetch('OUT_DIR')) }
    return stub_group(group) if ENV['BC2CPP_STUB_GENERATION'] == '1'

    if group.size == 1
      env, _, generated = group.first
      sh env.merge(gc_env), "#{RbConfig.ruby.shellescape} #{bc2cpp.shellescape} #{srcs.map(&:shellescape).join(' ')} > #{generated.shellescape}"
    else
      plan = "#{group.first[2]}.units.json"
      units = group.map do |env, _, generated|
        { 'env' => env.slice(*SharedGeneration::UNIT_KEYS), 'out' => generated, 'err' => "#{generated}.stderr" }
      end
      File.write(plan, JSON.generate(units))
      sh common.merge(SharedGeneration::UNIT_KEYS.to_h { |k| [k, nil] }, gc_env),
         "#{RbConfig.ruby.shellescape} #{bc2cpp.shellescape} #{SharedGeneration::FLAG} #{plan.shellescape} " \
         "#{srcs.map(&:shellescape).join(' ')}"
      FileUtils.rm_f([plan, *units.map { |unit| unit['err'] }])
    end
    group.each { |_, _, generated| @done[generated] = true }
  end

  # BC2CPP_STUB_GENERATION (scripts/bc2cpp/closed_build.bash, phase 1): that phase builds only the presym list, which
  # needs every source to preprocess, not the generated code; the native-kind analysis that follows reads its own
  # presym overlay (analysis_headers.rb). Each output bc2cpp.rb would write is an empty stub instead, marked so a stub
  # left behind is recognisable; phase 2 deletes the stub `_gen.cpp` files and generates for real.
  STUB = "// BC2CPP_STUB_GENERATION: placeholder for closed_build.bash phase 1\n"

  def stub_group(group)
    group.each do |env, _, generated|
      symbol = env.fetch('OUT_SYMBOL')
      headers = [File.join(env.fetch('OUT_DIR'), "#{symbol}_decls.h"), File.join(env.fetch('OUT_DIR'), "#{symbol}_entry.h")]
      headers << File.join(env['BC2CPP_ENTRY_INCLUDE_DIR'], "#{symbol}_entry.h") if env['BC2CPP_ENTRY_INCLUDE_DIR']
      shards = (1...Integer(env.fetch('BC2CPP_SHARDS', '1'))).map { |k| ShardOutput.shard_path(env.fetch('OUT_DIR'), symbol, k) }
      [generated, *headers, *shards].each do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, STUB)
      end
      # An empty manifest: phase 1's mrblib keeps every body (MRBLIB_STUBS).
      File.write(MrblibStubs.manifest_path(env.fetch('OUT_DIR'), symbol), '')
      File.write(File.join(env.fetch('OUT_DIR'), "#{symbol}_load.json"), '{}')
      @done[generated] = true
    end
  end
end

# The compiled gem whose registration removes `owner`'s left-out native methods, or nil (NATIVE_CANDIDATES).
def bc2cpp_native_strip_gem(owner)
  top = owner.delete_suffix('.singleton').split('::').first
  BC2CPP_COMPILED_GEMS.find { |_name, gem| Array(gem[:native_namespaces]).include?(top) }&.first
end

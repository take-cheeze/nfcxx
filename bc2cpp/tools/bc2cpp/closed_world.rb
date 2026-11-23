# frozen_string_literal: true

require_relative 'regexp_matches'
require 'set'
require_relative 'compiled_gems'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'touch_scan'
require_relative 'core_hierarchy_sigs'
require_relative 'foreign_definers'
require_relative 'core_defs'
require_relative 'native_names'
require_relative 'native_direct'
require_relative 'dynamic_names'
require_relative 'loop_installers'
require_relative 'scan_cache'
require_relative 'send_names'
require_relative 'factory_flow'
require_relative 'bytecode_ir_ops'
require_relative 'outside_singletons'

# CLOSED_WORLD: bc2cpp compiles closed-world builds only, where the only Ruby that
# can ever run is the closed world bc2cpp compiles, plus the scanned core and
# native sources of the build's own gems (compiled_gems.rb enforces that). A
# guard chain's by-name fallback can then call bc2cpp_nomethod, which raises
# exactly what mruby's dispatch raises, when this proves the receiver of that
# fallback can answer the name neither by a method nor by method_missing.
#
# Every question defaults to "refuse"; `refusal` returns the reason as a Symbol.
class ClosedWorld
  # method_missing/respond_to_missing? here reach every receiver.
  GLOBAL_HOOK_OWNERS = CoreHierarchySigs.ancestors('Object')
  BOOT_CLASSES = %w[BasicObject Object Module Class Kernel].freeze
  # Sends that define methods the registry walk may not attribute to an owner.
  INSTALLER_SENDS = %w[attr_reader attr_writer attr_accessor attr define_singleton_method].freeze
  MIXIN_SENDS = %w[include prepend extend].freeze
  # Sends that change a method's visibility by name (NATIVE_EXACT_DIRECT).
  VISIBILITY_SENDS = SendNames::VISIBILITY_SENDS
  # Sends that rebind a constant a guard chain resolves.
  CONST_REBINDERS = SendNames::CONST_REBINDERS
  # Constants whose `.new` makes a class (or members) the registry cannot see (SendNames).
  CLASS_FACTORIES = SendNames::CLASS_FACTORIES
  SEND_OPS = BytecodeIR::Ops::SEND
  # Ops whose operand names a method (ALIAS, UNDEF) or a symbol that may be one (LOADSYM).
  NAME_BINDING_OPS = Set[:ALIAS, :UNDEF, :LOADSYM].freeze
  # Writers of a class body's lexical scope: nil at top level (LOADNIL) or Object (OCLASS).
  CLASS_SCOPE_WRITERS = Set[:LOADNIL, :OCLASS].freeze
  C_STRING = /"((?:[^"\\\n]|\\.)*)"/
  # Native code that asks Ruby to define, alias or eval by name.
  NATIVE_DYNAMIC = /"(?:define_method|define_singleton_method|attr_reader|attr_writer|attr_accessor|attr|
                     alias_method|module_eval|class_eval|instance_eval|include|extend|prepend|
                     undef_method|remove_method)"|
                    MRB_SYM\((?:define_method|define_singleton_method|attr_\w+|alias_method|\w+_eval|
                     undef_method|remove_method)\)|
                    \bmrb_(?:alias_method|undef_method|remove_method|include_module|prepend_module)\b/x
  # REMOVED_NAMES: sends that remove a method by name. `send` and friends forward their first argument as the name.
  REMOVER_SENDS = %w[undef_method remove_method].freeze
  NAME_FORWARDERS = %w[send __send__ public_send].freeze
  # mruby core's own computed definitions only ever run for a Ruby-level
  # attr_*/define_method/alias/Struct.new, which scan_closed_world tracks.
  NATIVE_CORE = %r{/3rd/mruby/(?:src|mrbgems)/}
  # A definer word right after `:` is a Symbol literal (`member: :attr_reader`), never a call.
  RUBY_DYNAMIC = /(?<!:)\b(?:define_method|define_singleton_method|alias_method|attr_reader|attr_writer|attr_accessor)
                  \b[ \t]*\(?[ \t]*(?![:"'\s])/x
  RUBY_CONST_DYNAMIC = /\b(?:const_set|remove_const)\b/
  # DYNAMIC_NAME_LOOPS: a definer whose name is an interpolated Symbol (`alias_method :"x_#{v}", v`) is dynamic too.
  RUBY_DYNAMIC_SYMBOL = /\b(?:define_method|define_singleton_method|alias_method)\b[ \t]*\(?[ \t]*:"[^"\n]*#\{/
  # The definers a loop can enumerate, with the name argument they define (a loop variable, or a Symbol built from one).
  RUBY_DEFINER_ARG = /\b(?:define_method|define_singleton_method|alias_method)\b[ \t]*\(?[ \t]*
                      (?:(?<var>[a-z_]\w*)\b(?![ \t]*\()|:"(?<dsym>[^"\n]*)")/x
  # The head of a block over a constant or an inline %i[] / %w[] literal, with its loop variable.
  RUBY_LOOP_HEAD = /(?:\b(?<const>[A-Z]\w*)|%[iw]\[(?<words>[^\]]*)\])\.each\s*(?:do|\{)\s*\|\s*(?<var>[a-z_]\w*)(?:\s*,\s*\w+)?\s*\|/
  CLONE_SPELLING = /\bmrb_obj_clone\b|"clone"|MRB_SYM\(clone\)/
  # Project native code that freezes an object, or asks Ruby to (registering a method named
  # `freeze` is not one).
  NATIVE_FREEZE = /\bmrb_obj_freeze\b|\bMRB_SET_FROZEN_FLAG\b|->\s*frozen\s*=(?!=)|
                   \bmrb_(?:funcall|check_funcall)\w*\s*\([^;]*(?:"freeze"|MRB_SYM\(freeze\))/x
  # What `x.freeze` leaves of a receiver that is one of these: a builtin value, never an instance of
  # a user class.
  FREEZE_LITERAL_WRITERS = %i[ARRAY ARRAY2 HASH STRING STRCAT RANGE_INC RANGE_EXC].freeze
  # Core iterators whose result on a builtin receiver is a new Array or Hash (fresh_builtin_result?).
  FRESH_BUILTIN_SENDS = %w[map collect select filter reject flat_map collect_concat sort sort_by to_a entries zip
                           uniq compact reverse].freeze
  # FRESH_BUILTIN_OPS: ops that leave a builtin value in their register when it held one. ARYCAT/ARYPUSH append to
  # the Array in place (vm.c; ARYCAT on nil stores a dup'd splat, anything else but an Array raises), and ADD on an
  # Array or a String sends `+` unless both are Strings, which must then be core's (fresh_builtin_names_core?).
  # BC2CPP_FRESH_FREEZE_OPS=0 refuses them.
  FRESH_BUILTIN_OPS = { ADD: '+', ARYCAT: nil, ARYPUSH: nil }.freeze
  # The receivers ADD may have: an Array or String literal, or an Array op's result. A Hash or Range has no `+`, so
  # method_missing would answer it.
  FRESH_ADD_RECEIVERS = %i[ARRAY ARRAY2 STRING STRCAT ADD ARYCAT ARYPUSH].freeze
  # Kernel methods that give an arbitrary receiver a singleton class (`extend` is a global
  # refusal already, see scan_send). OutsideSingletons::MAKERS repeats them.
  SINGLETON_MAKERS = %w[singleton_class define_singleton_method instance_eval instance_exec].freeze
  # A project native that makes a singleton class by hand.
  NATIVE_SINGLETON = /\bmrb_singleton_class(?:_ptr|_clone)?\b|\bmrb_define_singleton_method(?:_id)?\b|\bmrb_obj_extend\b/
  # A ROM table installed on a class object's singleton (`MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(k)),
  # table)` with `RClass* k`) is mrb_define_class_method's effect: no instance gets a singleton class.
  CLASS_OBJECT_TABLE = /MRB_MT_INIT_ROM\(\s*\w+\s*,\s*mrb_singleton_class_ptr\(\s*\w+\s*,\s*mrb_obj_value\(\s*(\w+)\s*\)\s*\)\s*,\s*\w+\s*\)/

  def self.without_class_object_tables(text)
    text.gsub(CLASS_OBJECT_TABLE) { |m| text.match?(/\bRClass\s*\*\s*#{Regexp.last_match(1)}\b/) ? ' ' : m }
  end

  RUBY_SINGLETON = /\b(?:#{SINGLETON_MAKERS.join('|')}|extend)\b|\bclass\s*<<|\bdef\s+(?!self\b)[a-z_]\w*\./
  # PROVEN_MISS: a name passed to one of these is probed for or looked up
  # by name, so a send of it is guarded, not a bug.
  PROBE_SENDS = %w[respond_to? respond_to_missing? method_defined? public_method_defined?
                   private_method_defined? instance_method method
                   instance_methods public_methods].freeze
  attr_reader :global_refusal, :native_paths, :ruby_paths
  # BLOCK_SELF_WORLD: BlockSelfWorld's result, set by bc2cpp.rb once every Ruby source is read. Until
  # then (and without it) every block counts as rebound.
  attr_accessor :block_self_world

  # With BC2CPP_PROFILE_TIMINGS=1, the resident memory (Linux) after a construction step, so a run shows where the
  # closed world's memory goes. Silent otherwise.
  def profile_mark(step)
    return unless ENV['BC2CPP_PROFILE_TIMINGS'] == '1'

    kb = begin
      File.read('/proc/self/status').lines.grep(/\AVmRSS:/).first.to_s.split[1].to_i
    rescue StandardError
      -1
    end
    warn format('BC2CPP_TIME   ClosedWorld.new %-24s rss %d MB', step, kb / 1024)
  end
  private :profile_mark

  def initialize(ireps:, registry:, class_decls:, walked:, native_paths:, ruby_paths:, module_names: Set.new, root_label: nil,
                 struct_classes: [], included: nil, prepended: nil, unknown_mixins: nil, constant_writes: nil)
    @ireps = ireps
    @module_names = module_names.to_set
    @root_label = root_label
    @clone_sent = false
    @clone_symbol_loads = []
    @registry = registry
    # STRUCT_CLASS_DECLS: a class body-level `X = Struct.new(:a, ...)` whose members the registry lists (struct_member_lists)
    # runs once, before main, and makes X a class below Struct. It is declared here as such, so its members (registered
    # definers of X) and the methods its block defines bind like any declared class's (see struct_class?).
    @struct_classes = struct_classes.to_set
    # QUALIFIED_REBINDS: the registry's class-body and top-level constant writes, [irep label, index] => the qualified
    # constant written (constant_assignment_sites). Such a write rebinds that path only; any other write rebinds every
    # constant of its bare name (rebound?).
    @constant_write_sites = (constant_writes || []).to_h { |site| [[site[:irep], site[:idx]], site[:name]] }
    @rebound_qualified = Hash.new(0)
    @rebound_bare = Set.new
    # MODULE_DEFINER_INCLUDERS: the registry's class-body mixins (owner => modules), or nil when the caller has none.
    @mixins = included && prepended ? merge_mixins(included, prepended) : nil
    @unknown_mixins = unknown_mixins
    # Without the registry's default block: a read of an undeclared name (derives_from_module_or_class?, the superclass walk)
    # must not add a key, or class_declared? answers true for it from then on (a module_function module's self was taken
    # for an instance, so its singleton copy got no arm and the module object fell to the nomethod else).
    @class_decls = {}.merge(class_decls)
    @struct_classes.each do |owner|
      @class_decls[owner] = [{ super: 'Struct', outer_nil: true, outer_qualified: false, struct: true }] unless @class_decls.key?(owner)
    end
    # DECLARED_CLASS_SET: the registry's class_decls is a default Hash, so a read of any name adds it with no
    # declaration; whether a module looked declared then depended on which scan read it first. opaque? asks this
    # fixed set: the classes with a declaration (and the struct classes above).
    @declared_classes = @class_decls.select { |_, decls| !decls.empty? }.keys.to_set
    @walked = walked
    @global_refusal = nil
    @outside_names = Set.new
    # NATIVE_INCLUDE: what non-core natives can include (native_include_facts). `open` when a native include or
    # method name is computed; `names` the modules a native includes by a spelled lookup; `alias` the names of a
    # native that binds a constant to a value that could be a module object.
    @outside_include_open = false
    @outside_include_names = Set.new
    @outside_alias_names = Set.new
    # (function, parameter index) pairs a native dispatches a method name through (native_include_facts).
    @outside_include_helpers = []
    # Names a native module_function or singleton method defines: a constant receiver answers them (Graphics.update).
    @native_singleton_names = Set.new
    @native_tokens = Set.new
    @native_other_literals = Set.new
    @ruby_tokens = {}
    @outside_ruby_names = Set.new
    @outside_name_paths = {}
    @native_code_tokens = {}
    @native_class_events = []
    @native_class_assigns = {}
    @outside_ruby_supers = Set.new
    @native_arms_name = nil
    @outside_owner_name = nil
    @ruby_paths = ruby_paths
    # Per outside file: the constants it can create, reopen, subclass or rebind
    @touches = []
    @unknown_defs = Set.new
    @unknown_def_sources = Hash.new { |h, k| h[k] = [] }
    @visibility_names = Set.new
    # VISIBILITY_SAME_BODY: the names some visibility send build_registry cannot fold into the definition names.
    @visibility_unresolved = Set.new
    @dynamic_visibility = false
    @rebound = Set.new
    @constant_write_counts = Hash.new(0)
    # Struct.new(*MEMBERS, keyword_init: true) sites: their member names are checked after the scan (resolve_struct_splats).
    @deferred_struct_splats = []
    # Modules named by a mixin whose target the analysis cannot place (resolve_deferred_mixin_modules).
    @deferred_mixin_modules = []
    # LOADSYM of an installer or rebinder name: [irep, index, register, name] (resolve_installer_symbol_loads).
    @installer_symbol_loads = []
    # LOADSYM of a name CodeGen's installed-name scan treats as an installer (symbol_load_proven?), same shape.
    @name_installer_loads = []
    @proven_symbol_loads = Set.new
    @class_constant_names = Set.new
    # CLASS ops that declare a name (not the root-level reopen of native_class_unshadowed?).
    @class_declared_names = Set.new
    # Outside plain `mrb_define_class(_id)(mrb, "N", mrb->object_class)` per name: a define that finds N already
    # bound to a class with that superclass returns it, so two of them bind one class (see native_class_unshadowed?).
    @outside_plain_class_defines = Hash.new(0)
    @deferred_constant_writes = Set.new
    @struct_factory_members = []
    @dynamic_constant_mutation = false
    @basic_object_referenced = false
    @singleton_makers = []
    @singleton_opens = []
    # INSTANCE_SINGLETON_TAINT: the singleton-making sends ([irep, idx, insn]) and maker Symbol loads ([irep, idx, reg])
    # of the closed world's own Ruby, and each outside Ruby source's placement (OutsideSingletons), nil when one
    # is not placed.
    @singleton_sends = []
    @singleton_symbol_loads = []
    @outside_singleton_taint = []
    @outside_singleton_modules = Hash.new { |h, k| h[k] = [] }
    @outside_open_modules = Set.new
    @outside_constant_writes = Set.new
    @outside_constant_write_counts = Hash.new(0)
    @dynamic_subclassed = Set.new
    @struct_factory_used = false
    @probed_names = Set.new
    # Set when a probe send's name is not one proven Symbol: any miss could then be the probed one.
    @dynamic_probe = false
    @outside_def_names = Set.new
    # DYNAMIC_NAME_LOOPS: the names outside Ruby defines through a literal-container loop, not as a computed name.
    @outside_dyn_names = Set.new
    # REMOVED_NAMES: literal names undefined or removed by the program; @dynamic_removal when one is computed.
    @removed_names = Set.new
    @dynamic_removal = false
    @freeze_possible = false
    @factory_read_names = Set.new
    @frozen_constants = Set.new
    @fresh_freeze_names = Set.new
    @memo = {}
    @desc_memo = {}
    @native_paths = native_paths
    scan_native(native_paths)
    profile_mark('scan_native')
    @outside_include_open ||= !helper_names_enumerable?
    scan_outside_ruby(ruby_paths)
    profile_mark('scan_outside_ruby')
    scan_closed_world
    profile_mark('scan_closed_world')
    build_hierarchy
    profile_mark('build_hierarchy')
    build_method_missing
    @opaque_touches = {} unless ENV['BC2CPP_CLOSED_OPACITY_INDEX'] == '0'
  end

  # nil when a fallback for `name` on a chain listing `listed` can only raise
  # NoMethodError, else why not. `self_owner` is the enclosing method's owner
  # when the receiver is its `self`; `installed` is CodeGen#symbol_installed_names.
  # INSTANCE_RECEIVER: `instances` names the exact classes the exact-class flow proves
  # the receiver holds (nil allowed), none a class or module object (CodeGen#receiver_instances).
  # CALL_FACTS: `scoped` says `instances` is the whole receiver set, so only its classes need an
  # arm, and `native_free` that no native or outside definer of `name` reaches any of them.
  def refusal(name, listed, self_owner, installed, instances: nil, scoped: false, native_free: false,
              instance_scope: false, singleton_arms: nil, method_missing_arms: nil)
    return @global_refusal if @global_refusal
    # PUBLIC_SEND_DISPATCH: Kernel#public_send checks its target's visibility against how it was itself called; run
    # through an owner call it reaches private and protected methods the VM's send refuses, so it keeps that send.
    return :visibility_send if name == 'public_send'
    return :dynamic_install if installed.nil? || installed.include?(name)
    return :unknown_definer if instance_scope ? instance_unknown_def?(name) : @unknown_defs.include?(name)
    # A native singleton function is one more outside owner, which the owner call names (`Graphics.singleton`).
    return :core_or_native if @native_singleton_names.include?(name) && @outside_owner_name != name
    return :core_or_native if @outside_names.include?(name) && !native_arms_lift?(name) &&
                              @outside_owner_name != name && !(scoped && native_free)

    reason, required = required_classes(name, instance_self?(self_owner) || !instances.nil?, singleton_arms)
    return reason if reason

    required &= instances.to_set if scoped && instances
    return :unlisted_class unless required.subset?(listed.to_set)
    # METHOD_MISSING_ARMS: an exact-class arm per method_missing class sends by name before this else is reached.
    return :method_missing_receiver unless method_missing_free?(self_owner, instances) ||
                                           method_missing_arms&.to_set&.superset?(@mm_classes)

    nil
  end

  # Source files of the Ruby `method_missing` definitions.
  def method_missing_files
    @registry.fetch('method_missing', []).reject { |d| d.owner == '<native>' }.filter_map { |d| @ireps[d.irep]&.file }.uniq
  end

  def method_missing_classes
    @mm_classes
  end

  # RECORD_HASH_PROOF: could a definer the registry cannot see (a computed
  # attr_*, an outside Ruby or native definition) install method +name+?
  def invisibly_definable?(name)
    @unknown_defs.include?(name) || @outside_ruby_names.include?(name) || @outside_names.include?(name)
  end

  # ESCAPE_ANALYSIS: can an installer the registry cannot enumerate (computed names) define
  # +name+? Outside Ruby sources are judged by the caller, which knows which ones it compiled itself.
  def unknown_definer?(name)
    @global_refusal ? true : @unknown_defs.include?(name)
  end

  # No Ruby code in the closed world defines or installs `respond_to_missing?`
  # (nor could an outside Ruby file), so Kernel#respond_to?'s hook call after a
  # method-table miss can only reach the core default, which answers false.
  def respond_to_missing_free?
    return false if @global_refusal || @unknown_defs.include?('respond_to_missing?')
    return false if @outside_ruby_names.include?('respond_to_missing?')

    @registry.fetch('respond_to_missing?', []).all? { |d| d.owner == '<native>' }
  end

  # The classes a chain listing `listed` must still guard for `refusal` to clear:
  # empty unless :unlisted_class is the only reason it refuses (and, since that
  # check runs first, the receiver is method_missing-free). Each returned class
  # answers `name` itself or inherits it, so a guarded send to it reaches its
  # definition and every other class can only raise NoMethodError.
  def unlisted_classes(name, listed, self_owner, installed, instances: nil, scoped: false, native_free: false,
                       instance_scope: false, singleton_arms: nil)
    return [] unless refusal(name, listed, self_owner, installed, instances: instances, scoped: scoped,
                                                                  native_free: native_free,
                                                                  instance_scope: instance_scope,
                                                                  singleton_arms: singleton_arms) == :unlisted_class
    return [] unless method_missing_free?(self_owner, instances)

    _reason, required = required_classes(name, instance_self?(self_owner) || !instances.nil?, singleton_arms)
    required &= instances.to_set if scoped && instances
    (required - listed.to_set).to_a.sort
  end

  # PROVEN_MISS: a send of `name` to a receiver PROVEN to be `klass` (or, for
  # kind :lexical_self, a descendant) reaches no definition and no method_missing, so
  # it can only raise NoMethodError. `installed` is CodeGen#symbol_installed_names.
  # Every question defaults to "not a miss": the answer only ever adds a build error.
  # PROBE_SENDS: a name passed to a probe is guarded, not a bug (see PROVEN_MISS). An unproven probe name
  # is conservative: the build keeps every proven miss, since the probed name could be any of them.
  def probed_name?(name)
    @dynamic_probe || @probed_names.include?(name)
  end

  # A module's or class object's `self` is never modelled here (instance_self?).
  # +label+ is the irep the send sits in: `self` there is its lexical owner unless a rebinder may run it under
  # another object. Any other compiled block keeps its creator's self,
  # by the world fact or, where that fails, by the entry check every compiled block body then carries.
  def proven_miss?(name, klass, installed, kind, label: nil)
    return false if @global_refusal || installed.nil? || installed.include?(name)
    return false if @unknown_defs.include?(name) || @outside_names.include?(name) ||
                    @outside_def_names.include?(name) || probed_name?(name)
    return false if %w[method_missing respond_to_missing? initialize].include?(name)

    reason, required = required_classes(name, kind != :constant_object)
    return false if reason

    # A class object also answers singleton definers and Class/Module/Object/Kernel ones,
    # which required_classes refuses (`reason`) for the non-instance lookup.
    return false if kind == :lexical_self && (lexical_self_rebound?(label) || !instance_self?(klass))
    return false if required.include?(klass) || descendants(klass).intersect?(required)

    # An exact receiver is klass itself, which no hook reaches unless klass is a listed
    # method_missing class; only `self` may also be a descendant.
    kind == :lexical_self ? method_missing_free?(klass) : !@mm_classes.include?(klass)
  end

  def lexical_self_rebound?(label)
    @block_self_world.nil? || label.nil? || @block_self_world.rebound.include?(label)
  end

  # A `class` (never a module) declared in the closed world: the only owners an
  # exact-class guard can name, since modules never are `mrb_obj_class`.
  def class_declared?(owner)
    @class_decls.key?(owner)
  end

  # A `module` declared in the closed world (its methods run with any includer as `self`).
  def module_declared?(name)
    @module_names.include?(name)
  end

  # CONSTRUCTOR_POOLS: every declared class whose last path segment is +name+, the
  # classes a constant of that name can denote when no SETCONST binds a value to it.
  def classes_named(name)
    @by_simple.fetch(name, [])
  end

  # An outside source (native code without its comments, or foreign Ruby) spells both the root and the last
  # segment of +klass+'s path: the pair that could reach the class object, the test `opaque?` applies to
  # sources that create, reopen or subclass it.
  def outside_spells_class?(klass)
    root = klass.split('::').first
    last = simple(klass)
    [@native_code_tokens, @ruby_tokens].any? { |files| files.each_value.any? { |tokens| tokens.include?(root) && tokens.include?(last) } }
  end

  # The identifier tokens of each scanned native source ({ path => Set }) and of each foreign Ruby source. Read-only
  # views for ENTRY_SEEDS, which must see exactly which outside files spell a name.
  def native_token_files = @native_code_tokens

  def foreign_ruby_token_files = @ruby_tokens

  # No const_set or remove_const anywhere and no global refusal: every constant binding is a visible
  # SETCONST/CLASS/MODULE or a scanned native/foreign definition (NUMERIC_CONSTANT_RANGES).
  def constants_static?
    !@global_refusal && !@dynamic_constant_mutation
  end

  # The constant +name+ can only name a class or module: no bytecode binds a value to it.
  def class_valued_constant?(name)
    !@global_refusal && !@dynamic_constant_mutation && class_constant?(name)
  end

  # PROGRAM_CLASS_SLOTS: the modules the closed world declares, and the superclasses its class declarations name.
  def declared_module_names
    @module_names
  end

  def declared_superclass_names
    @class_decls.each_value.flat_map { |decls| decls.map { |d| d[:super] } }.grep(String).uniq
  end

  # CALL_FACTS: the classes (never modules) the closed world declares.
  def declared_class_names
    @class_decls.keys.select { |k| !k.include?('.') && !k.include?('<') }
  end

  # Foreign Ruby sources the closed world scanned, and whether one defines +name+.
  def outside_ruby_paths
    @ruby_paths
  end

  def outside_ruby_name?(name)
    @outside_ruby_names.include?(name)
  end

  # A DEF the registry does not hold (installed by code the walk cannot place) defines +name+.
  def unknown_def?(name)
    @unknown_defs.include?(name)
  end

  # NATIVE_CLASS_ARMS: a DEF the registry does not hold, as unknown_def?, but ignoring the ones that
  # land on a class or module object (`class << Const; def x`, `alias_method` inside it). Those answer only
  # that object's own sends, so a receiver set of instance classes never reaches them.
  def instance_unknown_def?(name)
    @unknown_defs.include?(name) && @unknown_def_sources[name].any? { |label| label.nil? || !class_object_body?(label) }
  end

  # +label+ is the irep of a direct `class << <class or module constant>` body (or `class << self` in a class
  # body): its cref is that object's singleton class.
  def class_object_body?(label)
    @class_object_bodies ||= @singleton_opens.each_with_object(Set.new) do |(irep, idx, insn), out|
      next unless insn.op == :SCLASS && class_constant_target?(irep, idx, insn.reg)

      body = BytecodeIR.class_bodies(irep, :SCLASS)[idx]
      out << body if body
    end
    @class_object_bodies.include?(label)
  end

  # NATIVE_DIRECT: while a caller emits exact-class arms for every
  # native class answering `name` (CodeGen#guarded_fallback_line), the native
  # registrations no longer make the fallback's receiver unknowable.
  def with_native_arms(name)
    previous = @native_arms_name
    @native_arms_name = name
    yield
  ensure
    @native_arms_name = previous
  end

  # OUTSIDE_OWNER_CALL: while a caller ends the chain's else in a call checked against every
  # outside (core, native or outside Ruby) class that defines `name` (CodeGen#guarded_fallback_line), those
  # definitions no longer make the fallback's receiver unknowable; the Ruby-side gates still apply.
  def with_outside_owner_call(name)
    previous = @outside_owner_name
    @outside_owner_name = name
    yield
  ensure
    @outside_owner_name = previous
  end

  # SELF_NEW_LEAF: `klass` and every class below it, when the closed world sees every one: the declared
  # subclasses (matched by last path segment, as the hierarchy is), and none made by `Class.new(klass)`, an outside
  # Ruby `class X < klass`, or an outside native source that spells the name (an `mrb_define_class` could subclass
  # it). nil when any of those may exist. A singleton method of `klass` runs with one of these as `self`, an instance
  # method of `klass` with an instance of one of them.
  def known_subclasses(klass)
    return nil unless @class_decls.key?(klass)

    bounded_subclasses(klass, Set[klass] | descendants(klass))
  end

  # RECEIVER_BOUND: known_subclasses for a receiver the RBS contract resolver reads. A core class the program does not
  # declare (`class Child < Array`, no `class Array`) is bounded too, by the program classes that name it as their
  # superclass (@undeclared_children); CoreHierarchySigs must list it. Other callers keep known_subclasses.
  def known_receiver_subclasses(klass)
    return known_subclasses(klass) if @class_decls.key?(klass)
    return nil unless CoreHierarchySigs.declared_class?(klass)

    set = Set[klass]
    @undeclared_children[klass].each { |child| set |= Set[child] | descendants(child) }
    bounded_subclasses(klass, set)
  end

  def bounded_subclasses(klass, set)
    return nil if @global_refusal || !@wild.empty? || rebound?(klass)
    return nil unless set.all? { |k| @class_decls.key?(k) || k == klass }

    names = set.map { |k| simple(k) }.to_set
    return nil if names.any? { |n| @dynamic_subclassed.include?(n) || @outside_ruby_supers.include?(n) }
    # NATIVE_LEAF: a declared class no outside file touches (opaque?) has no native subclass either -- the touch scan
    # records a native class definition's superclass and a class_new's argument as touches. Any other class keeps the
    # spelled-name test.
    spelled = set.reject { |k| @class_decls.key?(k) && !opaque?(k) }.map { |k| simple(k) }
    return nil if @native_code_tokens.each_value.any? { |tokens| spelled.any? { |n| tokens.include?(n) } }

    set.to_a.sort
  end

  # CORE_REDEFINED: may the program define +name+ on +owner+ itself? True when a program source outside the core
  # mrblib (a Ruby definition, a native or unknown definer, a refusal) may, so a core contract for it is not trusted.
  def program_may_define?(owner, name)
    @program_defines ||= {}
    @program_defines.fetch([owner, name]) do
      @program_defines[[owner, name]] = @global_refusal || invisibly_definable?(name) ||
                                        ForeignDefiners.defines?(@ruby_paths.reject { |path| CoreDefs.core_source?(path) }, owner, name)
    end
  end

  # REMOVED_NAMES: could the program undefine or remove method +name+ in some class? The scan does not attribute a
  # removal to a class, so any removal of the name counts, whichever class it sits in.
  def method_removed?(name)
    @dynamic_removal || @removed_names.include?(name)
  end

  # A literal `undef`/`remove_method`/`undef_method` names +name+ (method_removed? without the computed case).
  def method_removed_literally?(name)
    @removed_names.include?(name)
  end

  # MODULE_INCLUDERS: the classes a module's includers are drawn from (the declared classes), or nil when an includer
  # may be one the program does not declare: the world is open (known_subclasses), the module is rebound, or a native
  # or outside Ruby source names it (an `include` there is not in the registry). The caller checks each candidate's
  # ancestor chain (RbsSignatures.self_receivers), which the registry records for every declared class.
  def known_includer_candidates(mod)
    @includer_memo ||= {}
    return @includer_memo[mod] if @includer_memo.key?(mod)

    @includer_memo[mod] = includer_candidates_uncached(mod)
  end

  # A non-core native source that only defines or looks up a module's name (mrb_define_module, module_function) cannot
  # include it: native_file_facts names every include a non-core native can make (see native_include_facts). A foreign
  # Ruby source that spells the name stays refused, since its include sites are not classified.
  def includer_candidates_uncached(mod)
    return nil if @global_refusal || !@wild.empty? || !module_declared?(mod) || rebound?(mod)

    name = simple(mod)
    return nil if @outside_include_open || @outside_include_names.include?(name) || @outside_alias_names.include?(name)
    return nil if @ruby_tokens.each_value.any? { |tokens| tokens.include?(name) }
    # A mixin the analysis could not place (defer_mixin_module?: `obj.extend(Mod)`, a mixin made in a method) puts the
    # module on a receiver no declared class lists.
    return nil if deferred_mixin_module?(mod)

    declared_class_names
  end

  # Is +mod+ (a declared name) one a deferred mixin may name? The same superset resolve_deferred_mixin_modules takes.
  def deferred_mixin_module?(mod)
    @deferred_mixin_modules.any? do |ref|
      bare = ref.delete_prefix('::')
      mod == bare || mod.end_with?("::#{bare}")
    end
  end

  # NATIVE_CORE_DIRECT: nothing outside the registry (an outside Ruby
  # definition, alias, visibility change or prepend on `owner`, a dynamic
  # installer) can replace core `owner`'s native `name`.
  def core_native_arm_safe?(name, owner)
    return false if @global_refusal || @unknown_defs.include?(name)

    !ForeignDefiners.defines?(@ruby_paths, owner, name)
  end

  # NATIVE_OWNER_MAP: why the closed world does not allow an exact-class arm of `name` (nil when it
  # does), beyond the native definers the owner map checks. An arm calls a class's own definition for an object
  # of exactly that class, so a dynamic installer, an unknown or outside Ruby definer, a global refusal, or a
  # singleton maker (an object with a singleton class is not of its class's exact lookup) keeps the by-name
  # send. A `.singleton` definer answers only for class objects, whose class is never the arm's class, so it
  # does not refuse. `installed` is CodeGen#symbol_installed_names.
  def exact_arm_refusal(name, installed)
    return :global_refusal if @global_refusal
    return :dynamic_install if installed.nil? || installed.include?(name)
    return :unknown_definer if @unknown_defs.include?(name)
    return :outside_ruby if @outside_ruby_names.include?(name)
    return :singleton_maker unless exact_instances_singleton_free?

    nil
  end

  # NATIVE_EXACT_DIRECT: nothing outside the registry can replace or
  # hide the RGSS native `name` on the class it is registered for: it is spelled
  # only by the RGSS sources (so no outside Ruby, no other native), no dynamic
  # definer or visibility change (private, module_function ...) names it. The
  # registry-visible definers and installers are checked by the caller.
  def native_exact_direct_name_safe?(name, path_fragment)
    return false if @global_refusal || @dynamic_visibility

    !@unknown_defs.include?(name) && !@visibility_names.include?(name) && native_only_in?(name, path_fragment)
  end

  # BLOCK_CORE_DIRECT: like core_native_arm_safe?, for a method that mruby's own
  # Ruby defines on `owner`. That Ruby is what the arm calls, so only an outside definer that
  # is not core source (an engine-side reopening, a dynamic installer) can replace it.
  def core_ruby_arm_safe?(name, owner)
    return false if @global_refusal || @unknown_defs.include?(name)

    !ForeignDefiners.defines?(@ruby_paths.reject { |path| CoreDefs.core_source?(path) }, owner, name)
  end

  # Does a core mrblib file define `owner#name`? The registry may leave such a definition out (CoreMethods.excluded_labels
  # drops ineligible core methods before any proof reads them), so this reads the source.
  def core_ruby_defines?(name, owner)
    ForeignDefiners.defines_named?(@ruby_paths.select { |path| CoreDefs.core_source?(path) }, owner, name)
  end

  # Names an outside (native or foreign Ruby) source defines.
  def outside_names
    @outside_names
  end

  # STRICT_HINTS: does a KNOWN receiver outside `listed` answer `name`? A definer the registry has
  # but the chain does not list (uncompiled, an embedded accessor, a subclass), a
  # core or native definer, or a module's singleton definition (a class or module object is the receiver)
  # reaches the else arm of a candidate-set chain in a correct program, so the set is incomplete by design and
  # the arm is not a wrong hint.
  def answered_outside?(name, listed)
    reason, required = required_classes(name, false, nil)
    return true if reason || @outside_names.include?(name)

    !required.subset?(listed.to_set)
  end

  # KERNEL_DIRECT: an implicit-self send of `name` reaches the audited
  # Kernel/BasicObject native for every receiver. That needs the same name-level proof as
  # ownerless_native_dispatch_safe? plus a receiver that includes Kernel, which only a
  # BasicObject subclass lacks (the class may be declared, created or subclassed anywhere).
  def kernel_native_dispatch_safe?(name)
    ownerless_native_dispatch_safe?(name) && basic_object_subclass_free?
  end

  # BLOCK_ITERATOR_DIRECT: an implicit-self send of `name` reaches mruby's own Kernel Ruby body (defined
  # in `kernel_file`) for every receiver: no computed definer can install the name, the only outside Ruby source that
  # spells a definition of it (by name, wherever it sits) is `kernel_file`, which defines it on Kernel alone and
  # reopens nothing dynamically, and every receiver includes Kernel. Native registrations and the program's own
  # definitions are the caller's to check.
  def kernel_ruby_dispatch_safe?(name, kernel_file)
    return false if @global_refusal || @unknown_defs.include?(name)

    paths = outside_ruby_definer_paths(name)
    return false unless paths.all? { |path| File.expand_path(path) == File.expand_path(kernel_file.to_s) }
    unless paths.empty?
      definers = ForeignDefiners.scan(paths)
      return false unless definers.wild.empty? && definers.names.all? { |owner, names| owner == 'Kernel' || !names.include?(name) }
    end

    basic_object_subclass_free?
  end

  # The outside Ruby sources whose text spells a definition of `name` (foreign_method_names, over-collected).
  def outside_ruby_definer_paths(name)
    @outside_ruby_definer_paths ||= {}
    @outside_ruby_definer_paths[name] ||= Array(@ruby_paths).select { |path| outside_ruby_path_method_names(path).include?(name) }
  end

  # KERNEL_SELF_SEND: may `self` in a method of +owner+ lack Kernel? False when no class of the program is a BasicObject
  # subclass; otherwise true only for a BasicObject subclass, a class below one, or an owner whose includers are not known
  # (a module). The program's other classes keep Kernel, so an implicit-self send of a Kernel method reaches it there.
  def kernel_missing_self?(owner)
    return false if basic_object_subclass_free?
    return true if @global_refusal

    seen = Set.new
    cur = owner
    while cur && seen.add?(cur)
      decls = @class_decls[cur]
      return true unless decls

      supers = decls.map { |decl| decl[:super] }.uniq - [:none]
      return true unless supers.all?(String)
      return true if supers.any? { |sup| simple(sup) == 'BasicObject' }

      return false if supers.empty? # no superclass named: Object

      return true unless supers.size == 1

      cur = @class_decls.keys.find { |k| simple(k) == simple(supers.first) }
    end
    false
  end

  # No class of the program, created or subclassed anywhere, lacks Kernel.
  def basic_object_subclass_free?
    return false if @dynamic_subclassed.include?('BasicObject') || @outside_ruby_supers.include?('BasicObject')

    supers = @class_decls.values.flatten.map { |decl| decl[:super] }
    supers.all? { |sup| sup == :none || sup.is_a?(String) } && supers.none? { |sup| sup.is_a?(String) && simple(sup) == 'BasicObject' }
  end

  # BLOCK_PARAM_CALL: no Ruby code in the build defines or installs `name`
  # and NilClass has no method_missing, so `nil.name` can only be a NoMethodError once the
  # native registrations are read (CodeGen#block_param_nil_call_dead?).
  def nil_call_free?(name)
    return false if @global_refusal || @unknown_defs.include?(name) || @outside_ruby_names.include?(name)

    !@mm_classes.include?('NilClass')
  end

  # NIL_RECEIVER: no foreign Ruby source defines, aliases or re-scopes +name+ on any of
  # +owners+ (the classes and modules nil answers through), nothing defines it by a computed name,
  # and NilClass has no method_missing. Finer than nil_call_free?, which refuses a name any outside
  # class defines (`size`, `first` on Array).
  def nil_foreign_definition_free?(name, owners, instance_scope: false)
    return false if @global_refusal || @mm_classes.include?('NilClass')
    return false if instance_scope ? instance_unknown_def?(name) : @unknown_defs.include?(name)

    !ForeignDefiners.defines_any?(@ruby_paths, owners, name)
  end

  # Every native source of the build that spells +name+ (a definition, an alias or a funcall).
  def native_paths_spelling(name)
    (@outside_name_paths[name] || []).to_a.sort
  end

  # `name` is spelled only by the given native files, and no outside Ruby.
  def native_only_in?(name, path_fragment)
    paths = @outside_name_paths[name]
    !paths.nil? && !@outside_ruby_names.include?(name) && paths.all? { |path| path.include?(path_fragment) }
  end

  # No class in `owners` (full constant paths) has a declared, factory-made or
  # outside subclass, so an exact class guard names every instance.
  def native_subclass_free?(owners)
    return false if @global_refusal || !@wild.empty?

    simples = owners.map { |owner| simple(owner) }
    supers = @class_decls.values.flatten.map { |decl| decl[:super] }
    return false unless supers.all? { |sup| sup == :none || sup.is_a?(String) }

    simples.none? do |name|
      @dynamic_subclassed.include?(name) || @outside_ruby_supers.include?(name) ||
        supers.any? { |sup| sup.is_a?(String) && simple(sup) == name }
    end
  end

  # FACTORY_CLASS_FREE: no class mruby-struct's make_struct or mruby-data's Data.define makes can exist, so their
  # registrations on that computed class never run. The program's bytecode makes no Struct.new call (scan_factory;
  # any Data factory use, or a Struct constant that escapes, is already a global refusal), outside Ruby makes none
  # (:outside_class_factory), and neither class has a declared, factory-made or outside subclass whose `new` would
  # reach Struct.new.
  def factory_class_free?
    !@global_refusal && !@struct_factory_used && native_subclass_free?(%w[Struct Data])
  end

  # LCF_ROW_FLOW: no outside file can reopen, subclass or rebind `owner`, so a method
  # lookup that ends at one of its registry definitions cannot be redirected by a native installer.
  def untouched_class?(owner)
    !@global_refusal && !opaque?(owner)
  end

  # Is every instance whose class descends from `owner` exactly an `owner`?
  def exact_class?(owner)
    !@global_refusal && !opaque?(owner) && descendants(owner).empty?
  end

  # CHA_SELF: every class whose instances can be `owner` or descend
  # from it, or nil when that set is not fully enumerable (opaque owner or
  # opaque descendant, global refusal). `wild` are descendants whose superclass
  # the walk could not resolve: they may sit under any class, so a caller
  # cannot place them relative to an override.
  def class_hierarchy(owner)
    return nil if @global_refusal || opaque?(owner)

    sub = descendants(owner)
    return nil if sub.any? { |c| opaque?(c) }

    { descendants: sub, wild: @wild & sub }
  end

  # The superclass of a declared, non-opaque class: its full path, or
  # :none for an implicit Object. nil when it cannot be named with certainty
  # (an unresolved or ambiguous superclass expression, or an opaque class).
  def class_parent(klass)
    return nil if @global_refusal || opaque?(klass)

    supers = @class_decls.fetch(klass).map { |decl| decl[:super] }.uniq - [:none]
    return :none if supers.empty?
    return nil unless supers.one? && supers.first.is_a?(String)

    candidates = @by_simple[simple(supers.first)]
    parent = candidates.first
    candidates.one? && (parent == supers.first || parent.end_with?("::#{supers.first}")) ? parent : nil
  end

  # SUBTREE_DISPATCH: class_parent, plus a superclass written as the full path of a declared class
  # (`class Battle < RPG2k::Scene::Battle`), which class_parent refuses when several classes share its last segment.
  def declared_parent(klass)
    parent = class_parent(klass)
    return parent unless parent.nil?
    return nil if @global_refusal || opaque?(klass)

    supers = @class_decls.fetch(klass).map { |decl| decl[:super] }.uniq - [:none]
    supers.one? && supers.first.is_a?(String) && @class_decls.key?(supers.first) ? supers.first : nil
  end

  # Can an instance of `owner` or of a descendant answer through method_missing?
  def self_method_missing_free?(owner)
    method_missing_free?(owner)
  end

  # A runtime exact-class guard needs a stable constant, but unlike
  # exact_class? it does not require the class to have no subclasses.
  def stable_class_constant?(owner)
    return false if @global_refusal || !owner.is_a?(String)
    return !opaque?(owner) if @class_decls.key?(owner)

    # MODULE declarations do not participate in the class hierarchy table, but
    # their constant identity needs the same closed-world stability proof.
    return false if owner.include?('.') || owner.include?('<')
    return false unless ConstructClassNames.table&.key?(owner)
    return false if rebound?(owner)

    touches_for([owner.split('::').first, simple(owner)].uniq, source: true).empty?
  end

  # Constant-object dispatch needs identity stability, not an exact instance
  # hierarchy. Reopening a class/module changes methods, not its constant value;
  # the caller separately proves the singleton method lookup is closed.
  def stable_constant_identity?(owner)
    return false if @global_refusal || !owner.is_a?(String) || !ConstructClassNames.table&.key?(owner)

    # UNIQUE_CLASS_NAME includes native-defined class/module objects and has
    # already rejected bytecode, native, and foreign constant reassignment.
    return true if UniqueClassNames.table&.value?(owner)

    !rebound?(owner)
  end

  # `self` in a `def self.x` of a declared module is that module's
  # constant object. Only Kernel#clone copies a module's singleton methods, so
  # nothing else can run them with another self; a `clone` spelled anywhere in
  # the closed world or its outside sources refuses.
  def module_object_self?(owner)
    !@global_refusal && !@clone_sent && @module_names.include?(owner) && !@declared_classes.include?(owner) &&
      stable_constant_identity?(owner)
  end

  # A value constant is single-assignment only when bytecode has one binding
  # site, no outside source writes the name, and the name is not a class
  # declaration. Dynamic constant mutation poisons all such facts.
  def single_assignment_constant?(name)
    return false unless name.is_a?(String)

    static_constant_writes?(name.split('::').last, 1)
  end

  # The bare name's writes are exactly +count+ program SETCONST sites, and no class, deferred or outside write binds it.
  def static_constant_writes?(simple, count)
    return false if @dynamic_constant_mutation

    @constant_write_counts[simple] == count && !@class_constant_names.include?(simple) &&
      !@deferred_constant_writes.include?(simple) && !@outside_constant_writes.include?(simple)
  end

  # INSTANCE_RECEIVER: instances of the declared class are never class or module
  # objects (instance_self?, stated for `self`; an exact instance has the same property).
  def instance_class?(klass)
    instance_self?(klass)
  end

  # NATIVE_RESULT_FACTS: a class a native defines (RGSS::Rect) is what its constant
  # names for the whole run. Exactly one outside write binds the simple name (the native
  # definition itself; a second define, const_set, const_remove or Ruby `Name =` makes two), no
  # bytecode SETCONST binds it, and no dynamic constant mutation exists.
  # A caller auditing mutually exclusive native definitions may supply their binding count.
  def native_class_constant_stable?(full, bindings: 1)
    return false if @global_refusal || @dynamic_constant_mutation || !full.is_a?(String)

    name = simple(full)
    @constant_write_counts[name].zero? && @outside_constant_write_counts[name] == bindings
  end

  # NATIVE_CONSTRUCTED_CONSTANT: native_class_constant_stable?, and no program class of that simple name either. A
  # CLASS opcode binds its constant without a SETCONST, so the write counts above do not see a class declaration.
  # Neither a root `class N` with no superclass (root_reopen?) nor outside writes that are all plain Object-superclass
  # defines is a second binding (mruby returns the same class). docs/bc2cpp-type-check.md, "IO.open", has the details.
  def native_class_unshadowed?(full)
    return false if @global_refusal || @dynamic_constant_mutation || !full.is_a?(String)

    name = simple(full)
    plain = @outside_plain_class_defines[name]
    stable = native_class_constant_stable?(full) ||
             (plain.positive? && @constant_write_counts[name].zero? && @outside_constant_write_counts[name] == plain)
    stable && !@class_declared_names.include?(name)
  end

  # The root irep runs with the Object target class (no lexical class body), so `class N` there with no superclass
  # (cbase and superclass registers loaded by LOADNIL, or the cbase from OCLASS) names Object::N. A class body's
  # irep is a child of the root, and its `class N` names a nested constant, so it is not a root reopen.
  def root_reopen?(irep, idx, insn)
    root = irep.tree && !referenced_labels(irep.tree).include?(irep.label)
    return false unless root

    base = insn.reg.to_i
    BytecodeIR.all_writers_reaching?(irep, idx, base) { |_j, w| CLASS_SCOPE_WRITERS.include?(w.op) } &&
      BytecodeIR.all_writers_reaching?(irep, idx, base + 1) { |_j, w| w.op == :LOADNIL }
  end

  def referenced_labels(tree)
    @referenced_labels ||= {}
    @referenced_labels[tree.object_id] ||= tree.each_value.flat_map(&:reps).to_set
  end

  # A literal `Klass.new` has an exact-class result only while ordinary
  # construction is visible: no unresolved installer can replace `new` or
  # `allocate`, and no outside Ruby file defines either name.
  def standard_constructor_lookup?
    !@global_refusal && %w[new allocate].none? do |name|
      @unknown_defs.include?(name) || @outside_ruby_names.include?(name)
    end
  end

  # EXACT_NEW: `klass.new` answers an instance of exactly +klass+. Its constant is stable and no outside source touches
  # the class (stable_class_constant?), and `new` / `allocate` are Class's natives: no Ruby definition on Class, on
  # +klass+ or a superclass or their singletons, or on a module (which `extend` could put on a singleton), and no mixin
  # into Class or those singletons.
  def exact_constructor_class?(klass, superclass_of)
    return false unless standard_constructor_lookup? && class_declared?(klass) && @mixins && @unknown_mixins
    return false unless stable_class_constant?(klass)
    return false if @unknown_mixins.include?('Class') || !@mixins.fetch('Class', []).empty?

    defs = %w[new allocate].flat_map { |name| @registry.fetch(name, []) }.reject { |d| d.owner == '<native>' }
    return false if defs.any? { |d| d.owner == 'Class' || @module_names.include?(d.owner.to_s) }

    seen = Set.new
    while klass.is_a?(String) && seen.add?(klass)
      singleton = "#{klass}.singleton"
      return false if @unknown_mixins.include?(singleton) || !@mixins.fetch(singleton, []).empty?
      return false if defs.any? { |d| d.owner == klass || d.owner == singleton }

      klass = superclass_of[klass]
    end
    true
  end

  # NUMERIC_RETURN_PROOF: can a call to `name` reach only the definitions the
  # registry lists? False for a name some native or foreign source defines or
  # calls a runtime installer with, or whenever a method_missing hook exists.
  def name_fully_visible?(name)
    !@global_refusal && @mm_classes.empty? && !@unknown_defs.include?(name) && !@outside_names.include?(name)
  end

  # NATIVE_RETURN_CLASSES: NativeReturnClasses.admit already accounts for every native registration of the name (each
  # owner has one proven ROM entry, no computed or unknown owner), so a native spelling of it is not a gap here. What
  # remains is a Ruby definition the caller checks itself, an installer, a method_missing hook or a global refusal.
  def name_visible_to_native_table?(name)
    !@global_refusal && @mm_classes.empty? && !@unknown_defs.include?(name) && !@outside_ruby_names.include?(name)
  end

  # NATIVE_RESULT_FACTS: name_fully_visible?, except that natives under
  # +path_fragment+ may define the name (the caller proves what each one returns).
  def name_visible_except_natives_in?(name, path_fragment)
    return false if @global_refusal || !@mm_classes.empty? || @unknown_defs.include?(name)

    !@outside_names.include?(name) || native_only_in?(name, path_fragment)
  end

  # Audited outside Ruby aliases may join a native return table.
  def native_return_sources_visible?(name, audited_ruby_paths = [])
    return false if @global_refusal || !@mm_classes.empty? || @unknown_defs.include?(name)

    outside_ruby_paths_defining(name).all? { |path| audited_ruby_paths.include?(path) }
  end

  def outside_ruby_paths_defining(name)
    @outside_return_def_paths ||= {}
    @outside_return_def_paths[name] ||= @ruby_paths.select { |path| outside_ruby_path_method_names(path).include?(name) }
  end

  # The names one outside Ruby file defines, read and scanned once per run rather than once per asked name.
  def outside_ruby_path_method_names(path)
    @outside_path_method_names ||= {}
    @outside_path_method_names[path] ||= foreign_method_names([path])
  end

  # Inherited dispatch additionally needs every possible method installer for
  # this name to be represented in the registry.
  def inherited_lookup_safe?(name, owner)
    stable_class_constant?(owner) && !@unknown_defs.include?(name) && !@outside_names.include?(name)
  end

  # inherited_lookup_safe? for a name the RGSS natives register, judged on
  # the exact class's own lookup chain (`chain`: the class, its superclasses and
  # every mixin) instead of the global name. Every outside spelling must be a
  # registration NativeDirect parsed to a class, and none of those classes may sit
  # on the chain.
  def exact_chain_lookup_safe?(name, owner, chain)
    return false unless stable_class_constant?(owner) && !@unknown_defs.include?(name)
    return true unless @outside_names.include?(name)
    return false unless native_only_in?(name, '/mruby-rgss/src/')

    registered = NativeDirect.registered_owners(name, @outside_name_paths[name])
    !registered.nil? && registered.none? { |native_owner| chain.include?(native_owner) }
  end

  # The registry's visibility for `name` is the one mruby ends up with.
  # build_registry follows `private`/`public` in the defining class body only; a
  # `private :name` that names an inherited method, or one sent dynamically, makes a
  # copy it never sees.
  def visibility_stable?(name)
    !@global_refusal && !@dynamic_visibility && !@visibility_unresolved.include?(name)
  end

  # OWNERLESS_NATIVE_DISPATCH: class-independent native bodies may bypass
  # method lookup only when the closed inputs prove there is no competing Ruby
  # definition or unresolved dynamic installation for the same name.
  def ownerless_native_dispatch_safe?(name)
    return false if @global_refusal || @unknown_defs.include?(name) || @outside_ruby_names.include?(name)

    @registry.fetch(name, []).all? { |definition| definition.owner == '<native>' }
  end

  # ownerless_native_dispatch_safe? for a name only instances are asked: a definition on a class or
  # module object (owner "X.singleton") never answers one.
  def instance_native_dispatch_safe?(name)
    return false if @global_refusal || @unknown_defs.include?(name) || @outside_ruby_names.include?(name)

    @registry.fetch(name, []).all? { |definition| definition.owner == '<native>' || definition.owner.end_with?('.singleton') }
  end

  # No instance of a class the closed world defines can ever be frozen, so a store into
  # one of its embedded ivars needs no frozen check. Every route to a frozen user object is a
  # `freeze` (Ruby or native), and each is refused unless provably aimed at a builtin literal:
  # a send on anything else, `:freeze` or "freeze" spelled where a computed name could reach it
  # (DynamicNames), project native or foreign Ruby that freezes. mruby's own core freezes only
  # its builtin values and Data instances (audited against 3rd/mruby), and its Ruby is exempt
  # from the send scan for the same reason. clone copies a frozen flag, it never sets one.
  def user_objects_unfrozen?
    return false if @global_refusal || @freeze_possible

    unless defined?(@user_objects_unfrozen)
      @user_objects_unfrozen = @frozen_constants.all? { |name| class_constant?(name) } &&
                               fresh_builtin_names_core? && !DynamicNames.universe(@ireps).include?('freeze')
    end
    @user_objects_unfrozen
  end

  # CONST_DEF_ELIDE: a class or module whose last path segment is +bare+ may be frozen. user_objects_unfrozen? admits
  # `Klass.freeze` on a class-valued constant; here such a send refuses the classes it names, and a frozen value
  # constant (which might hold any class) refuses every one.
  def class_object_freeze_possible?(bare)
    unless defined?(@class_freeze_open)
      @class_freeze_open = @global_refusal || @freeze_possible || !fresh_builtin_names_core? ||
                           DynamicNames.universe(@ireps).include?('freeze') ||
                           @frozen_constants.any? { |name| !class_constant?(name) }
    end
    !!@class_freeze_open || @frozen_constants.include?(bare)
  end

  # No Array/Hash/Range/String instance can gain a singleton class or a mixin: nothing in the
  # world (mruby's own Ruby aside, which never does it to those) names a singleton-making
  # method, opens a singleton class on a non-class object, or creates one from native code.
  # INSTANCE_SINGLETON_TAINT, for the generation log: "none", "not placed (reason)", or each tainted class with the
  # names its instances' singletons may answer.
  def instance_singleton_report
    taint = instance_singleton_taint
    return "not placed (#{singleton_taint_unplaced})" if taint.nil?
    return 'none' if taint.empty?

    taint.sort.map do |klass, gain|
      names = gain == :any ? ['any name'] : gain.map { |n| n == SINGLETON_INSTALLED ? '<installed names>' : n }.sort
      "#{klass} (#{names.join(' ')})"
    end.join(', ')
  end

  def exact_instances_singleton_free?
    !@global_refusal && singleton_makers.empty?
  end

  # INSTANCE_SINGLETON_TAINT: the per-class form of exact_instances_singleton_free?. Which classes' instances may get a
  # singleton class, and what it may answer: { class path => :any | Set of method names }, read as that class and
  # every class below it. A gain holding SINGLETON_INSTALLED also answers every name installed by Symbol. {} when
  # exact_instances_singleton_free? holds.
  #
  # A maker in the closed world's own Ruby is placed on the class whose instance its receiver is (`self` in an instance
  # method of a declared class, instance_singleton_place); one whose receiver may be any object but whose gain is
  # bounded (define_singleton_method(:x), `def obj.x`, a singleton_class only asked include? or given a listed module)
  # is placed on Object, so on every class. nil when some maker cannot be placed (then any instance may have one with
  # any method): a global refusal, a native maker, an outside Ruby maker OutsideSingletons does not place, a maker
  # whose receiver and gain are both open, or a maker-named Symbol whose value may reach a send.
  #
  # The singleton class an `extend Mod` makes answers Mod's methods; Mod must be a module the outside sources or the
  # registry fully list (no mixin, hook or other definer in its body), else :any. A class or module object's
  # singleton (`class << self`, `def self.x`, `Const.singleton_class`) taints nothing: an instance never sees it.
  def instance_singleton_taint
    return @instance_singleton_taint if defined?(@instance_singleton_taint)

    @instance_singleton_taint = compute_instance_singleton_taint
  end

  # Why instance_singleton_taint is nil (a label for the generation log), or nil when it is placed.
  attr_reader :singleton_taint_unplaced

  # NUMERIC_SLOW_CLOSED `%`: the constant +name+ of a core class names that class in every scope
  # core Ruby looks it up from: no bytecode binds it, no outside source rebinds it (the core's own definition is
  # the one write), and no nested class of that name is declared.
  # `global_only` asks about the top-level constant a C++ `mrb_class_get` reads: a class of that name nested in another
  # namespace (LCF::File) cannot rebind it, only the lexical lookups of Ruby code.
  def core_constant_plain?(name, global_only: false)
    return false if @global_refusal || @dynamic_constant_mutation

    @constant_write_counts[name].zero? && !@deferred_constant_writes.include?(name) && @outside_constant_write_counts[name] <= 1 &&
      (global_only || @class_decls.keys.none? { |key| key != name && simple(key) == name })
  end

  # IS_A_GUARD: the constant path +written+ (`K` or `Root::K`, a GETCONST and at most one GETMCNST)
  # names exactly the declared class K wherever it is evaluated, and every instance of K is exactly a K:
  #   * the root names one constant for the whole run: the closed world declares exactly one class or module of
  #     that simple name, at top level; no bytecode SETCONST writes the name and no dynamic constant mutation
  #     exists; no foreign Ruby source spells it; no native binds it except a top-level mrb_define_class /
  #     mrb_define_module (which reopens that same top-level constant). GETCONST then finds that binding from any
  #     scope (Object holds it), so const_missing is never asked;
  #   * `Root::K` is found in Root's own constant table, where its declaration put it, before any ancestor;
  #   * K is a declared, non-opaque class (no rebinding, no dynamic subclass, no outside file reopening it) with no
  #     declared, unresolved (`wild`) or foreign Ruby subclass, so `x.is_a?(K)` holds only for an exact K.
  def is_a_guard_constant?(written)
    return false if @global_refusal || @dynamic_constant_mutation || !written.is_a?(String)

    segments = written.split('::')
    return false unless segments.size.between?(1, 2) && segments.all? { |s| s.match?(/\A[A-Z]\w*\z/) }
    return false unless top_level_constant_unique?(segments.first)

    !opaque?(written) && descendants(written).empty? && !@outside_ruby_supers.include?(simple(written)) &&
      @constant_write_counts[simple(written)].zero? && !@deferred_constant_writes.include?(simple(written))
  end

  # No bytecode of the world spells the constant BasicObject, the one way to an object that lacks Kernel's methods
  # without a class declaration (kernel_native_dispatch_safe? covers the declared subclasses).
  def basic_object_unreferenced?
    !@global_refusal && !@basic_object_referenced
  end

  # BASIC_OBJECT_SEALED: no object of the world is a bare BasicObject, so every receiver includes Kernel. Subclasses
  # are ruled out by basic_object_subclass_free?, the world's own bytecode never reads the constant, and no outside
  # Ruby source spells it. The native side is CodeGen#kernel_receiver_sealed?'s.
  def basic_object_instance_free?
    return false unless basic_object_subclass_free? && basic_object_unreferenced?

    Array(@ruby_paths).none? { |path| File.read(path, encoding: 'BINARY').include?('BasicObject') }
  end

  private

  # is_a_guard_constant?'s root rule: +name+ is bound once, by the closed world's own top-level declaration.
  def top_level_constant_unique?(name)
    declared = (@class_decls.keys + @module_names.to_a).select { |path| simple(path) == name }.uniq
    return false unless declared == [name]
    return false if @constant_write_counts[name].positive? || @deferred_constant_writes.include?(name)
    return false if @ruby_tokens.each_value.any? { |tokens| tokens.include?(name) }

    @native_code_tokens.none? { |path, tokens| tokens.include?(name) && native_binds_nested?(path, name) }
  end

  NATIVE_CONSTANT_BINDERS = /\bmrb_(?:define_(?:class|module)_under(?:_id)?|define_(?:global_)?const|const_set|const_remove|
                             define_(?:class|module)_id)\s*\(([^;]*)/mx

  # A native source binds +name+ other than through a top-level mrb_define_class / mrb_define_module with the name
  # spelled out (a nested define, a const_set or const_remove, a global or class const, or an `_id` define whose
  # name is a symbol the scan does not resolve). An unreadable source answers true.
  def native_binds_nested?(path, name)
    text = File.binread(path).gsub(%r{/\*.*?\*/|//[^\n]*}m, ' ')
    spelled = /"#{Regexp.escape(name)}"|\bMRB_(?:SYM|CVSYM|IVSYM)\(#{Regexp.escape(name)}\)/
    text.scan(NATIVE_CONSTANT_BINDERS).any? { |(body)| body.match?(spelled) || !body.match?(/"[A-Za-z_]\w*"|MRB_\w*SYM\(/) }
  rescue SystemCallError
    true
  end

  def native_arms_lift?(name)
    @native_arms_name == name && native_only_in?(name, '/mruby-rgss/src/')
  end

  def note_outside_constant_write(name)
    @outside_constant_writes << name
    @outside_constant_write_counts[name] += 1
  end

  # NATIVE_HELPER: every (function, parameter) a native dispatches a computed method name through must receive an
  # enumerable name at every call in the outside natives, and the function must never be used except as a call (no
  # pointer to it). Otherwise a caller may pass `include`, so the includers of every module are open.
  def helper_names_enumerable?
    @outside_include_helpers.all? do |fn, index, static, home|
      # A static function is reached only from its own file. Otherwise a file that neither calls, declares nor defines
      # `fn(...)` cannot reach it: a use of the word there is another name (a local, a member), so it is not checked.
      paths = static ? [home] : @native_paths
      paths.all? do |path|
        !File.binread(path).gsub(%r{/\*.*?\*/|//[^\n]*}m, ' ').match?(/\b#{Regexp.escape(fn)}\s*\([^;{}]*\)\s*[;{]/m) ||
          helper_calls_enumerable?(path, fn, index)
      end
    end
  end

  def helper_calls_enumerable?(path, fn, index)
    text = File.binread(path).gsub(%r{/\*.*?\*/|//[^\n]*}m, ' ')
    blanked = text.gsub(/"((?:[^"\\\n]|\\.)*)"/) { |lit| '"' + ' ' * (lit.size - 2) + '"' }
    symbols = nil
    RegexpMatches.of(blanked, /\b#{Regexp.escape(fn)}\b/).all? do |m|
      # A member access (`x.fn(`, `x->fn(`) is not a call to a free helper.
      next true if m.begin(0).positive? && text[0...m.begin(0)].match?(/(?:\.|->)\s*\z/)
      # A symbol spelled by a macro (MRB_SYM(fn)) names the method, not the function.
      next true if text[0...m.begin(0)].match?(/MRB_(?:OP)?SYM\(\s*\z/)

      rest = text[m.end(0)..]
      open_paren = rest[/\A\s*\(/]
      next false unless open_paren # a use that is not a call (a pointer to the function) could pass any name

      after = rest[open_paren.size..]
      line_start = m.begin(0).positive? ? (text.rindex("\n", m.begin(0) - 1) || -1) + 1 : 0
      prefix = text[line_start...m.begin(0)]
      # A definition has a return type before its name on its line, and a body after its parameter list.
      next true if prefix.match?(/\A\s*(?:(?:static|inline|extern|const|virtual)\s+)*[\w:<>]+[\s\*&]+\z/) &&
                   after.match?(/\A[^;{]*\)\s*(?:const\s*)?\{/)

      symbols ||= ClosedWorld.native_local_symbols(text)
      arg = bc2cpp_c_call_args(after).to_a[index].to_s.strip
      words = (m2 = arg.match(NATIVE_SPELLED_NAME)) ? [m2[1] || m2[2] || m2[3]] : symbols[arg]
      words && words.none? { |word| INCLUDE_METHOD_NAMES.include?(word) }
    end
  end

  def global!(reason)
    @global_refusal ||= reason
  end

  # -- outside the closed world ------------------------------------------------

  # The facts are a function of the bytes alone, so ScanCache may store them; replaying them in order leaves the
  # state a direct scan would.
  def scan_native(paths)
    facts = ScanCache.fetch('closed_world.native', Array(paths)) { self.class.native_facts(paths) }
    facts.each { |file| apply_native_file(file) }
  end

  def apply_native_file(file)
    path = file.fetch(:path)
    @native_code_tokens[path] = Set.new(file.fetch(:code_tokens))
    @native_tokens.merge(file.fetch(:funcall_tokens))
    @native_other_literals.merge(file.fetch(:other_literals))
    file.fetch(:constant_writes).each { |name| note_outside_constant_write(name) }
    file.fetch(:plain_class_defines).each { |name| @outside_plain_class_defines[name] += 1 }
    @dynamic_constant_mutation = true if file.fetch(:dynamic_constant_mutation)
    @outside_names.merge(file.fetch(:names))
    @outside_include_open ||= file.fetch(:include_open)
    @outside_include_names.merge(file.fetch(:include_names))
    @outside_alias_names.merge(file.fetch(:alias_names))
    @outside_include_helpers.concat(file.fetch(:include_helpers).map { |fn, index, static| [fn, index, static, path] })
    @native_singleton_names.merge(file.fetch(:singleton_names))
    file.fetch(:names).each { |n| (@outside_name_paths[n] ||= Set.new) << path }
    file.fetch(:refusals).each { |reason| global!(reason) }
    @clone_sent = true if file.fetch(:clone_sent)
    @freeze_possible = true if file.fetch(:freeze_possible)
    @singleton_makers << [path, :native] if file.fetch(:singleton_maker)
    record_native_touches(path, file.fetch(:touch), file.fetch(:defines_class), file.fetch(:legacy_names))
    touch = file.fetch(:touch)
    @native_class_assigns[path] = touch.fetch(:class_assigns)
    touch.fetch(:events).each { |event| @native_class_events << [path, *event] if NATIVE_CLASS_MAKERS.match?(event[0]) }
  end

  # The native events that can make a class (TouchScan.native_facts kinds).
  NATIVE_CLASS_MAKERS = /\A(?:define_class|class_new\z|super\z|obj_alloc\z|obj_new\z|instance_new\z|funcall)/
  # mruby's own implementation of the class-making API (and of the funcall family it forwards through): each event
  # there forwards a caller's class, which is that caller's own event, or serves Class.new / Class#initialize /
  # Module#dup, which the closed world's dynamic-subclass facts bound.
  NATIVE_CLASS_API = %r{/3rd/mruby/src/(?:class|gc|vm)\.c\z}

  # NATIVE_LEAF_CORE: no native source can make an instance of a subclass of +klass+. Outside NATIVE_CLASS_API:
  #   - every class definition and class_new names a superclass that resolves (a built-in handle, a class_get, a
  #     local assigned only such values) to another class, and nothing assigns ->super;
  #   - every instantiation (obj_new, instance_new, a funcall of `new`/`allocate`) is of a class that resolves to no
  #     class factory (Class, Module, Struct, Data), or passes no argument a superclass could be (none, or only
  #     integer/nil/string values), or is NATIVE_INSTANCE_REVIEWED.
  # An obj_alloc of a class object makes a class with no superclass until ->super is set. A funcall of a computed
  # name forwards a Ruby send, which the Ruby facts bound. False when any of those cannot be read.
  def native_unsubclassed?(klass)
    names = native_superclass_names
    !names.nil? && !names.include?(simple(klass))
  end

  # [path suffix, call prefix] of instantiations reviewed against the pinned mruby: error.c's mrb_make_exception
  # sends `new` to the class `raise` was given and raises TypeError unless the result is an exception, so a class it
  # makes there has no instance.
  NATIVE_INSTANCE_REVIEWED = [['/3rd/mruby/src/error.c', 'mrb_funcall_argv(mrb, exc, MRB_SYM(new), n, &mesg)']].freeze

  # The simple names native class definitions take as superclass, or nil when one cannot be resolved.
  def native_superclass_names
    return @native_superclass_names if defined?(@native_superclass_names)

    norm = (@class_decls.keys.map { |k| simple(k) } + CoreHierarchySigs.hierarchy[0].keys).uniq
                                                                                   .group_by { |n| n.downcase.delete('_') }
    @native_superclass_names = @native_class_events.each_with_object(Set.new) do |(path, kind, args, why, helper), out|
      next if path.match?(NATIVE_CLASS_API) || kind == 'obj_alloc'
      next if NATIVE_INSTANCE_REVIEWED.any? { |suffix, call| path.end_with?(suffix) && why.to_s.start_with?(call) }

      args = Array(args)
      # A function's own definition or declaration (`mrb_define_class(mrb_state *mrb, ...)`), not a call.
      next if args.first.to_s.match?(/\bmrb_state\s*\*/)

      names = native_class_event_supers(kind, args, helper, @native_class_assigns.fetch(path, {}), norm)
      break nil unless names

      out.merge(names)
    end
  end

  # A value no superclass can be.
  NATIVE_NON_CLASS_ARG = /\A(?:mrb_(?:fixnum|int|nil|bool|true|false|symbol)_value\s*\(.*\)|mrb_str_new\w*\s*\(.*\)|
                            NULL|nullptr|0)\z/mx

  # The superclass names one NATIVE_CLASS_MAKERS event may give a new class (empty when it makes none), or nil.
  def native_class_event_supers(kind, args, helper, assigns, norm)
    instance = lambda do |cls, rest|
      names = native_class_resolve(cls, assigns, norm)
      next Set.new if names && (names & TouchScan::CLASS_FACTORIES).empty?

      rest.all? { |arg| arg.to_s.strip.match?(NATIVE_NON_CLASS_ARG) } ? Set.new : nil
    end
    case kind
    when 'super' then nil
    when 'obj_new', 'instance_new' then instance.(args[1], args[3..].to_a)
    when /\Afuncall/
      mids = helper || [TouchScan.native_literal(args[2])].compact
      next_args = args[3].to_s.strip == '0' ? [] : args[4..].to_a
      mids.empty? || (mids & %w[new allocate]).empty? ? Set.new : instance.(args[1], next_args)
    when 'class_new' then native_class_resolve(args[1], assigns, norm)
    else native_class_resolve(args[kind.include?('_under') ? 3 : 2], assigns, norm)
    end
  end

  # The simple names a native class expression can denote: TouchScan.native_resolve, a class definition's own name,
  # an exception class get, or each value a local is assigned. nil when one cannot be named.
  def native_class_resolve(expr, assigns, norm, depth = 0)
    e = expr.to_s.strip.sub(/\A\(\s*(?:struct\s+)?RClass\s*\*\s*\)\s*/, '')
    e = Regexp.last_match(1).strip while e.match(/\Amrb_(?:obj_value|class_ptr)\s*\(\s*(\w+)\s*\)\z/)
    return nil if depth > 4

    if (m = e.match(/\Amrb_define_class(_under)?(?:_id)?\s*\((.*)\)\z/m))
      name = TouchScan.native_literal(bc2cpp_c_call_args(m[2])[m[1] ? 2 : 1])
      return name ? Set[TouchScan.path_names(name).last] : nil
    end
    if (m = e.match(/\Amrb_exc_get(?:_id)?\s*\((.*)\)\z/m))
      name = TouchScan.native_literal(bc2cpp_c_call_args(m[1])[1])
      return name ? Set[name] : nil
    end
    resolved = TouchScan.native_resolve(e, norm)
    return resolved - [TouchScan::WILD] if resolved
    return nil unless e.match?(TouchScan::IDENTIFIER) && !(values = assigns[e]).to_a.empty?

    values.each_with_object(Set.new) do |value, out|
      # `a = mrb->x_class = expr;` assigns expr; a null pointer is no class.
      value = value.sub(/\A(?:[\w.]+(?:\s*->\s*\w+)*\s*=(?!=)\s*)+/, '')
      next if value.match?(/\A(?:NULL|nullptr|0)\z/)

      names = native_class_resolve(value, assigns, norm, depth + 1)
      return nil unless names

      out.merge(names)
    end
  end
  public :native_unsubclassed?

  # The facts of each path in `paths`, in order: plain data (Hash, Array, Set, String, Symbol, true/false) with
  # no state and no ENV, so the result can be stored and loaded as it is.
  # Each file's facts are stored on their own too, so a list with one new or changed file rescans only that file.
  def self.native_facts(paths)
    Array(paths).map { |path| ScanCache.fetch('closed_world.native_file', [path]) { native_file_facts(path) } }
  end

  # The text a native file's identifiers come from: comments removed, and string literals that contain whitespace
  # dropped (prose such as a help string naming "Game directory"). A class name passed to mrb_class_get or
  # mrb_const_get is a whitespace-free literal, so those are kept.
  # An escape, or an unterminated literal or block comment, runs to the end of the text.
  NATIVE_CODE_TEXT_SKIP = %r{//[^\n]*|/\*.*?(?:\*/|\z)|"(?:[^"\\]|\\.|\\\z)*(?:"|\z)|'(?:[^'\\]|\\.|\\\z)*(?:'|\z)}m

  def self.native_code_text(text)
    text.gsub(NATIVE_CODE_TEXT_SKIP) do |tok|
      if tok.start_with?('/') then ''
      elsif tok.match?(/\s/) then ' '
      else tok
      end
    end
  end

  def self.native_file_facts(path)
    # Drop comments, keeping string and char literals (a "//" inside one).
    source = File.binread(path)
    text = source.gsub(%r{"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|/\*.*?\*/|//[^\n]*}m) do |tok|
      tok.start_with?('/') ? ' ' : tok
    end
    names = Set.new
    singleton_names = Set.new
    constant_writes = []
    plain_class_defines = []
    dynamic_constant_mutation = false
    refusals = []
    code_tokens = Set.new(native_code_text(text).scan(/[A-Za-z_]\w*/))
    dynamic = text.match?(NATIVE_DYNAMIC)
    defines_class = text.match?(/\bmrb_(?:const_set|const_remove|define_global_const)\b/)
    unless path.match?(NATIVE_CORE)
      source.scan(/\bmrb_(?:const_set|const_remove)\s*\(([^;]*?)\);/m) do |(body)|
        args = bc2cpp_c_call_args(body)
        target = args[2].to_s
        constant = target[/\bmrb_intern_(?:lit|cstr)\s*\(\s*\w+\s*,\s*"(\w+)"/, 1] ||
                   target[/\bMRB_SYM\((\w+)\)/, 1]
        if constant
          names << constant
          constant_writes << constant
        else
          dynamic_constant_mutation = true
        end
      end
      source.scan(/\bmrb_define_global_const\s*\(\s*\w+\s*,\s*"([A-Z]\w*)"/) do |m|
        names << m.first
        constant_writes << m.first
      end
    end
    text.scan(/\bmrb_define_(\w+)\s*\(([^;]*)/m) do |kind, body|
      literals = body.scan(C_STRING).flatten
      tokens = body.scan(MRB_SYM_TOKEN_RE).map { |m, n| resolve_mrb_sym_token(m, n) }
      if kind.match?(/\A(?:(?:class|module)(?:_under)?(?:_id)?|(?:global_)?const(?:_id)?)\z/)
        defines_class = true
        args = bc2cpp_c_call_args(body)
        positions = kind.match?(/\A(?:class|module)/) ? [1, 2] : [2]
        positions.each do |position|
          constant = args[position].to_s[/\bMRB_SYM\((\w+)\)/, 1] || args[position].to_s[/"(\w+)"/, 1]
          constant_writes << constant if constant
        end
        if kind.match?(/\A(?:class)(?:_id)?\z/) && args[2].to_s.strip == 'mrb->object_class'
          constant = args[1].to_s[/\bMRB_SYM\((\w+)\)/, 1] || args[1].to_s[/"(\w+)"/, 1]
          plain_class_defines << constant if constant
        end
        next
      end
      names.merge(literals)
      names.merge(tokens)
      # A method on the object itself (module_function, class and singleton methods): a constant receiver answers it.
      singleton_names.merge(literals) if kind.match?(/\A(?:module_function|class_method|singleton_method)/)
      # The name argument (after mrb and the class) must be spelled out.
      args = bc2cpp_c_call_args(body)
      [args[2], (args[3] if kind == 'alias')].compact.each do |arg|
        dynamic = true unless arg.match?(/\A\s*(?:#{C_STRING}|#{MRB_SYM_TOKEN_RE})\s*\z/o)
      end
    end
    include_open, include_names, alias_names, include_helpers =
      path.match?(NATIVE_CORE) ? [false, [], [], []] : native_include_facts(text, code_tokens)
    refusals << :outside_dynamic_definition if dynamic && !path.match?(NATIVE_CORE)
    # Struct members named by C strings (mruby-marshal checks for Struct).
    dynamic ||= text.match?(/"Struct"|MRB_SYM\(Struct\)/)
    text.scan(/MRB_MT_ENTRY\s*\(\s*\w+\s*,\s*#{MRB_SYM_TOKEN_RE}/o) { |m, n| names << resolve_mrb_sym_token(m, n) }
    # An engine gem's class-object table answers a constant receiver, as mrb_define_module_function / class_method did.
    if NativeOwnerMap.engine_source?(path)
      NativeOwnerMap.rom_bindings(text).each { |_expr, singleton, name, _fn| singleton_names << name if singleton }
    end
    names.merge(text.scan(C_STRING).flatten) if dynamic
    # Only mruby's own defaults: BasicObject#method_missing, Kernel#respond_to_missing?.
    refusals << :outside_method_missing if names.include?('method_missing') && !path.end_with?('/3rd/mruby/src/class.c')
    refusals << :outside_respond_to_missing if names.include?('respond_to_missing?') &&
                                               !path.end_with?('/3rd/mruby/src/kernel.c')
    {
      path: path,
      code_tokens: code_tokens.to_a,
      funcall_tokens: native_funcall_names(text),
      other_literals: native_other_literals(text),
      constant_writes: constant_writes,
      plain_class_defines: plain_class_defines,
      dynamic_constant_mutation: dynamic_constant_mutation,
      names: names.to_a,
      singleton_names: singleton_names.to_a,
      refusals: refusals,
      clone_sent: !path.match?(NATIVE_CORE) && text.match?(CLONE_SPELLING),
      freeze_possible: !path.match?(NATIVE_CORE) && text.match?(NATIVE_FREEZE),
      singleton_maker: !path.match?(NATIVE_CORE) && without_class_object_tables(text).match?(NATIVE_SINGLETON),
      defines_class: defines_class,
      touch: TouchScan.native_facts(text),
      legacy_names: native_legacy_names(text),
      include_open: include_open,
      include_names: include_names,
      alias_names: alias_names,
      include_helpers: include_helpers
    }
  end

  # NATIVE_INCLUDE: what one non-core native source can do to a module's includers. Returns [open, names, alias_names].
  #  * open: the source may include a module the scan cannot name. That is an include-family call (mrb_include_module,
  #    mrb_prepend_module, mrb_extend_*) whose module argument is not a spelled lookup; a funcall whose method name is
  #    computed or is include/prepend/extend; or the spelling of one of those method names (a native `include` method).
  #    Every module is then open (ClosedWorld#includer_candidates_uncached).
  #  * names: the last path segment of each module a spelled lookup (mrb_module_get "N") passes to an include-family call.
  #  * alias_names: the identifiers of the source, when it writes a constant to a value that could be a module object
  #    (any const write whose value is not a literal). A constant alias of a module is then seen by name.
  # A native that only defines or looks up a module's name (mrb_define_module, module_function) matches none of these.
  INCLUDE_METHOD_NAMES = %w[include prepend extend].freeze
  NATIVE_INCLUDE_WORD = /"(?:include|prepend|extend)"|MRB_SYM\((?:include|prepend|extend)\)/
  NATIVE_INCLUDE_CALL = /\bmrb_\w*(?:include|prepend|extend)\w*\s*\(([^;]*)/m
  NATIVE_DISPATCH_CALL = /\bmrb_(?:funcall(?:_id|_argv|_with_block)?|check_funcall)\s*\(([^;]*)/m
  NATIVE_CONST_WRITE = /\bmrb_(?:const_set|define_global_const|define_const(?:_id)?)\s*\(([^;]*)/m
  NATIVE_MODULE_LOOKUP = /\bmrb_(?:module_get|class_get|const_get)(?:_id)?\s*\(/
  # A method name spelled out in full: a C string, MRB_SYM / MRB_OPSYM, or an interned literal.
  NATIVE_SPELLED_NAME = /\A(?:"([^"]*)"|MRB_(?:OP)?SYM\((\w+)\)|mrb_intern_(?:lit|cstr|static)\s*\(\s*\w+\s*,\s*"([^"]*)"\s*\))\z/
  NATIVE_LITERAL_VALUE = /\A\s*(?:mrb_(?:fixnum|float|int|bool|true|false|nil|str|cstr|ary|hash)\w*\s*\(|-?\d|"|true\b|false\b|nil\b)/

  # NATIVE_LOCAL_SYMBOL: a local that names a method, bound once to its spelled names: `mrb_sym NAME = mrb_intern_lit(M,
  # "x")` (or MRB_SYM), or `const char* NAME = c ? "a" : "b"` (a ternary of literals; nullptr adds no name). NAME
  # resolves only when every occurrence in the source is that declaration, a dispatch's name argument, or an `if (NAME)`
  # test. A parameter, an assignment or an alias of NAME is another occurrence, so it is not resolved and stays open.
  NATIVE_LOCAL_SYMBOL = /(?:\bmrb_sym\s+|\bconst\s+char\s*\*\s*|\bchar\s*\*\s*)(\w+)\s*=\s*([^;]+);/
  NATIVE_NO_NAME = /\A(?:nullptr|NULL|0)\z/

  # The values of a (possibly nested) ternary: `c1 ? a : c2 ? b : d` gives a, b, d. A bare expression is its own value.
  def self.ternary_values(expr)
    pieces = expr.split('?')
    return [expr.strip] if pieces.size == 1

    values = pieces[1..].map { |piece| piece.split(':').first.to_s.strip }
    values << pieces.last.split(':').last.to_s.strip
  end

  def self.native_local_symbols(text)
    # A MRB_SYM(name) spelling (a ROM entry's key) names a method, not the local of the same name.
    blanked = text.gsub(/"((?:[^"\\\n]|\\.)*)"/) { |lit| '"' + ' ' * (lit.size - 2) + '"' }
                  .gsub(/MRB_(?:OP)?SYM\w*\(\s*\w+\s*\)/, ' ')
    dispatched = Hash.new(0)
    RegexpMatches.of(text, NATIVE_DISPATCH_CALL).each do |md|
      arg = bc2cpp_c_call_args(md[1])[2].to_s.strip
      dispatched[arg] += 1 if arg.match?(/\A\w+\z/)
    end
    symbols = {}
    RegexpMatches.of(text, NATIVE_LOCAL_SYMBOL).each do |md|
      name = md[1]
      branches = ternary_values(md[2])
      next unless branches.all? { |b| b.match?(NATIVE_NO_NAME) || b.match?(NATIVE_SPELLED_NAME) }

      tests = blanked.scan(/\bif\s*\(\s*#{name}\s*\)/).size
      next if blanked.scan(/\b#{name}\b/).size != 1 + dispatched[name] + tests

      symbols[name] = branches.reject { |b| b.match?(NATIVE_NO_NAME) }.map { |b| (m = b.match(NATIVE_SPELLED_NAME))[1] || m[2] || m[3] }
    end
    symbols
  end

  # The function a dispatch at offset +at+ sits in, when that function takes parameter +param+: [function, index].
  # The enclosing function is the last definition header before the dispatch (C and C++ do not nest functions), so a
  # dispatch whose enclosing function does not declare +param+ (a lambda, a macro) answers nil and stays open.
  NATIVE_DEFINITION = /(?<!\w)(?!(?:if|for|while|switch|catch|return|sizeof)\b)(\w+)\s*\(([^()]*)\)\s*(?:const\s*)?\{/
  def self.native_helper_param(text, at, param)
    defn = RegexpMatches.of(text[0...at], NATIVE_DEFINITION).last
    return nil unless defn

    params = defn[2].split(',').map(&:strip)
    index = params.index { |p| p.match?(/\b#{Regexp.escape(param)}\s*(?:\[\s*\])?\z/) }
    return nil unless index

    # Internal linkage (`static`) keeps the function to its own file.
    line = text[(text.rindex("\n", defn.begin(0)) || -1) + 1...defn.begin(0)]
    [defn[1], index, line.match?(/\bstatic\b/)]
  end

  def self.native_include_facts(text, code_tokens)
    open = text.match?(NATIVE_INCLUDE_WORD)
    names = Set.new
    alias_possible = false
    text.scan(NATIVE_INCLUDE_CALL) do |(body)|
      module_arg = bc2cpp_c_call_args(body).last.to_s
      spelled = module_arg.match(/"([A-Za-z_][\w:]*)"|MRB_SYM\(([A-Za-z_]\w*)\)/)
      if spelled && module_arg.match?(NATIVE_MODULE_LOOKUP)
        names << (spelled[1] || spelled[2]).split('::').last
      else
        open = true
      end
    end
    symbols = native_local_symbols(text)
    helpers = Set.new
    RegexpMatches.of(text, NATIVE_DISPATCH_CALL).each do |md|
      # The method name is enumerable when it is spelled out (a literal, a MRB_SYM / MRB_OPSYM, an interned literal,
      # a local bound to one of those, or a ternary between them); anything else is computed and could be `include`.
      name_arg = bc2cpp_c_call_args(md[1])[2].to_s.strip
      # A ternary names its two branches; its condition is not the name.
      ternary_values(name_arg).each do |branch|
        branch = branch.strip
        m = branch.match(NATIVE_SPELLED_NAME) || branch.sub(/\A\(\s*/, '').sub(/\s*\)\z/, '').match(NATIVE_SPELLED_NAME)
        words = m ? [m[1] || m[2] || m[3]] : symbols[branch]
        # A spelled include, prepend or extend is refused by NATIVE_INCLUDE_WORD, so an enumerable name needs no check here.
        if words
          next
        elsif (helper = branch.match?(/\A\w+\z/) && native_helper_param(text, md.begin(0), branch))
          # A parameter of an enclosing helper: its callers' names are checked (ClosedWorld#helper_names_enumerable?).
          helpers << helper
        else
          open = true
        end
      end
    end
    text.scan(NATIVE_CONST_WRITE) do |(body)|
      alias_possible = true unless bc2cpp_c_call_args(body).last.to_s.match?(NATIVE_LITERAL_VALUE)
    end
    [open, names.to_a, alias_possible ? code_tokens.to_a : [], helpers.to_a]
  end

  # The names a legacy touch spells (TouchScan's fallback), in the order of the text.
  def self.native_legacy_names(text)
    (text.scan(C_STRING).flatten + text.scan(/MRB_SYM\(([A-Z]\w*)\)/).flatten)
      .grep(/\A[A-Z]/).flat_map { |s| s.split('::') }.uniq
  end

  # The tokens an outside native source's funcall-family arguments name, plus the
  # hooks the VM and core call implicitly.
  def self.native_funcall_names(text)
    names = Set.new(IMPLICIT_HOOKS)
    text.scan(FUNCALL_CALL) do |(body)|
      arg = bc2cpp_c_call_args(body)[2].to_s
      arg.scan(MRB_SYM_TOKEN_RE) { |m, n| names << resolve_mrb_sym_token(m, n) }
      arg.scan(C_STRING) { |(lit)| names << lit }
    end
    names.to_a
  end

  # The string literals of a native source that are not the name of a registration.
  def self.native_other_literals(text)
    counts = Hash.new(0)
    text.scan(C_STRING) { |(lit)| counts[lit] += 1 }
    text.scan(/\bmrb_define_(\w+)\s*\(([^;]*)/m) do |kind, body|
      next unless NATIVE_REGISTRATION_KINDS.include?(kind)

      lit = bc2cpp_c_call_args(body)[2].to_s[/\A\s*#{C_STRING}\s*\z/o, 1]
      counts[lit] -= 1 if lit
    end
    counts.filter_map { |lit, n| lit if n.positive? }
  end

  # Every `def name` anywhere in the text, not only at a line start: foreign_method_names
  # misses `private def loop` (mruby's Kernel#loop), which a proven miss must not call absent.
  def self.broad_def_names(paths)
    # Cached as an Array: mruby's Marshal cannot dump a Set.
    ScanCache.fetch('closed_world.broad_def_names', Array(paths), cache_absent: false) do
      Array(paths).each_with_object(Set.new) do |path, names|
        text = File.read(path, encoding: 'BINARY')
        text.scan(/(?:^|[\s;(])def\s+(?:[A-Za-z_]\w*\.)?(#{FOREIGN_METHOD_NAME_RE})/o) { |(n)| names << n }
      end.to_a
    end.to_set
  end

  def scan_outside_ruby(paths)
    paths = Array(paths)
    facts = ScanCache.fetch('closed_world.ruby', paths) { self.class.ruby_facts(paths) }

    ruby_names = Set.new(facts.fetch(:ruby_names))
    global!(:outside_method_missing) if ruby_names.include?('method_missing')
    global!(:outside_respond_to_missing) if ruby_names.include?('respond_to_missing?')
    @outside_ruby_names.merge(ruby_names)
    @outside_def_names.merge(facts.fetch(:broad_defs))
    @outside_names.merge(ruby_names)

    facts.fetch(:files).each do |file|
      path = file.fetch(:path)
      @ruby_tokens[path] = Set.new(file.fetch(:tokens))

      file.fetch(:supers).each { |sup| @outside_ruby_supers << sup }

      touch = file.fetch(:touch)
      if touch
        if touch.fetch(:legacy)
          names = Set.new(touch.fetch(:names))
          @touches << Touch.new(path, names, {}, touch.fetch(:note), false)
        else
          hard = Set.new(touch.fetch(:hard))
          @touches << Touch.new(path, hard, touch.fetch(:evidence), '', false) unless hard.empty?
        end
      end

      @clone_sent = true if file.fetch(:clone_sent)
      @freeze_possible = true if file.fetch(:freeze_possible)
      @singleton_makers << [path, :ruby] if file.fetch(:singleton_maker)
      note_outside_singletons(file)

      file.fetch(:constant_writes).each { |name| note_outside_constant_write(name) }

      global!(:outside_dynamic_definition) if file.fetch(:dynamic)
      @dynamic_constant_mutation = true if file.fetch(:dynamic_constant_mutation)
      global!(:outside_class_factory) if file.fetch(:class_factory)
      @struct_factory_used = true if file.fetch(:struct_factory)
    end
    # Every constant write is noted by now, native ones included, so the loops can be judged.
    facts.fetch(:files).each { |file| resolve_definer_loops(file) }
  end

  # DYNAMIC_NAME_LOOPS: a loop over a literal (inline, or a constant the program writes once) whose body only defines
  # names built from its loop variable defines exactly those names. They join the outside-defined names. A constant
  # written again, or a constant-free loop that is not a literal, keeps the global refusal.
  def resolve_definer_loops(file)
    path = file.fetch(:path)
    file.fetch(:definer_loops).each do |loop|
      const = loop.fetch(:const)
      exact = const.nil? || (@outside_constant_write_counts[const] == 1 && @constant_write_counts[const].zero? &&
                             !@dynamic_constant_mutation)
      unless exact
        global!(:outside_dynamic_definition)
        next
      end
      loop.fetch(:names).each do |name|
        @outside_dyn_names << name
        @outside_ruby_names << name
        @outside_names << name
        (@outside_name_paths[name] ||= Set.new) << path
      end
    end
  end

  def self.ruby_facts(paths)
    paths = Array(paths)
    {
      ruby_names: foreign_method_names(paths).to_a,
      broad_defs: broad_def_names(paths).to_a,
      files: paths.map { |path| ruby_file_facts(path) }
    }
  end

  # `tok.chomp('=').chomp('?').chomp('!')` for a token of the identifier scans here (`[A-Za-z_]\w*[?!=]?`), which
  # ends in at most one of those; an unsuffixed token is returned as is, not copied.
  def self.token_stem(tok)
    tok.end_with?('=', '?', '!') ? tok.chop : tok
  end

  # DYNAMIC_NAME_LOOPS: the Symbol names of `CONST = %i[...].freeze` or `CONST = { key: "...", ... }.freeze` written
  # in +text+ (once, plain literal), or nil when the literal is not one of those shapes.
  def self.loop_literal_names(text, const)
    definition = text.match(/\b#{const}\s*=(?![=~>])\s*(?:\{(?<hash>[^{}]*)\}\.freeze|%i\[(?<sym>[^\]]*)\]\.freeze)/)
    return nil unless definition

    if definition[:hash]
      body = definition[:hash]
      return nil unless body.match?(/\A\s*(?:\w+:\s*"[^"\n]*"\s*,?\s*)+\z/)

      body.scan(/(\w+):/).flatten
    else
      names = definition[:sym].split
      names.all? { |n| n.match?(/\A\w+\z/) } && !names.empty? ? names : nil
    end
  end

  # DYNAMIC_NAME_LOOPS: the body of the block +head+ opens (up to the `end` at the same indentation), or nil.
  def self.loop_body(text, head)
    line_start = text.rindex("\n", head.begin(0) - 1)
    line_start = line_start ? line_start + 1 : 0
    indent = text[line_start..][/\A[ \t]*/]
    rest = text[head.end(0)..]
    close = rest.match(/^#{Regexp.escape(indent)}end\b/)
    close && rest[0...close.begin(0)]
  end

  # DYNAMIC_NAME_LOOPS: { const:, names:, dyn: } for the loop +head+ opens, where +dyn+ counts its dynamic definers and
  # +names+ is what they define over every value of the loop. nil when a definer in it cannot be enumerated.
  def self.definer_loop(text, head)
    body = loop_body(text, head)
    return nil unless body

    dyn = body.scan(RUBY_DYNAMIC).size + body.scan(RUBY_DYNAMIC_SYMBOL).size
    return { const: head[:const], names: [], dyn: 0 } if dyn.zero?
    var = head[:var]
    # The loop variable is read as bound: no block parameter or assignment of it in the body.
    return nil if body.match?(/\|[^|\n]*\b#{var}\b[^|\n]*\||\b#{var}\s*(?:[-+*\/|&]?=)(?!=)/)

    values = head[:words] ? head[:words].split : loop_literal_names(text, head[:const])
    return nil unless values && !values.empty? && values.all? { |v| v.match?(/\A\w+\z/) }

    args = RegexpMatches.of(body, RUBY_DEFINER_ARG)
    return nil unless args.size == dyn

    names = args.flat_map do |arg|
      if arg[:var]
        return nil unless arg[:var] == var

        values
      else
        return nil unless arg[:dsym].scan(/#\{(\w+)\}/).flatten.all? { |v| v == var }

        values.map { |value| arg[:dsym].gsub("\#{#{var}}", value) }
      end
    end
    return nil unless names.all? { |n| n.match?(/\A[A-Za-z_]\w*[?!]?\z/) }

    { const: head[:const], names: names.uniq, dyn: dyn }
  end

  # FOREIGN_DEFINER_CALLS: `define_method(a, b, c)` with three or more arguments is not Module#define_method, which
  # takes one or two (it would raise ArgumentError and define nothing): RBS's DefinitionBuilder has its own
  # `define_method(methods, definition, method, ...)`. Keyword arguments count as the one Hash they would pass. Only a
  # parenthesised list whose top level the scan below reads exactly is counted: names, calls, `::`, ternaries and
  # comparisons, Symbols, nested brackets; a string, comment, block pass or splat (`&`, `*`, which can change the
  # count) stops the scan, and that call stays a dynamic definer.
  def self.foreign_definer_calls(text)
    RegexpMatches.of(text, /\bdefine_method\(/).count do |match|
      args = definer_call_args(text, match.end(0))
      next false unless args

      keywords, positional = args.partition { |arg| arg.match?(/\A\s*[a-z_]\w*:(?!:)/) }
      positional.size + (keywords.empty? ? 0 : 1) >= 3
    end
  end

  # The top-level arguments of the call whose `(` ends just before +from+, or nil when the scan cannot read them exactly.
  def self.definer_call_args(text, from)
    depth = 0
    args = [+'']
    text[from..].each_char do |char|
      case char
      when '(', '[', '{' then depth += 1
      when ')', ']', '}'
        return args.all? { |arg| arg.match?(/\S/) } ? args : nil if depth.zero? && char == ')'
        return nil if depth.zero?

        depth -= 1
      when ',' then (args << +'') && next if depth.zero?
      when /[\w\s.:?!=<>+\-|]/ then nil
      else return nil
      end
      args.last << char
    end
    nil
  end

  def self.ruby_file_facts(path)
    text = File.read(path, encoding: 'BINARY').gsub(/^\s*#.*$/, '')

    tokens = Set.new
    text.scan(/[A-Za-z_]\w*[?!=]?/) do |tok|
      tokens << tok
      tokens << ClosedWorld.token_stem(tok)
    end

    supers = text.scan(/^\s*class\s+[\w:]+\s*<\s*([\w:]+)/).map { |(sup)| sup.split('::').last }

    scan = TouchScan.ruby(text)
    touch =
      if scan.legacy
        names = text.scan(/\b[A-Z]\w*/).to_set
        { legacy: true, names: names.to_a, note: "legacy (#{scan.legacy}): spells #{names.size} constants" }
      else
        { legacy: false, hard: scan.hard.to_a, evidence: scan.evidence }
      end

    core = CoreDefs.core_source?(path)

    # DYNAMIC_NAME_LOOPS: every dynamic definer is either inside a loop this file enumerates exactly, or unresolved.
    loops = RegexpMatches.of(text, RUBY_LOOP_HEAD).map { |head| definer_loop(text, head) }
    covered = loops.compact.sum { |loop| loop[:dyn] }
    dynamic_total = text.scan(RUBY_DYNAMIC).size + text.scan(RUBY_DYNAMIC_SYMBOL).size - foreign_definer_calls(text)
    dynamic_unresolved = covered != dynamic_total
    definer_loops = dynamic_unresolved ? [] : loops.compact.select { |loop| loop[:dyn].positive? }
    class_factory, struct_factory = ruby_factory_facts(text)
    # INSTANCE_SINGLETON_TAINT: read from the syntax tree; a source that does not parse keeps the text scan, unplaced.
    singletons = core ? nil : OutsideSingletons.scan(path)

    {
      path: path,
      tokens: tokens.to_a,
      supers: supers,
      touch: touch,
      # A full-line comment sends nothing; any other spelling (code or a string) counts.
      clone_sent: text.gsub(/^[ \t]*#.*$/, '').match?(/\bclone\b/),
      freeze_possible: !core && text.match?(/\bfreeze\b/),
      singleton_maker: !core && (singletons ? singletons.fetch(:maker) : text.match?(RUBY_SINGLETON)),
      singleton_taint: core ? [] : singletons&.fetch(:taint),
      singleton_modules: singletons ? singletons.fetch(:modules) : {},
      open_modules: singletons ? singletons.fetch(:open_modules) : [],
      constant_writes: text.scan(/\b(?:[A-Z]\w*::)*([A-Z]\w*)\s*=(?!=|>)/).map(&:first),
      dynamic: dynamic_unresolved,
      definer_loops: definer_loops,
      dynamic_constant_mutation: text.match?(RUBY_CONST_DYNAMIC),
      class_factory: class_factory,
      struct_factory: struct_factory
    }
  end

  # OUTSIDE_STRUCT_FACTORY: `Struct.new(:a, :b)` or `Struct.new(:a, keyword_init: true)`, on one line, with no block
  # after it. Its class has Symbol members only (accessors mruby-struct defines natively under computed names) and no
  # Ruby body, so it is the program's own Struct.new case (@struct_factory_used: factory_class_free? fails and those
  # names keep their unknown native owner) rather than a global refusal. A block (whose `def`s OutsideRubyOwners
  # would place on the enclosing body), any other argument, or a spelling this does not read stays a class factory.
  RUBY_SAFE_STRUCT_NEW = /\GStruct\.new\([ \t]*:\w+(?:[ \t]*,[ \t]*:\w+)*(?:[ \t]*,[ \t]*keyword_init:[ \t]*true)?[ \t]*\)
                          (?![ \t]*(?:do\b|\{))/x
  # A factory receiver: `Class` or `Struct`, bare, `::`-rooted or namespaced (`Foo::Class`, which mruby's scoped lookup
  # may resolve to the top-level class). A namespaced one is the file's own class only when the file defines a class of
  # that name (RBS's `AST::Declarations::Class`).
  RUBY_FACTORY_NEW = /(?<![\w:])(?:::)?(?<recv>Class|Struct)\.new\b|(?<ns>\w::)(?<recv>Class|Struct)\.new\b/

  # [class_factory, struct_factory] of a file's text (see RUBY_SAFE_STRUCT_NEW).
  def self.ruby_factory_facts(text)
    class_factory = false
    struct_factory = false
    RegexpMatches.of(text, RUBY_FACTORY_NEW).each do |match|
      at = match.begin(:recv)
      next if match[:ns] && text.match?(/^[ \t]*class[ \t]+#{match[:recv]}\b/)

      if match[:recv] == 'Struct' && text.match?(RUBY_SAFE_STRUCT_NEW, at) && text.match(RUBY_SAFE_STRUCT_NEW, at)&.begin(0) == at
        struct_factory = true
      else
        class_factory = true
      end
    end
    [class_factory, struct_factory]
  end

  # YIELD_REACH: the method names outside code can call back into Ruby by. Native code
  # names them in the funcall family (a variable name is one of the send-like natives, which the
  # yield analysis treats as seeds); foreign Ruby can call any identifier it spells.
  FUNCALL_CALL = /\bmrb_(?:funcall(?:_id|_argv|_with_block)?|check_funcall|obj_respond_to|respond_to)\s*\(([^;]*)/m
  # What the VM and mruby core invoke on user objects implicitly.
  IMPLICIT_HOOKS = %w[initialize initialize_copy respond_to_missing? const_missing inherited included extended
                      prepended method_added singleton_method_added method_removed to_s inspect to_str to_ary to_a
                      to_hash to_proc to_i to_f to_int hash eql? equal? coerce exception message backtrace each
                      call].freeze

  # SETTER_POOLS: every string literal of an outside native source except the name a registration
  # (`mrb_define_method(M, cls, "x=", ...)`) gives, so a setter only a registration spells is not one native code calls.
  NATIVE_REGISTRATION_KINDS = %w[method class_method module_function].freeze

  def merge_outside_tokens(path, text)
    tokens = (@ruby_tokens[path] = Set.new)
    text.scan(/[A-Za-z_]\w*[?!=]?/) do |tok|
      tokens << tok
      tokens << ClosedWorld.token_stem(tok)
    end
  end

  public

  # Does an outside native source spell +literal+ as a string other than a registration's method name?
  def outside_native_literal?(literal)
    @native_other_literals.include?(literal)
  end

  # Does any outside (foreign Ruby) source spell the identifier +token+?
  def outside_ruby_token?(token)
    @ruby_tokens.each_value.any? { |tokens| tokens.include?(token) }
  end

  # Names outside code can call Ruby methods by: native funcall names and every identifier of the
  # foreign Ruby sources, minus the Ruby files the caller analyses itself (`except_files`).
  # DEFINE_METHOD_SITES: `define_method` in a class body still reaches mruby's own
  # Module#define_method, so a recognized site installs exactly the method it spells. Anything
  # that could rename, wrap or intercept that send withdraws every site.
  def define_method_sites_trusted?
    return @define_method_trusted if defined?(@define_method_trusted)

    @define_method_trusted = !@global_refusal && !installer_intercepted?('define_method')
  end

  # DYNAMIC_NAME_LOOPS: a define_method site may be a definition for +name+ when the program trusts define_method
  # and no outside dynamic definer can name +name+ (the names of the literal loops it could be, not every name).
  def define_method_name_trusted?(name)
    define_method_sites_trusted? && !@outside_dyn_names.include?(name)
  end

  # ALIAS_SITES: the same question for `alias_method`, whose class-body sites the registry
  # defines as copies of the method they name.
  def alias_method_trusted?
    return @alias_method_trusted if defined?(@alias_method_trusted)

    @alias_method_trusted = !@global_refusal && !installer_intercepted?('alias_method')
  end

  def outside_call_names(except_files)
    names = @native_tokens.dup
    @ruby_tokens.each { |path, toks| names.merge(toks) unless except_files.include?(path) }
    names
  end

  private

  # -- the closed world's own dynamic definitions ------------------------------

  def installer_intercepted?(name)
    return true if @registry.key?(name) || @unknown_defs.include?(name)
    return true if @outside_def_names.include?(name) || @outside_ruby_names.include?(name)
    return true if @outside_name_paths.fetch(name, []).any? { |path| !path.match?(NATIVE_CORE) }

    @ireps.each_value.any? do |irep|
      BytecodeIR.for(irep).instructions_with_op(*NAME_BINDING_OPS).any? do |insn|
        insn.typed.any? { |operand| operand.value.to_s == name }
      end
    end
  end


  def scan_closed_world
    registered = Set.new
    @registry.each_value { |defs| defs.each { |d| registered << d.irep if d.irep } }
    children = @ireps.values.flat_map(&:reps).compact.to_set
    @ireps.each do |label, irep|
      own_source = !(children.include?(label) && CoreDefs.core_source?(irep.file))
      BytecodeIR.for(irep).each_source do |insn, idx|
        scan_singleton_maker(irep, idx, insn) if own_source
        case insn.op
        when :TDEF, :SDEF
          child = irep.reps[insn.block_index]
          note_unknown_def(insn.sym, insn.op == :TDEF ? irep.label : nil) unless registered.include?(child)
        when :DEF
          sym = insn.sym_token
          child = def_method_body(irep, idx, insn)
          note_unknown_def(sym, irep.label) unless child && registered.include?(child)
        when SEND_OPS
          scan_probe_send(irep, idx, insn) if PROBE_SENDS.include?(insn.sym)
          scan_send(irep, idx, insn)
        when :UNDEF
          @removed_names << insn.sym
        when :LOADSYM, :SYMBOL
          # A %i[] element is a SYMBOL (its name is in the pool) and a method name can be sent from it just the same.
          sym = loaded_symbol_name(irep, insn)
          next unless sym

          # CLONE_SYMBOL_PROOF: a `:clone` that is only compared or listed (`%i[clone dup].include?(m)`) copies nothing;
          # resolve_installer_symbol_loads counts it as a clone only when its value may reach a send.
          @clone_symbol_loads << [irep, idx, insn.reg] if sym == 'clone'
          @dynamic_visibility = true if VISIBILITY_SENDS.include?(sym)
          # An installer or rebinder name loaded as a symbol may be sent by name: its value must stay on safe paths
          # (resolve_installer_symbol_loads), not refuse the program outright.
          @installer_symbol_loads << [irep, idx, insn.reg, sym] if INSTALLER_SENDS.include?(sym) || CONST_REBINDERS.include?(sym)
          @name_installer_loads << [irep, idx, insn.reg, sym] if NAME_INSTALLER_NAMES.include?(sym)
        when :GETCONST, :GETMCNST
          const = insn.const_name
          @basic_object_referenced = true if const == 'BasicObject'
          scan_factory(irep, idx, insn, const) if CLASS_FACTORIES.include?(const) && !scoped_constant_of_other_scope?(irep, idx, insn)
        when :CLASS, :MODULE
          name = insn.sym_token
          if name
            bare = name.split('::').last
            @class_constant_names << bare
            @class_declared_names << bare unless insn.op == :CLASS && root_reopen?(irep, idx, insn)
          end
        when :SETCONST, :SETMCNST
          name = insn.const_name.to_s
          @rebound << name
          qualified = insn.op == :SETCONST && @constant_write_sites[[irep.label, idx]]
          if qualified
            @rebound_qualified[qualified] += 1
          else
            @rebound_bare << name
          end
          @constant_write_counts[name] += 1
          @deferred_constant_writes << name unless @walked.include?(irep.label)
        end
      end
    end
    resolve_struct_splats
    resolve_struct_class_members
    resolve_deferred_mixin_modules
    resolve_installer_symbol_loads
    # A read name (scan_factory) can run a definition the scan only finishes seeing here.
    global!(:class_factory_escape) unless @factory_read_names.all? { |name| ownerless_native_dispatch_safe?(name) }
  end

  # DEF reads the method value from R[a+1], independently of intervening METHODs.
  # A join must agree on one body: registration of another body elsewhere proves no attribution here.
  def def_method_body(irep, index, insn)
    register = insn.reg
    return nil unless register

    writers = BytecodeIR.reaching_writer_indices(irep, index, (register + 1))
    return nil unless writers

    bodies = writers.map do |writer|
      method = BytecodeIR.for(irep).source_at(writer)
      return nil unless method.op == :METHOD && method.block_index

      child = irep.reps[method.block_index]
      return nil unless child

      child
    end.uniq
    bodies.first if bodies.size == 1
  end

  # -- singleton classes --------------------------------------------

  def compute_instance_singleton_taint
    return {} if exact_instances_singleton_free?
    return unplaced_singleton(:global_refusal) if @global_refusal

    native = @singleton_makers.find { |_, kind| kind == :native }
    return unplaced_singleton("native #{native[0]}") if native

    taint = Hash.new { |h, k| h[k] = Set.new }
    @outside_singleton_taint.each do |path, entries|
      return unplaced_singleton("outside #{path}") if entries.nil?

      entries.each { |klass, gain, modules| add_singleton_gain(taint, klass, gain || module_gain(modules)) }
    end
    makers = @singleton_opens.map { |irep, idx, insn| [irep, idx, insn, insn.op == :SDEF ? [insn.sym.to_s] : :any] } +
             @singleton_sends.map { |irep, idx, insn| [irep, idx, insn, nil] }
    makers.each do |irep, idx, insn, gain|
      next if !SELF_SEND_OPS.include?(insn.op) && class_object_value?(irep, idx, insn.reg)

      gain ||= singleton_send_gain(irep, idx, insn)
      # A receiver that cannot be placed may be any object: a bounded gain still holds for every class.
      klass = instance_singleton_place(irep, idx, insn) || (gain == :any ? nil : 'Object')
      return unplaced_singleton("#{irep.label}:#{idx} #{insn.sym || insn.op} in #{File.basename(irep.file.to_s)}") unless klass

      add_singleton_gain(taint, klass, gain)
    end
    @singleton_symbol_loads.each do |irep, idx, reg|
      # The value only compared or listed (resolve_installer_symbol_loads' proof) is never sent.
      next if installer_symbol_value_safe?(irep, idx, reg, 0, false)

      return unplaced_singleton("#{irep.label}:#{idx} a maker Symbol")
    end
    taint.to_h { |klass, gain| [klass, gain == :any ? :any : gain.freeze] }
  end

  SELF_SEND_OPS = %i[SSEND SSEND0 SSENDB].freeze
  # A module's hooks that run on what it is mixed into.
  MIXIN_HOOKS = %w[extended extend_object included append_features prepended prepend_features].freeze

  # `reg` holds a class or module object on every path: `self` in a class body, or a constant that names a class or
  # module the closed world or the core declares and that nothing (bytecode or outside source) binds another value
  # to. Stricter than class_object_register?, which also takes a constant only outside code writes (`ENV`) and a
  # fresh `Object.new`, both instances.
  def class_object_value?(irep, idx, reg)
    return false if reg.nil?

    every_definition?(irep, idx, reg) do |writer, _|
      case writer.op
      # The root body's self is the main object, an instance of Object.
      when :LOADSELF then @walked.include?(irep.label) && irep.label != @root_label
      when :GETCONST, :GETMCNST
        name = simple((writer.op == :GETCONST ? writer.const_name : writer.mcnst_name).to_s)
        class_constant?(name) && !@outside_constant_writes.include?(name) && named_class_or_module?(name)
      else false
      end
    end
  end

  def named_class_or_module?(name)
    return true if !classes_named(name).empty? || @module_names.any? { |mod| simple(mod) == name }

    super_of, mixins = CoreHierarchySigs.hierarchy
    super_of.key?(name) || mixins.each_value.any? { |mods| Array(mods).include?(name) }
  end

  def unplaced_singleton(why)
    @singleton_taint_unplaced = why.to_s
    nil
  end

  def add_singleton_gain(taint, klass, gain)
    if gain == :any || taint[klass] == :any
      taint[klass] = :any
    else
      taint[klass].merge(gain)
    end
  end

  # What the singleton class `extend` gives with these module references can answer: the instance methods of every
  # module whose path ends in one of them (a superset, as resolve_deferred_mixin_modules), or :any when one is not
  # found or not fully listed.
  def module_gain(refs)
    outside = @outside_singleton_modules
    owners = Set.new
    @registry.each_value { |defs| defs.each { |d| owners << d.owner } }
    known = (outside.keys + @module_names.to_a + owners.to_a).uniq
    names = Set.new
    refs.each do |ref|
      bare = ref.delete_prefix('::')
      matches = known.select { |mod| mod == bare || mod.end_with?("::#{bare}") }
      return :any if matches.empty?

      matches.each do |mod|
        return :any unless module_listed?(mod, owners)

        names.merge(outside.fetch(mod, []))
        @registry.each { |name, defs| names << name if defs.any? { |d| d.owner == mod } }
        # A module of the closed world's own Ruby may also define a name by Symbol (a define_method loop the registry
        # does not hold): CodeGen reads this mark as every name the build installs that way (symbol_installed_names).
        names << SINGLETON_INSTALLED if @module_names.include?(mod) || owners.include?(mod)
      end
    end
    names
  end

  # In a gain: also every name the closed world's own Ruby installs by Symbol.
  SINGLETON_INSTALLED = :installed

  # No mixin into +mod+, no class of that name, no computed definer and no extend hook: its instance methods are the
  # ones listed.
  def module_listed?(mod, owners)
    return false if @outside_open_modules.include?(mod) || @declared_classes.include?(mod)
    return false if @mixins.nil? || !@mixins.fetch(mod, []).empty? || @unknown_mixins&.include?(mod)

    hooks = owners.include?("#{mod}.singleton") &&
            MIXIN_HOOKS.any? { |hook| @registry.fetch(hook, []).any? { |d| d.owner == "#{mod}.singleton" } }
    !hooks
  end

  # The declared class whose instance `self` is at a maker in the closed world's own Ruby, or nil: the maker's receiver
  # (SDEF and SCLASS's register, a send's receiver, implicit in SSEND) is `self` on every path, in the body of a method
  # the registry defines on a class (not a module, not a class object). A block's `self` may be rebound, so a block is
  # not placed.
  def instance_singleton_place(irep, idx, insn)
    self_receiver = %i[SSEND SSEND0 SSENDB].include?(insn.op) ||
                    (insn.reg && every_definition?(irep, idx, insn.reg) { |writer, _| writer.op == :LOADSELF })
    return nil unless self_receiver

    owners = method_body_owners.fetch(irep.label, [])
    return nil unless owners.size == 1

    owner = owners.first
    return nil if owner.end_with?('.singleton') || module_declared?(owner) || !class_declared?(owner)

    owner
  end

  # { irep label => the owners the registry defines that irep's body on }.
  def method_body_owners
    @method_body_owners ||= begin
      map = Hash.new { |h, k| h[k] = [] }
      @registry.each_value { |defs| defs.each { |d| map[d.irep] << d.owner if d.irep && !d.core } }
      map.transform_values(&:uniq)
    end
  end

  # The names whose lookup a maker send may change on its receiver: define_singleton_method(:x) answers x, a
  # `singleton_class` whose value is only read as below changes what those reads say, and any other maker send may
  # define anything (:any).
  def singleton_send_gain(irep, idx, insn)
    return :any unless insn.reg

    case insn.sym
    when 'define_singleton_method'
      names = literal_symbol_args(irep, idx, insn, 1)
      names && names.size == 1 ? names : :any
    when 'singleton_class' then singleton_class_use_gain(irep, idx, insn.reg)
    else :any
    end
  end

  # The value `x.singleton_class` wrote to +reg+ at +idx+ is only the receiver of `include?`, of an `include` or
  # `prepend` of a listed module (its methods), or of a `remove_method`/`undef_method` of literal names, directly or
  # through `send` (those names). Any other use may define anything: :any.
  def singleton_class_use_gain(irep, idx, reg)
    uses = FactoryFlow.uses(irep, idx, reg)
    return :any if uses.nil? || uses.empty?

    program = BytecodeIR.for(irep)
    gain = Set.new
    uses.each do |use_idx, use_reg|
      use = program.source_at(use_idx)
      return :any unless SEND_OPS.include?(use.op) && !SELF_SEND_OPS.include?(use.op) && use.reg == use_reg

      names =
        case use.sym
        when 'include?' then []
        when 'include', 'prepend'
          ref = mixin_module_ref(irep, use_idx, use)
          ref && ref[:name] ? module_gain([ref[:name]]) : :any
        when 'remove_method', 'undef_method' then literal_symbol_args(irep, use_idx, use, :all)
        when 'send', '__send__', 'public_send'
          all = literal_symbol_args(irep, use_idx, use, :all)
          all && %w[remove_method undef_method].include?(all.first) && all.size > 1 ? all.drop(1) : nil
        end
      return :any if names.nil? || names == :any

      gain.merge(names)
    end
    gain.to_a
  end

  # The Symbol literals a send passes at argument position +range+ (1-based), or at every one for :all, or nil when the
  # argument list is not plain or one of them is not a literal.
  def literal_symbol_args(irep, idx, insn, range)
    return nil unless insn.reg && insn.plain_fixed_argc?

    argc = insn.argc.to_i
    positions = range == :all ? (1..argc).to_a : [range]
    return nil if positions.empty? || positions.max > argc

    positions.map do |i|
      names = []
      literal = every_definition?(irep, idx, insn.reg + i) do |writer, _|
        name = %i[LOADSYM SYMBOL].include?(writer.op) ? loaded_symbol_name(irep, writer) : nil
        names << name if name
        !name.nil?
      end
      return nil unless literal && names.uniq.size == 1

      names.first
    end
  end

  def note_outside_singletons(file)
    @outside_singleton_taint << [file.fetch(:path), file.fetch(:singleton_taint)]
    file.fetch(:singleton_modules).each { |mod, names| @outside_singleton_modules[mod].concat(names) }
    @outside_open_modules.merge(file.fetch(:open_modules))
  end

  # Judged after the scan: class_constant? needs every SETCONST counted.
  def singleton_makers
    @singleton_makers_all ||= @singleton_makers + @singleton_opens.filter_map do |irep, idx, insn|
      [irep.label, insn.op] unless class_object_register?(irep, idx, insn.reg)
    end
  end
  # constructor_pools_refusal (codegen_constructor_pools.rb) names the makers it refuses over.
  public :singleton_makers

  def scan_singleton_maker(irep, idx, insn)
    case insn.op
    when :SDEF, :SCLASS
      @singleton_opens << [irep, idx, insn]
    when :LOADSYM, :SYMBOL
      name = loaded_symbol_name(irep, insn)
      return unless name && SINGLETON_MAKERS.include?(name)

      @singleton_makers << [irep.label, name]
      @singleton_symbol_loads << [irep, idx, insn.reg]
    when SEND_OPS
      return unless SINGLETON_MAKERS.include?(insn.sym)

      @singleton_makers << [irep.label, insn.sym]
      @singleton_sends << [irep, idx, insn]
    end
  end

  # `reg` holds a class or module object (`self` in a class body, a constant nothing assigns a
  # value to) or a fresh `Object.new` at `idx`, never an Array/Hash/Range/String.
  def class_object_register?(irep, idx, reg)
    every_definition?(irep, idx, reg) do |writer, definition|
      case writer.op
      when :LOADSELF then @walked.include?(irep.label)
      when :GETCONST, :GETMCNST then class_constant?(writer.op == :GETCONST ? writer.const_name : writer.mcnst_name)
      when :SEND0 then writer.sym == 'new' && fresh_object_class?(irep, definition.index, definition.reg)
      else false
      end
    end
  end

  # `reg` holds a class or module object on every path: a constant nothing assigns a value to, or `self` in a
  # class body. Unlike class_object_register? it refuses a fresh `Object.new`, whose singleton class an
  # instance of a proven set can have.
  def class_constant_target?(irep, idx, reg)
    every_definition?(irep, idx, reg) do |writer|
      case writer.op
      when :LOADSELF then @walked.include?(irep.label)
      when :GETCONST then class_constant?(writer.const_name)
      when :GETMCNST then class_constant?(writer.mcnst_name)
      else false
      end
    end
  end

  # Every definition of +reg+ reaching the read at +idx+ passes the block, which gets the defining instruction and
  # its Definition. A join has one definition per branch, so the nearest writer says nothing about the others
  # (BytecodeIR.reaching_definitions). An entry value, no definition and a refused query all answer false.
  def every_definition?(irep, idx, reg)
    defs = BytecodeIR.reaching_definitions(irep, idx, reg, through_handlers: true, shared: true)
    return false if defs.nil? || defs.empty? || defs.any?(&:entry?)

    defs.all? { |definition| yield BytecodeIR.for(irep).source_at(definition.index), definition }
  end

  # No SETCONST binds a value to the name, so it can only name a class or module.
  def class_constant?(name)
    @constant_write_counts[name].zero?
  end

  # The receiver of the `new` at +idx+ is the constant Object on every path (a join of Object and Foo is not).
  def fresh_object_class?(irep, idx, reg)
    standard_constructor_lookup? && irep.agreed_constant_name(idx, reg, through_handlers: true) == 'Object'
  end

  def loop_installer_sites
    @loop_installer_sites ||= LoopInstallers.sites(@registry)
  end

  # The name a symbol load produces: LOADSYM names it in the operand, SYMBOL in the irep's pool. Nil if it is not a string.
  def loaded_symbol_name(irep, insn)
    return insn.sym_token if insn.op == :LOADSYM

    entry = irep.pool && insn.pool_index && irep.pool[insn.pool_index.to_i]
    entry.is_a?(String) ? entry : nil
  end

  # Names whose only use, as a value, is a read that never sends its argument: a set or key test, equality, a hash or a
  # string form. Each must be native (a Ruby method of that name could send its argument).
  INSTALLER_SAFE_READS = %w[include? key? member? == != eql? equal? === hash to_s inspect].freeze
  # Each step (a container, a freeze, a constant binding and its reads, an Array#+, a map(&:to_s)) is one level; the
  # compiler's own tables chain several (`INSTALLERS = (%i[...] + ACCESSORS).freeze`), so the bound leaves room for them.
  INSTALLER_SYMBOL_DEPTH = 10

  # Every LOADSYM of an installer or rebinder name must be on a safe path: its value (and any array or hash holding it, or
  # constant bound to it, read anywhere in the program) reaches only native reads. A value that reaches a send, a return,
  # an unknown container or an unknown read keeps the refusal, since mruby would send the name at run time.
  def resolve_installer_symbol_loads
    @installer_symbol_loads.each do |irep, idx, reg, _sym|
      if installer_symbol_value_safe?(irep, idx, reg, 0, false)
        @proven_symbol_loads << [irep.label, idx]
      else
        global!(:dynamic_install)
      end
    end
    @clone_symbol_loads.each do |irep, idx, reg|
      @clone_sent = true unless installer_symbol_value_safe?(irep, idx, reg, 0, false)
    end
    # These names refuse nothing here; CodeGen's installed-name scan asks for the proof instead (symbol_load_proven?).
    @name_installer_loads.each do |irep, idx, reg, _sym|
      @proven_symbol_loads << [irep.label, idx] if installer_symbol_value_safe?(irep, idx, reg, 0, false)
    end
  end

  # The names CodeGen#collect_installed_names treats as installers when loaded as a symbol (NAME_INSTALLER_SENDS).
  NAME_INSTALLER_NAMES = %w[alias_method define_method undef_method remove_method].freeze

  # Whether the symbol load at +idx+ of irep +label+ was proven to stay off every send path
  # (resolve_installer_symbol_loads): its name is then only compared, never installed by name.
  def symbol_load_proven?(label, idx)
    @proven_symbol_loads.include?([label, idx])
  end
  public :symbol_load_proven?

  # +container+: the value followed is a literal Array or Hash holding the symbol (false: the symbol itself). It decides
  # which class answers a send whose receiver is that value (receiver_read_native?).
  def installer_symbol_value_safe?(irep, idx, reg, depth, container)
    return false if depth > INSTALLER_SYMBOL_DEPTH || reg.nil?

    uses = FactoryFlow.uses(irep, idx, reg)
    return false unless uses

    uses.all? { |use_idx, use_reg| installer_symbol_use_safe?(irep, use_idx, use_reg, depth, container) }
  end

  def installer_symbol_use_safe?(irep, use_idx, use_reg, depth, container)
    insn = BytecodeIR.for(irep).source_at(use_idx)
    case insn.op
    when :ARRAY, :HASH
      installer_symbol_value_safe?(irep, use_idx, insn.reg, depth + 1, true)
    when :CLASS, :MODULE, :SCLASS, :TCLASS
      # A class or module operand is type-checked, never sent a method: a stale temporary read here is not a send.
      true
    when :GETMCNST
      # OP_GETMCNST reads only regs[a], the scope of `Scope::NAME`, and type-checks it (a non-module raises TypeError):
      # it is never sent a method. Any other register the read set reports here is not read by the VM.
      true
    when :EQ
      # OP_EQ compares regs[a] with regs[a+1]: identity and numeric fast paths, else regs[a]'s `==` with regs[a+1]
      # as its argument (vm.c). As the receiver the value's own class answers; as the argument, the receiver is
      # unknown, so every `==` must be core.
      use_reg == insn.reg ? receiver_read_native?('==', container) : native_only?('==')
    when :ADD
      # `a + b` of a literal Array: Array#+ builds a new Array holding the same elements, which is followed in turn.
      return false unless container && literal_array_add?(irep, use_idx, insn, use_reg)

      installer_symbol_value_safe?(irep, use_idx, insn.reg, depth + 1, true)
    when :SETCONST
      return false unless insn.regs&.first == use_reg

      installer_constant_reads_safe?(insn.const_name.to_s, depth + 1, container)
    when *BytecodeIR::Ops::SEND.to_a
      # OP_SSEND / OP_SSEND0 / OP_SSENDB start with regs[a] = regs[0]: the stale value in regs[a] is overwritten by self,
      # never read (vm.c). Only an argument register of a self send is a real read.
      return true if BytecodeIR::Ops::SELF_SEND.include?(insn.op) && use_reg == insn.reg

      receiver = use_reg == insn.reg
      # `freeze` returns its receiver (the same register, now frozen): the value continues on that register.
      if insn.sym == 'freeze' && receiver && receiver_read_native?('freeze', container)
        return installer_symbol_value_safe?(irep, use_idx, insn.reg, depth + 1, container)
      end
      # `container.map(&:to_s)`: Array#map runs Symbol#to_s on each element; the result is followed as a container.
      if insn.sym == 'map' && receiver && container && symbol_to_s_block?(irep, use_idx, insn)
        return installer_symbol_value_safe?(irep, use_idx, insn.reg, depth + 1, true)
      end
      return false unless INSTALLER_SAFE_READS.include?(insn.sym)

      # As the receiver, the value's own class answers (a literal Array/Hash, or a Symbol). As an argument, the receiver
      # is unknown, so every definer of the name must be native.
      receiver ? receiver_read_native?(insn.sym, container) : native_only?(insn.sym)
    else
      false
    end
  end

  # `a + b` where the followed container is one operand and the other is a literal Array (or the followed value itself):
  # the receiver is an Array, so Array#+ answers unless a Ruby `+` sits on Array's chain.
  def literal_array_add?(irep, use_idx, insn, use_reg)
    return false unless receiver_read_native?('+', true)
    return true if use_reg == insn.reg

    _idx, receiver = sole_definition(irep, use_idx, insn.reg)
    use_reg == insn.reg + 1 && receiver&.op == :ARRAY
  end

  # A `map` whose block is `&:to_s` (the block register holds the Symbol :to_s) and every method it runs is core.
  def symbol_to_s_block?(irep, use_idx, insn)
    return false unless insn.op == :SENDB && insn.argc.to_i.zero? && insn.reg
    return false unless receiver_read_native?('map', true) && receiver_read_native?('to_s', false) &&
                        receiver_read_native?('to_proc', false)

    _idx, block = sole_definition(irep, use_idx, insn.reg + 1)
    loaded_symbol_name(irep, block) == 'to_s' if block && %i[LOADSYM SYMBOL].include?(block.op)
  end

  # The classes that answer a send to a literal container, or to a Symbol, before any other class could.
  CONTAINER_READ_OWNERS = %w[Array Hash Object Kernel BasicObject Enumerable].freeze
  SYMBOL_READ_OWNERS = %w[Symbol Object Kernel BasicObject Comparable].freeze

  # +name+ sent to the value runs a core method unless a Ruby definer sits on the value's class or one of its ancestors;
  # definers on other classes (Irep#freeze, StrictKeySet#include?) cannot answer it.
  def receiver_read_native?(name, container)
    owners = container ? CONTAINER_READ_OWNERS : SYMBOL_READ_OWNERS
    @registry.fetch(name, []).all? { |d| d.owner == '<native>' || !owners.include?(d.owner) }
  end

  # Every definer of +name+ is native (a Ruby method of that name could send what it is given).
  def native_only?(name)
    @registry.fetch(name, []).all? { |d| d.owner == '<native>' }
  end

  # Every read of constant +name+ in the program (GETCONST and scoped GETMCNST) carries a safe value.
  def installer_constant_reads_safe?(name, depth, container)
    @ireps.each_value do |irep|
      source = BytecodeIR.for(irep)
      (0...source.size).each do |i|
        read = source.source_at(i)
        next unless (read.op == :GETCONST && read.const_name.to_s == name) || (read.op == :GETMCNST && read.mcnst_name.to_s == name)
        return false unless installer_symbol_value_safe?(irep, i, read.reg, depth, container)
      end
    end
    true
  end

  # A scoped read whose scope is a named module (`RBS::AST::Declarations::Class`) names that module's constant, never the
  # core class of the same spelling, so it is not a class factory. An unknown scope or Object's own keeps the check.
  def scoped_constant_of_other_scope?(irep, idx, insn)
    return false unless insn.op == :GETMCNST

    scope = irep.constant_path(idx - 1, insn.reg)
    !scope.nil? && scope.root == :const && !scope.name.nil? && scope.name.delete_prefix('::') != 'Object'
  end

  # The module argument of an include/prepend/extend send (one plain argument), as a constant reference, or nil.
  def mixin_module_ref(irep, idx, insn)
    return nil unless %w[include prepend extend].include?(insn.sym) && insn.reg && insn.plain_fixed_argc? && insn.argc == 1

    resolve_mixin_ref(irep, idx, insn.reg + 1) || straight_line_constant_ref(irep, idx, insn.reg + 1)
  end

  # The argument of a send that directly follows its own `GETCONST` (no other path reaches the send, handlers included):
  # the register holds that constant, whatever the reaching-definition analysis of the method could not prove (an
  # `ensure` clause makes it give up). Nil otherwise.
  def straight_line_constant_ref(irep, idx, reg)
    program = BytecodeIR.for(irep)
    return nil unless idx >= 1 && program.linear_corridor?(idx - 1, idx, include_handlers: true)

    writer = program.source_at(idx - 1)
    return nil unless writer.op == :GETCONST && writer.reg == reg && writer.const_name

    { name: writer.const_name.to_s, qualified: false, absolute: false }
  end

  # A mixin the analysis cannot place (a singleton class, `extend` in a class body, a mixin made in a method) adds the
  # module's methods to some receiver. Those names become dynamic: every call site of one keeps dispatching by name, and
  # mruby's own lookup decides at run time (resolve_deferred_mixin_modules). Returns false (the caller refuses the closed
  # world) when the module argument is not a constant.
  def defer_mixin_module?(irep, idx, insn)
    ref = mixin_module_ref(irep, idx, insn)
    return false unless ref && ref[:name]

    @deferred_mixin_modules << ref[:name]
    true
  end

  # Every declared name ending in the referenced name is a candidate (a superset, so sound: the scope it was spelled in is
  # not tracked here). A candidate-free reference names a module the program does not declare (a gem's), so the closed
  # world is refused. The names are the methods of those modules as registered.
  def resolve_deferred_mixin_modules
    declared = @module_names | @class_decls.keys.to_set
    @deferred_mixin_modules.each do |name|
      bare = name.delete_prefix('::')
      modules = declared.select { |decl| decl == bare || decl.end_with?("::#{bare}") }.to_set
      if modules.empty?
        global!(:dynamic_mixin)
        next
      end
      @registry.each do |method_name, defs|
        note_unknown_def(method_name, nil) if defs.any? { |d| modules.include?(d.owner) }
      end
    end
  end

  # A file-scope `Const.include(Mod)` / `Const.prepend(Mod)` in the root body (explicit_mixin_refs): the registry records it
  # as a mixin of the owner when both constants resolve to declared names, so no ancestor is unknown. Any other explicit
  # receiver, or a constant that does not resolve, stays dynamic.
  def explicit_mixin_accepted?(irep, idx, insn)
    return false unless @root_label && irep.label == @root_label

    refs = explicit_mixin_refs(irep, idx, insn)
    return false unless refs

    declared = @module_names | @class_decls.keys.to_set
    owner = mixin_declared_name(refs[0], nil, declared)
    mod = mixin_declared_name(refs[1], nil, declared)
    !owner.nil? && !mod.nil? && @module_names.include?(mod)
  end

  def scan_send(irep, idx, insn)
    name = insn.sym
    @clone_sent = true if name == 'clone'
    scan_freeze_send(irep, idx, insn) if name == 'freeze'
    scan_visibility_send(irep, idx, insn) if VISIBILITY_SENDS.include?(name)
    scan_removal_send(irep, idx, insn) if REMOVER_SENDS.include?(name) || NAME_FORWARDERS.include?(name)
    if CONST_REBINDERS.include?(name)
      @dynamic_constant_mutation = true
      global!(:dynamic_install)
    end
    if MIXIN_SENDS.include?(name)
      # Class-body include/prepend is separately represented by build_registry
      # (or marked unknown_mixins); runtime mixin changes are not.
      class_body_mixin = %w[include prepend].include?(name) && @walked.include?(irep.label) &&
                         BytecodeIR::Ops::SELF_SEND.include?(insn.op)
      unless class_body_mixin || explicit_mixin_accepted?(irep, idx, insn) || defer_mixin_module?(irep, idx, insn)
        global!(:dynamic_mixin)
      end

      return
    end
    return unless INSTALLER_SENDS.include?(name)
    # LOOP_INSTALLERS: the registry holds every name this send installs.
    return if loop_installer_sites.include?([irep.label, idx])

    n = insn.argc
    sets = n && argument_name_sets(irep, idx, insn, n)
    syms = n ? sets&.flatten : packed_syms(irep, idx, insn)
    return global!(:dynamic_install) unless syms

    # build_registry only attributes a self-implicit attr_* in a class body.
    self_send = BytecodeIR::Ops::SELF_SEND.include?(insn.op)
    trusted = name.start_with?('attr') && @walked.include?(irep.label) && self_send
    return if trusted

    scoped_label = self_send ? irep.label : nil
    syms.each do |s|
      note_unknown_def(s, scoped_label)
      note_unknown_def("#{s}=", scoped_label)
    end
  end

  # +label+ is the irep a definer sits in when its target is that irep's own cref (a `def`/`alias_method` with
  # an implicit receiver), else nil: only the former can be proven to land on a class object (see
  # instance_unknown_def?).
  def note_unknown_def(name, label)
    @unknown_defs << name
    @unknown_def_sources[name] << label
  end

  # A `freeze` send in the closed world's own Ruby (user_objects_unfrozen?): harmless only when its
  # receiver is a builtin literal, or a class/module constant (freezing the class object leaves its
  # instances alone), on every path (dominance, not the nearest writer). The constant is judged
  # after the scan, when every SETCONST is counted.
  def scan_freeze_send(irep, idx, insn)
    return if @freeze_possible
    return if CoreDefs.core_source?(irep.file) # mruby's own Ruby: builtin values only

    constant = nil
    harmless = BytecodeIR::Ops::SEND_PREFIX_OPS.include?(insn.op) && insn.argc.to_i.zero? &&
               irep.walk_dominating_writers(idx - 1, insn.reg, use: idx, follow_moves: true) do |writer, index|
                 case writer.op
                 when *FREEZE_LITERAL_WRITERS then true
                 when :GETCONST then (constant = writer.const_name) && true
                 when :GETMCNST then (constant = writer.mcnst_name) && true
                 else fresh_builtin_result?(irep, index, writer)
                 end
               end
    return @freeze_possible = true unless harmless == true

    @frozen_constants << constant if constant
  end

  # FRESH_BUILTIN_FREEZE: `(0..n).map { }.freeze`, `(%w[a] + [b]).freeze`. A core iterator of FRESH_BUILTIN_SENDS or
  # an op of FRESH_BUILTIN_OPS on a builtin literal (or on such a result) leaves a builtin value, never a user object,
  # as long as only mruby's own code defines the name. That is judged after the scan (fresh_builtin_names_core?), when every definer is known.
  # BC2CPP_FRESH_FREEZE=0 refuses it, for comparison.
  def fresh_builtin_result?(irep, index, writer, depth = 0)
    return false if ENV['BC2CPP_FRESH_FREEZE'] == '0' || depth >= 4

    name = fresh_builtin_name(writer)
    return false if name == false

    literal = irep.walk_dominating_writers(index - 1, writer.reg, use: index, follow_moves: true) do |receiver, at|
      next false if writer.op == :ADD && !FRESH_ADD_RECEIVERS.include?(receiver.op)

      FREEZE_LITERAL_WRITERS.include?(receiver.op) || (writer.op == :ARYCAT && receiver.op == :LOADNIL) ||
        fresh_builtin_result?(irep, at, receiver, depth + 1)
    end
    return false unless literal == true

    @fresh_freeze_names << name if name
    true
  end

  # The method name a FRESH_BUILTIN_FREEZE writer dispatches (nil: none, it is an Array op), or false when the writer
  # is not one.
  def fresh_builtin_name(writer)
    if BytecodeIR::Ops::SEND_PREFIX_OPS.include?(writer.op)
      FRESH_BUILTIN_SENDS.include?(writer.sym.to_s) && writer.sym.to_s
    elsif FRESH_BUILTIN_OPS.key?(writer.op) && ENV['BC2CPP_FRESH_FREEZE_OPS'] != '0'
      FRESH_BUILTIN_OPS[writer.op]
    else
      false
    end
  end

  # Every definer of a FRESH_BUILTIN_FREEZE name is mruby's own: core Ruby or a core native.
  def fresh_builtin_names_core?
    @fresh_freeze_names.all? do |name|
      !@unknown_defs.include?(name) &&
        @registry.fetch(name, []).all? { |d| d.irep.nil? || CoreDefs.core_source?(@ireps[d.irep]&.file) } &&
        outside_ruby_paths_defining(name).all? { |path| CoreDefs.core_source?(path) } &&
        (@outside_name_paths[name] || []).all? { |path| path.match?(NATIVE_CORE) }
    end
  end

  # `private :a, :b` / `private def a`: the names it hides. Any other argument
  # shape could name anything.
  def scan_visibility_send(irep, idx, insn)
    n = BytecodeIR::Ops::ZERO_SUFFIX_OPS.include?(insn.op) ? 0 : insn.argc
    return if n&.zero?

    sets = n && argument_name_sets(irep, idx, insn, n, definitions: true)
    syms = n ? sets&.flatten : packed_syms(irep, idx, insn)
    return @dynamic_visibility = true unless syms

    @visibility_names.merge(syms)
    @visibility_unresolved.merge(syms) unless same_body_visibility_send?(irep, idx, insn, syms)
  end

  # VISIBILITY_SAME_BODY: `private :a` / `public :a` (implicit self) in the class body that defined `a` earlier, in
  # one class only: build_registry sets that definition's visibility from it, so the registry's answer is mruby's.
  # A send in another body (an inherited method gets a copy there), or a body whose
  # `a` the registry places on several owners, is not. BC2CPP_VISIBILITY_SAME_BODY=0 counts every send.
  def same_body_visibility_send?(irep, idx, insn, syms)
    return false if ENV['BC2CPP_VISIBILITY_SAME_BODY'] == '0'
    return false unless %w[private public protected].include?(insn.sym) && %i[SSEND SSEND0].include?(insn.op)

    syms.all? do |sym|
      body = nil
      irep.each_with_op(:TDEF, :DEF) do |d, i|
        next unless i < idx && d.sym == sym

        body = d.op == :TDEF ? irep.reps[d.block_index] : def_method_body(irep, i, d)
      end
      # Irep#reps holds the child labels.
      label = body.respond_to?(:label) ? body.label : body
      label && method_body_owners.fetch(label, []).size == 1
    end
  end

  # Every reaching argument value must have a finite immutable name set. A String
  # remains usable only at its adjacent load: register flow does not prove aliases
  # cannot mutate it. Definition ops return their Symbol name in the receiver register.
  def argument_name_sets(irep, idx, insn, n, definitions: false, strings: false)
    program = BytecodeIR.for(irep)
    (1..n).map do |position|
      reg = (insn.reg + position)
      defs = BytecodeIR.reaching_definitions(irep, idx, reg, through_handlers: true, origin_transfers: true, shared: true)
      return nil if defs.nil? || defs.empty? || defs.any?(&:entry?)

      names = defs.map do |definition|
        writer = program.source_at(definition.index)
        case writer.op
        when :LOADSYM then writer.sym_token
        when :DEF, :TDEF, :SDEF then writer.sym_token if definitions
        when :STRING
          next unless strings && definition.index == idx - n + position - 1
          next unless program.linear_corridor?(definition.index, idx, include_handlers: true)
          gap = (definition.index + 1...idx)
          next unless gap.all? { |k| %i[LOADSYM STRING MOVE].include?(program.source_at(k).op) }

          irep.pool[writer.pool_index.to_i]
        end
      end
      return nil unless names.all?(String)

      names.uniq
    end
  end

  # REMOVED_NAMES: preserve each argument's alternatives separately: only the first
  # argument of a forwarding send selects the operation, while the rest name methods.
  def scan_removal_send(irep, idx, insn)
    sets = insn.argc && argument_name_sets(irep, idx, insn, insn.argc, strings: true)
    # A forwarder whose literal selector names an ordinary method (`send(:pl_use, PlOther.new)`) calls that method
    # and removes nothing, whatever its other arguments are; only the selector decides what it does.
    selector = insn.argc&.positive? && argument_name_sets(irep, idx, insn, 1, strings: true)
    if REMOVER_SENDS.include?(insn.sym)
      return @dynamic_removal = true unless sets

      @removed_names.merge(sets.flatten)
    elsif !sets && selector && selector.first.all? { |name| !NAME_FORWARDERS.include?(name) && !REMOVER_SENDS.include?(name) }
      nil
    elsif !sets || sets.first&.any? { |name| NAME_FORWARDERS.include?(name) }
      @dynamic_removal = true
    elsif sets.first&.any? { |name| REMOVER_SENDS.include?(name) }
      @removed_names.merge(sets.drop(1).flatten)
    end
  end

  # The name a probe sends about is its first argument. A single proven Symbol there is probed; any other
  # name (a join, a computed String, no argument) makes every miss unprovable, see probed_name?.
  def scan_probe_send(irep, idx, insn)
    names = insn.argc&.positive? ? argument_name_sets(irep, idx, insn, 1)&.first : nil
    return @dynamic_probe = true unless names&.size == 1

    @probed_names.merge(names)
  end

  # 15+ arguments arrive packed: `ARRAY Ra k` builds the array in Ra from R[a]..R[a+k-1] (OP_ARRAY, vm.c), and the
  # `n=*` send reads it from R[insn.reg + 1]. The array is proven by flow: its only reaching definition is that
  # ARRAY, its only read is the splat send (FactoryFlow.uses follows MOVEs, so any other read could mutate or
  # escape it), and each element has exactly one reaching LOADSYM. Anything else is nil (dynamic).
  def packed_syms(irep, idx, insn)
    return nil unless insn.pure_splat?

    program = BytecodeIR.for(irep)
    source_idx, source = sole_definition(irep, idx, (insn.reg + 1))
    return nil unless source

    # `*names` with a variable: `LOADNIL Ra; ARYCAT Ra (Rb)` copies the packed array into a fresh one, so the
    # ARYCAT is the splat's only reader of the packed array.
    if source.op == :ARYCAT
      base = sole_definition(irep, source_idx, source.reg)&.last
      return nil unless base&.op == :LOADNIL

      copied = source.regs[1]
      arr_idx, arr = sole_definition(irep, source_idx, copied)
      return nil unless arr&.op == :ARRAY

      expected = [source_idx, copied]
    else
      arr_idx, arr = source_idx, source
      return nil unless arr.op == :ARRAY

      expected = [idx, (insn.reg + 1)]
    end
    uses = FactoryFlow.uses(irep, arr_idx, arr.reg)
    return nil unless uses && uses.size == 1 && uses.first == expected

    literal = program.container_literal(arr_idx)
    return nil unless literal&.kind == :array && literal.count.positive?

    (0...literal.count).map do |offset|
      _element_idx, writer = sole_definition(irep, arr_idx, (literal.base + offset))
      return nil unless writer&.op == :LOADSYM

      writer.sym_token
    end
  end

  # The one non-entry instruction that writes +reg+ at +use+, as [index, instruction], or nil.
  def sole_definition(irep, use, reg)
    defs = BytecodeIR.reaching_definitions(irep, use, reg, through_handlers: true, origin_transfers: true, shared: true)
    return nil unless defs && defs.size == 1 && !defs.first.entry?

    [defs.first.index, BytecodeIR.for(irep).source_at(defs.first.index)]
  end

  # Sends that only compare or name a factory constant (`x.is_a?(Class)`,
  # `when Struct`), never make anything with it. The constant may be the receiver or
  # an argument, so the send's name must be native-only (checked after the scan,
  # see scan_closed_world): a Ruby `==` or `is_a?` could store it.
  FACTORY_READS = %w[=== == != equal? is_a? kind_of? instance_of? name to_s inspect].freeze

  # Every use of every MOVE alias must be a native-only read or a constructor whose
  # generated members/superclasses are known. A safe first use does not license later escapes.
  def scan_factory(irep, idx, insn, const)
    uses = FactoryFlow.uses(irep, idx, insn.reg)
    return global!(:class_factory_escape) unless uses

    uses.each do |use, register|
      call = BytecodeIR.for(irep).source_at(use)
      return global!(:class_factory_escape) unless SEND_OPS.include?(call.op)

      if FACTORY_READS.include?(call.sym)
        @factory_read_names << call.sym
        next
      end
      unless call.sym == 'new' && BytecodeIR::Ops::RECEIVER_SEND.include?(call.op) && call.reg == register
        return global!(:class_factory_escape)
      end
      return global!(:class_factory_escape) if const == 'Data'

      argc = BytecodeIR::Ops::ZERO_ARG_SEND.include?(call.op) ? 0 : (call.argc if call.plain_fixed_argc?)
      case const
      when 'Struct'
        @struct_factory_used = true
        if struct_keyword_init?(call) && call.positional_splat?
          @deferred_struct_splats << [irep, use, call]
          next
        end
        argc = call.argc if struct_keyword_init?(call)
        return global!(:class_factory_escape) unless argc
        member_names = []
        argc.times do |argument|
          names = factory_argument_names(irep, use, call.reg.to_i + argument + 1, %i[LOADSYM])
          return global!(:class_factory_escape) unless names

          member_names.concat(names.to_a)
        end
        # STRUCT_CLASS_DECLS: whether this is a declared struct class's factory is known once every constant write is
        # counted (resolve_struct_class_members).
        @struct_factory_members << [irep, use, call, member_names]
      when 'Class'
        return global!(:class_factory_escape) unless argc && argc <= 1

        bases = argc.zero? ? Set['Object'] :
                factory_argument_names(irep, use, call.reg.to_i + 1, %i[GETCONST GETMCNST])
        return global!(:class_factory_escape) unless bases

        @dynamic_subclassed.merge(bases)
      end
    end
  end

  # `Struct.new(:a, :b, keyword_init: true)`: the constructor's keyword only changes how instances are built, so the
  # positional arguments are the members and the keyword defines nothing. Ruby rejects any other keyword for a Struct,
  # so a single keyword with no keyword splat is accepted. The members may be a splat (see resolve_struct_splats).
  def struct_keyword_init?(call)
    call.keyword_arguments? && call.keyword_argc == 1 && !call.keyword_splat?
  end

  def struct_packed_member_names(irep, use, call, arr_idx, arr)
    uses = FactoryFlow.uses(irep, arr_idx, arr.reg)
    return nil unless uses && uses.size == 1 && uses.first == [use, call.reg + 1]

    literal = BytecodeIR.for(irep).container_literal(arr_idx)
    return nil unless literal&.kind == :array && literal.count.positive?

    (0...literal.count).map do |offset|
      _element_idx, writer = sole_definition(irep, arr_idx, (literal.base + offset))
      name = case writer&.op
             when :LOADSYM then writer.sym_token
             when :SYMBOL then irep.pool&.[](writer.pool_index.to_i)
             end
      return nil unless name.is_a?(String)

      name
    end
  end

  # STRUCT_CLASS_DECLS: a Struct.new's members are unknown definers unless the call is a declared struct class's one
  # `X = Struct.new(...)`, whose members the registry lists as definers of X.
  def resolve_struct_class_members
    @struct_factory_members.each do |irep, use, call, names|
      next if struct_class_factory?(irep, use, call)

      names.each do |name|
        note_unknown_def(name, nil)
        note_unknown_def("#{name}=", nil)
      end
    end
  end

  # `Struct.new(*MEMBERS, keyword_init: true)`: mruby takes a call with more than 14 positional arguments and a keyword
  # for a block, so the members are packed in a constant array. They are the symbols of MEMBERS when the program
  # writes MEMBERS exactly once, in this body, as a literal `%i[...].freeze`. Anything else refuses the closed world.
  def resolve_struct_splats
    @deferred_struct_splats.each do |irep, use, call|
      names = struct_splat_member_names(irep, use, call)
      unless names
        global!(:class_factory_escape)
        next
      end
      names.each do |name|
        note_unknown_def(name, nil)
        note_unknown_def("#{name}=", nil)
      end
    end
  end

  def struct_splat_member_names(irep, use, call)
    program = BytecodeIR.for(irep)
    source_idx, source = sole_definition(irep, use, (call.reg + 1))
    # 15+ literal members and a keyword arrive packed: `ARRAY Ra k` read only by this send (as packed_syms reads them).
    return struct_packed_member_names(irep, use, call, source_idx, source) if source&.op == :ARRAY
    return nil unless source&.op == :ARYCAT

    base = sole_definition(irep, source_idx, source.reg)&.last
    return nil unless base&.op == :LOADNIL

    _read_idx, read = sole_definition(irep, source_idx, source.regs[1])
    return nil unless read&.op == :GETCONST

    const = read.const_name.to_s
    return nil unless @constant_write_counts[const] == 1 && !@deferred_constant_writes.include?(const)

    setters = (0...program.size).select do |i|
      writer = program.source_at(i)
      writer.op == :SETCONST && writer.const_name.to_s == const
    end
    return nil unless setters.size == 1

    value_idx, value = sole_definition(irep, setters.first, program.source_at(setters.first).regs.first)
    return nil unless value&.op == :SEND0 && value.sym == 'freeze'

    arr_idx, arr = sole_definition(irep, value_idx, value.reg)
    return nil unless arr&.op == :ARRAY

    literal = program.container_literal(arr_idx)
    return nil unless literal&.kind == :array && literal.count.positive?

    (0...literal.count).map do |offset|
      _element_idx, writer = sole_definition(irep, arr_idx, (literal.base + offset))
      # A %i[] element is a SYMBOL (its name is in the pool); a LOADSYM names it directly.
      name = case writer&.op
             when :LOADSYM then writer.sym_token
             when :SYMBOL then irep.pool&.[](writer.pool_index.to_i)
             end
      return nil unless name.is_a?(String)

      name
    end
  end

  def factory_argument_names(irep, index, register, ops)
    names = Set.new
    known = every_definition?(irep, index, register) do |writer, definition|
      next false unless writer.reg == definition.reg && ops.include?(writer.op)

      name = writer.op == :LOADSYM ? writer.sym : writer.const_name
      name && names.add(name)
    end
    names if known
  end

  # -- the class hierarchy -----------------------------------------------------

  def simple(name)
    (@simple_names ||= {})[name] ||= name.split('::').last
  end

  # A class whose instances this analysis can enumerate: declared by a CLASS
  # op, not also created or subclassed outside, never rebound or subclassed
  # dynamically, and named by a plain constant path.
  def opaque?(owner)
    return true if owner.include?('.') || owner.include?('<') || BOOT_CLASSES.include?(owner)
    return true unless @declared_classes.include?(owner)
    return true if (rebound?(owner) && !struct_class?(owner)) || @dynamic_subclassed.include?(simple(owner))

    # Touch scans are complete after construction; declaration and rebinding guards stay live.
    return @opaque_touches.fetch(owner) { @opaque_touches[owner] = outside_class_touch?(owner) } if @opaque_touches

    outside_class_touch?(owner)
  end

  # QUALIFIED_REBINDS: may the constant naming +owner+ be bound to another value? A write the registry qualified
  # rebinds only its own path; a write it did not (in a method body, `Outer::X =`, or one it does not record) rebinds
  # every constant of that bare name.
  def rebound?(owner)
    @rebound_bare.include?(simple(owner)) || @rebound_qualified[owner].positive?
  end

  # STRUCT_CLASS_DECLS: X is a struct class whose one constant write is the `X = Struct.new(...)` the registry saw. That
  # write is a declaration, not a rebinding: a second write of X, or a write of its bare name the registry did not
  # qualify, leaves X rebound.
  def struct_class?(owner)
    return false unless @struct_classes.include?(owner)

    @rebound_qualified[owner] == 1 && !@rebound_bare.include?(simple(owner))
  end

  # STRUCT_CLASS_DECLS: the Struct.new call at +use+ is the one `X = Struct.new(...)` of a declared struct class, so the
  # registry holds its members as definers of X.
  def struct_class_factory?(irep, use, call)
    return false unless @walked.include?(irep.label)

    store = BytecodeIR.for(irep).source_at(use + 1)
    return false unless store&.op == :SETCONST && store.reg_operand == call.reg

    owner = @constant_write_sites[[irep.label, use + 1]]
    !owner.nil? && struct_class?(owner)
  end

  def outside_class_touch?(owner)
    # Outside code reaches a class only through its path, so a file that could
    # create, reopen or subclass it names both the root and the last segment.
    # A native definition of a class the closed world declares is its source.
    touches_for([owner.split('::').first, simple(owner)].uniq, source: false).any?
  end

  # Touches whose names cover a class path `[root, simple]`; `source: true` adds
  # the files that natively define it (owners the closed world does not declare).
  def touches_for(spelled, source:)
    @touches.select do |t|
      (source || !t.source) && t.names.include?(spelled.last) &&
        (t.names.include?(spelled.first) || t.names.include?(TouchScan::WILD))
    end
  end

  Touch = Struct.new(:path, :names, :why, :note, :source)

  def record_ruby_touches(path, text)
    scan = TouchScan.ruby(text)
    if scan.legacy
      names = text.scan(/\b[A-Z]\w*/).to_set
      @touches << Touch.new(path, names, {}, "legacy (#{scan.legacy}): spells #{names.size} constants", false)
    else
      @touches << Touch.new(path, scan.hard, scan.evidence, '', false) unless scan.hard.empty?
    end
  end

  # A native file touches what it subclasses, mixes into or rebinds by
  # name. Any construct TouchScan cannot classify keeps the old rule, gated as
  # before on the file defining classes or constants at all.
  def record_native_touches(path, facts, defines_class, legacy_names)
    scan = TouchScan.native_classify(facts, @class_decls.keys.map { |k| simple(k) }.uniq)
    if scan.legacy && defines_class
      names = legacy_names.to_set
      @touches << Touch.new(path, names, {}, "legacy (#{scan.reasons.uniq.first(3).join('; ')}): spells #{names.size} constants", false)
    end
    @touches << Touch.new(path, scan.hard, scan.evidence, '', false) unless scan.hard.empty?
    @touches << Touch.new(path, scan.origin, scan.evidence, '', true) unless scan.origin.empty?
  end

  def build_hierarchy
    # A compact definition whose outer constant registry.rb resolved
    # (outer_qualified) is named correctly and needs no refusal.
    global!(:qualified_class_definition) if @class_decls.values.flatten.any? { |d| !d[:outer_nil] && !d[:outer_qualified] }
    by_simple = Hash.new { |h, k| h[k] = [] }
    @class_decls.each_key { |c| by_simple[simple(c)] << c }
    @by_simple = by_simple
    @children = Hash.new { |h, k| h[k] = Set.new }
    # Program classes whose superclass the program does not declare (`class Child < Array`): the superclass is named
    # as written, and known_subclasses reads them for an undeclared core root.
    @undeclared_children = Hash.new { |h, k| h[k] = Set.new }
    # A superclass the walk could not resolve could be any class.
    @wild = Set.new
    @class_decls.each do |klass, decls|
      decls.each do |d|
        case d[:super]
        when nil then @wild << klass unless d[:fresh_struct_super]
        when String
          parents = superclass_candidates(d[:super], by_simple)
          if parents.empty?
            @undeclared_children[d[:super]] << klass unless d[:super] == klass
          else
            parents.each { |parent| @children[parent] << klass unless parent == klass }
          end
        end
      end
    end
  end

  # The declared classes a superclass expression +sup+ may name. Constant lookup is lexical then by ancestry, so any
  # class of that simple name may be the one meant; a written path (`RPG2k::Scene::Battle`) narrows that to the classes
  # whose path ends with it, unless one of its segments is rebound or no declared class ends with it.
  def superclass_candidates(sup, by_simple)
    all = by_simple[simple(sup)]
    path = sup.delete_prefix('::')
    segments = path.split('::')
    return all if segments.size < 2 || segments.any? { |seg| @rebound.include?(seg) || @outside_constant_writes.include?(seg) }

    written = all.select { |c| c == path || c.end_with?("::#{path}") }
    written.empty? ? all : written
  end

  def descendants(klass)
    @desc_memo[klass] ||= begin
      seen = Set.new
      work = [klass]
      until work.empty?
        @children[work.pop].each { |c| work << c if seen.add?(c) }
      end
      seen.delete(klass)
      seen | (@wild - [klass])
    end
  end

  # Every class whose instances answer `name`, or the reason that is unknown.
  # SELF_INSTANCE_RECEIVER: `self` in an instance method of a declared class is an
  # instance of it or a descendant, never a class or module object, so a method
  # defined on a `.singleton` (a `def self.x` or `class << self` one) cannot answer
  # it. False when the class could itself be a Module/Class subclass (whose
  # instances are class objects), when its superclass is unresolved, or for
  # modules (their `self` may be the module object or an includer).
  def instance_self?(self_owner)
    return false unless self_owner.is_a?(String) && class_declared?(self_owner)

    !derives_from_module_or_class?(self_owner, Set.new)
  end

  def derives_from_module_or_class?(klass, seen)
    return false unless seen.add?(klass)

    Array(@class_decls[klass]).any? do |d|
      sup = d[:super]
      next true if sup.nil? || %w[Module Class].include?(simple(sup.to_s))

      sup.is_a?(String) && @by_simple[simple(sup)].any? { |parent| derives_from_module_or_class?(parent, seen) }
    end
  end

  # SINGLETON_ARMS: the modules (and, CLASS_OBJECT_ARMS, the class objects) whose `.singleton` definition of `name` a
  # guard chain can answer with an identity arm, or nil when some singleton definer cannot be armed. A module object is
  # reached only by its own constant: no subclasses (module_object_self? also bars a class and any
  # `clone`, the one way to copy singleton methods). The caller proves the singleton chain has no mixin.
  public def singleton_arm_modules(name)
    return nil if @global_refusal

    owners = @registry.fetch(name, []).map(&:owner).select { |o| o.end_with?('.singleton') }.uniq
    return nil if owners.empty?

    arms = Set.new
    owners.each do |owner|
      base = owner.delete_suffix('.singleton')
      if module_object_self?(base)
        arms << base
      elsif (objects = class_object_arms(base))
        arms.merge(objects)
      else
        return nil
      end
    end
    arms.to_a
  end

  # CLASS_OBJECT_ARMS: a class's `def self.x` answers for that class object and for every subclass's class object
  # (singleton methods are inherited by subclasses), so the arm set is the class and its known subclasses, each a
  # declared, non-opaque class whose constant names one object. nil when the hierarchy below it is not closed.
  def class_object_arms(klass)
    return nil if @global_refusal || @clone_sent || !@declared_classes.include?(klass) || @module_names.include?(klass)

    subclasses = known_subclasses(klass)
    return nil unless subclasses
    return nil unless subclasses.all? { |c| @declared_classes.include?(c) && !opaque?(c) && stable_constant_identity?(c) }

    subclasses
  end

  def merge_mixins(included, prepended)
    merged = Hash.new { |h, k| h[k] = Set.new }
    [included, prepended].each { |table| table.each { |owner, mods| merged[owner].merge(Array(mods)) } }
    merged
  end

  # MODULE_DEFINER_INCLUDERS: the classes whose instances reach +mod+'s instance methods, through a class-body
  # include or prepend of +mod+ or of a module that includes it, or nil when that is not known: +mod+ is not a
  # declared module, an includer may be one the registry does not see (known_includer_candidates), an outside
  # source or a dynamic mixin may name it, some mixin did not resolve, or a root class (Object, Kernel, BasicObject)
  # takes it, which reaches every object. A module nothing includes answers no instance: its instance methods (the
  # private copies `module_function` makes) bind no receiver, and its `.singleton` definitions are judged on their own.
  public def module_definer_includers(mod)
    return nil unless @mixins && @unknown_mixins && @unknown_mixins.empty? && @module_names.include?(mod)

    @module_includer_memo ||= {}
    return @module_includer_memo[mod] if @module_includer_memo.key?(mod)

    @module_includer_memo[mod] = module_includers_uncached(mod)
  end

  def module_includers_uncached(mod)
    return nil if known_includer_candidates(mod).nil? || outside_class_touch?(mod)

    classes = Set.new
    seen = Set[mod]
    work = [mod]
    until work.empty?
      target = work.pop
      @mixins.each do |owner, mods|
        next unless mods.include?(target)
        return nil if BOOT_CLASSES.include?(owner) || owner.include?('.') || owner.include?('<')

        if @module_names.include?(owner)
          return nil if outside_class_touch?(owner)

          work << owner if seen.add?(owner)
        else
          classes << owner
        end
      end
    end
    classes
  end

  def required_classes(name, instance_self = false, singleton_arms = nil)
    @memo[[name, instance_self, singleton_arms]] ||= begin
      defs = @registry.fetch(name, []).reject { |d| d.owner == '<native>' }
      required = Set.new
      reason = nil
      defs.each do |d|
        if d.owner.end_with?('.singleton')
          next if instance_self || singleton_arms&.include?(d.owner.delete_suffix('.singleton'))

          break reason = :singleton_definer
        end
        if (includers = module_definer_includers(d.owner))
          # MODULE_DEFINER_INCLUDERS: a module's method is reached through the classes that include or prepend it.
          blocked = includers.find { |c| opaque?(c) || descendants(c).any? { |sub| opaque?(sub) } }
          break reason = :opaque_definer if blocked

          includers.each { |c| required << c; required.merge(descendants(c)) }
          next
        end
        break reason = :opaque_definer if opaque?(d.owner)

        required << d.owner
        sub = descendants(d.owner)
        break reason = :opaque_subclass if sub.any? { |c| opaque?(c) }

        required.merge(sub)
      end
      [reason, required]
    end
  end

  # -- method_missing ----------------------------------------------------------

  def build_method_missing
    %w[method_missing respond_to_missing?].each do |hook|
      global!(:"#{hook.delete('?')}_hook") if @unknown_defs.include?(hook)
    end
    @registry.fetch('respond_to_missing?', []).each do |d|
      global!(:respond_to_missing_hook) if GLOBAL_HOOK_OWNERS.include?(d.owner)
    end
    @mm_classes = Set.new
    @registry.fetch('method_missing', []).each do |d|
      next if d.owner == '<native>'

      if GLOBAL_HOOK_OWNERS.include?(d.owner) || opaque?(d.owner)
        global!(:method_missing_hook)
      else
        @mm_classes << d.owner
        @mm_classes.merge(descendants(d.owner))
      end
    end
  end

  # Can the fallback's receiver be an instance of a method_missing class? Only
  # `self` is known: every entry into a compiled method passes a kind_of? its
  # owner (dispatch, a guarded or lexical-self direct call, super).
  # METHOD_MISSING_ARMS: the classes whose instances reach a Ruby method_missing (with the subclasses that inherit it),
  # when each is a declared, non-opaque class of stable constant identity and none is open below, so an exact-class arm
  # per class (bc2cpp_class_is, which looks through an object's singleton class) catches every such receiver. nil
  # when there are none or that is not so.
  public def method_missing_arm_classes
    return nil if @global_refusal || @mm_classes.empty? || !@wild.empty?
    return nil unless @mm_classes.all? { |c| @declared_classes.include?(c) && !opaque?(c) && stable_constant_identity?(c) }
    return nil unless @mm_classes.all? { |c| (subs = known_subclasses(c)) && subs.to_set.subset?(@mm_classes) }

    @mm_classes.to_a.sort
  end

  def method_missing_free?(self_owner, instances = nil)
    return true if @mm_classes.empty?
    # A proven class set: a class inherits method_missing exactly when @mm_classes holds it.
    return instances.none? { |c| @mm_classes.include?(c) } if instances && !self_owner
    return false unless self_owner
    # A class or module object: only a hook on Class/Module/Object or a
    # singleton method_missing reaches it, and both are global refusals.
    return true if self_owner.end_with?('.singleton')
    return false if opaque?(self_owner)

    ([self_owner] + descendants(self_owner).to_a).none? { |c| @mm_classes.include?(c) }
  end
end

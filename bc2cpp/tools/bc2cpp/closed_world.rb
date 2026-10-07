# frozen_string_literal: true

require 'set'
require_relative 'compiled_gems'
require_relative 'touch_scan'
require_relative 'foreign_definers'
require_relative 'core_defs'
require_relative 'native_names'
require_relative 'native_direct'
require_relative 'dynamic_names'
require_relative 'loop_installers'

# CLOSED_WORLD (docs/adr/0210): with BC2CPP_CLOSED_WORLD=1 the only Ruby that
# can ever run is the closed world bc2cpp compiles, plus the scanned core and
# native sources of the build's own gems (compiled_gems.rb enforces that). A
# guard chain's by-name fallback can then call bc2cpp_nomethod, which raises
# exactly what mruby's dispatch raises, when this proves the receiver of that
# fallback can answer the name neither by a method nor by method_missing.
#
# Every question defaults to "refuse"; `refusal` returns the reason as a Symbol.
class ClosedWorld
  # method_missing/respond_to_missing? here reach every receiver.
  GLOBAL_HOOK_OWNERS = %w[BasicObject Object Kernel].freeze
  BOOT_CLASSES = %w[BasicObject Object Module Class Kernel].freeze
  # Sends that define methods the registry walk may not attribute to an owner.
  INSTALLER_SENDS = %w[attr_reader attr_writer attr_accessor attr define_singleton_method].freeze
  MIXIN_SENDS = %w[include prepend extend].freeze
  # Sends that change a method's visibility by name (NATIVE_EXACT_DIRECT).
  VISIBILITY_SENDS = %w[private public protected private_class_method public_class_method module_function].freeze
  # Sends that rebind a constant a guard chain resolves.
  CONST_REBINDERS = %w[const_set remove_const].freeze
  # Constants whose `.new` makes a class (or members) the registry cannot see.
  CLASS_FACTORIES = %w[Class Module Struct Data].freeze
  SEND_OPS = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].freeze
  STOP_OPS = /\A(?:JMP|RETURN|BREAK|RAISE|STOP|EXEC)/
  C_STRING = /"((?:[^"\\\n]|\\.)*)"/
  # Native code that asks Ruby to define, alias or eval by name.
  NATIVE_DYNAMIC = /"(?:define_method|define_singleton_method|attr_reader|attr_writer|attr_accessor|attr|
                     alias_method|module_eval|class_eval|instance_eval|include|extend|prepend)"|
                    MRB_SYM\((?:define_method|define_singleton_method|attr_\w+|alias_method|\w+_eval)\)|
                    \bmrb_alias_method\b/x
  # mruby core's own computed definitions only ever run for a Ruby-level
  # attr_*/define_method/alias/Struct.new, which scan_closed_world tracks.
  NATIVE_CORE = %r{/3rd/mruby/(?:src|mrbgems)/}
  RUBY_DYNAMIC = /\b(?:define_method|define_singleton_method|alias_method|attr_reader|attr_writer|attr_accessor)
                  \b[ \t]*\(?[ \t]*(?![:"'\s])/x
  RUBY_CONST_DYNAMIC = /\b(?:const_set|remove_const|autoload)\b/
  CLONE_SPELLING = /\bmrb_obj_clone\b|"clone"|MRB_SYM\(clone\)/
  # Project native code that freezes an object, or asks Ruby to (registering a method named
  # `freeze` is not one). ADR 0299.
  NATIVE_FREEZE = /\bmrb_obj_freeze\b|\bMRB_SET_FROZEN_FLAG\b|->\s*frozen\s*=(?!=)|
                   \bmrb_(?:funcall|check_funcall)\w*\s*\([^;]*(?:"freeze"|MRB_SYM\(freeze\))/x
  # What `x.freeze` leaves of a receiver that is one of these: a builtin value, never an instance of
  # a user class (ADR 0299).
  FREEZE_LITERAL_WRITERS = %w[ARRAY ARRAY2 HASH STRING STRCAT RANGE_INC RANGE_EXC].freeze
  # Kernel methods that give an arbitrary receiver a singleton class (`extend` is a global
  # refusal already, see scan_send). ADR 0280.
  SINGLETON_MAKERS = %w[singleton_class define_singleton_method instance_eval instance_exec].freeze
  # A project native that makes a singleton class by hand.
  NATIVE_SINGLETON = /\bmrb_singleton_class(?:_ptr|_clone)?\b|\bmrb_define_singleton_method(?:_id)?\b|\bmrb_obj_extend\b/
  RUBY_SINGLETON = /\b(?:#{SINGLETON_MAKERS.join('|')}|extend)\b|\bclass\s*<<|\bdef\s+(?!self\b)[a-z_]\w*\./
  # PROVEN_MISS (ADR 0275): a name passed to one of these is probed for or looked up
  # by name, so a send of it is guarded, not a bug.
  PROBE_SENDS = %w[respond_to? respond_to_missing? method_defined? public_method_defined?
                   private_method_defined? instance_method public_instance_method method public_method
                   instance_methods public_methods].freeze
  # Sends that run a block with another `self`, which breaks "self is its lexical owner".
  SELF_REBINDERS = %w[instance_eval instance_exec class_eval class_exec module_eval module_exec].freeze

  attr_reader :global_refusal, :native_paths

  def initialize(ireps:, registry:, class_decls:, walked:, native_paths:, ruby_paths:, module_names: Set.new)
    @ireps = ireps
    @module_names = module_names.to_set
    @clone_sent = false
    @registry = registry
    @class_decls = class_decls
    @walked = walked
    @global_refusal = nil
    @outside_names = Set.new
    @native_tokens = Set.new
    @ruby_tokens = {}
    @outside_ruby_names = Set.new
    @outside_name_paths = {}
    @native_code_tokens = {}
    @outside_ruby_supers = Set.new
    @native_arms_name = nil
    @ruby_paths = ruby_paths
    # Per outside file: the constants it can create, reopen, subclass or rebind
    # (TouchScan, ADR 0256).
    @touches = []
    @unknown_defs = Set.new
    @unknown_def_sources = Hash.new { |h, k| h[k] = [] }
    @visibility_names = Set.new
    @dynamic_visibility = false
    @rebound = Set.new
    @constant_write_counts = Hash.new(0)
    @class_constant_names = Set.new
    @deferred_constant_writes = Set.new
    @dynamic_constant_mutation = false
    @basic_object_referenced = false
    @singleton_makers = []
    @singleton_opens = []
    @outside_constant_writes = Set.new
    @outside_constant_write_counts = Hash.new(0)
    @dynamic_subclassed = Set.new
    @probed_names = Set.new
    @outside_def_names = Set.new
    @self_rebound = false
    @freeze_possible = false
    @frozen_constants = Set.new
    @memo = {}
    @desc_memo = {}
    @native_paths = native_paths
    scan_native(native_paths)
    scan_outside_ruby(ruby_paths)
    scan_closed_world
    build_hierarchy
    build_method_missing
    warn touch_report.join("\n") if ENV['BC2CPP_TOUCH_REPORT'] == '1'
    warn "== singleton makers ==\n#{singleton_makers.map(&:inspect).join("\n")}" if ENV['BC2CPP_SINGLETON_REPORT'] == '1'
  end

  # BC2CPP_TOUCH_REPORT=1: every class the touch analysis makes opaque, the
  # outside files that touched it and the construct that put it in the file's
  # touch set, so a touch can be traced to its source.
  def touch_report
    lines = ['== class touch report (opaque because an outside file touches it) ==']
    @class_decls.keys.sort.each do |owner|
      next if owner.include?('.') || owner.include?('<') || @rebound.include?(simple(owner))

      spelled = [owner.split('::').first, simple(owner)].uniq
      files = touches_for(spelled, source: false)
      next if files.empty?

      lines << "  #{owner}: #{files.size} file(s)"
      files.each do |t|
        evidence = spelled.filter_map { |name| t.why[name] }.uniq.first(2)
        lines << "    #{t.path}: #{evidence.empty? ? t.note : evidence.join(' | ')}"
      end
    end
    lines
  end

  # nil when a fallback for `name` on a chain listing `listed` can only raise
  # NoMethodError, else why not. `self_owner` is the enclosing method's owner
  # when the receiver is its `self`; `installed` is CodeGen#symbol_installed_names.
  # INSTANCE_RECEIVER (ADR 0302): `instances` names the exact classes the exact-class flow proves
  # the receiver holds (nil allowed), none a class or module object (CodeGen#receiver_instances).
  # CALL_FACTS (ADR 0317): `scoped` says `instances` is the whole receiver set, so only its classes need an
  # arm, and `native_free` that no native or outside definer of `name` reaches any of them.
  def refusal(name, listed, self_owner, installed, instances: nil, scoped: false, native_free: false,
              instance_scope: false, singleton_arms: nil)
    return @global_refusal if @global_refusal
    return :dynamic_install if installed.nil? || installed.include?(name)
    return :unknown_definer if instance_scope ? instance_unknown_def?(name) : @unknown_defs.include?(name)
    return :core_or_native if @outside_names.include?(name) && !native_arms_lift?(name) && !(scoped && native_free)

    reason, required = required_classes(name, instance_self?(self_owner) || !instances.nil?, singleton_arms)
    return reason if reason

    required &= instances.to_set if scoped && instances
    return :unlisted_class unless required.subset?(listed.to_set)
    return :method_missing_receiver unless method_missing_free?(self_owner, instances)

    nil
  end

  # Source files of the Ruby `method_missing` definitions (lint cross-check, ADR 0368).
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

  # ESCAPE_ANALYSIS (ADR 0316): can an installer the registry cannot enumerate (computed names) define
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

  # PROVEN_MISS (ADR 0275): a send of `name` to a receiver PROVEN to be `klass` (or, for
  # kind :lexical_self, a descendant) reaches no definition and no method_missing, so
  # it can only raise NoMethodError. `installed` is CodeGen#symbol_installed_names.
  # Every question defaults to "not a miss": the answer only ever adds a build error.
  # A module's or class object's `self` is never modelled here (instance_self?).
  def proven_miss?(name, klass, installed, kind)
    return false if @global_refusal || installed.nil? || installed.include?(name)
    return false if @unknown_defs.include?(name) || @outside_names.include?(name) ||
                    @outside_def_names.include?(name) || @probed_names.include?(name)
    return false if %w[method_missing respond_to_missing? initialize].include?(name)

    reason, required = required_classes(name, kind != :constant_object)
    return false if reason

    # A class object also answers singleton definers and Class/Module/Object/Kernel ones,
    # which required_classes refuses (`reason`) for the non-instance lookup.
    return false if kind == :lexical_self && (@self_rebound || !instance_self?(klass))
    return false if required.include?(klass) || descendants(klass).intersect?(required)

    # An exact receiver is klass itself, which no hook reaches unless klass is a listed
    # method_missing class; only `self` may also be a descendant.
    kind == :lexical_self ? method_missing_free?(klass) : !@mm_classes.include?(klass)
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

  # CONSTRUCTOR_POOLS (ADR 0313): every declared class whose last path segment is +name+, the
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

  # No const_set, remove_const or autoload anywhere and no global refusal: every constant binding is a visible
  # SETCONST/CLASS/MODULE or a scanned native/foreign definition (NUMERIC_CONSTANT_RANGES).
  def constants_static?
    !@global_refusal && !@dynamic_constant_mutation
  end

  # The constant +name+ can only name a class or module: no bytecode binds a value to it.
  def class_valued_constant?(name)
    !@global_refusal && !@dynamic_constant_mutation && class_constant?(name)
  end

  # CALL_FACTS (ADR 0317): the classes (never modules) the closed world declares.
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

  # NATIVE_CLASS_ARMS (ADR 0323): a DEF the registry does not hold, as unknown_def?, but ignoring the ones that
  # land on a class or module object (`class << Const; def x`, `alias_method` inside it). Those answer only
  # that object's own sends, so a receiver set of instance classes never reaches them.
  def instance_unknown_def?(name)
    @unknown_defs.include?(name) && @unknown_def_sources[name].any? { |label| label.nil? || !class_object_body?(label) }
  end

  # +label+ is the irep of a direct `class << <class or module constant>` body (or `class << self` in a class
  # body): its cref is that object's singleton class.
  def class_object_body?(label)
    @class_object_bodies ||= @singleton_opens.each_with_object(Set.new) do |(irep, idx, insn), out|
      next unless insn.op == 'SCLASS' && class_constant_target?(irep, idx, insn.reg.to_s)

      exec = irep.instructions[idx + 1]
      body = exec && exec.op == 'EXEC' && exec.reg.to_s == insn.reg.to_s && irep.reps[exec.block_index.to_i]
      out << body if body
    end
    @class_object_bodies.include?(label)
  end

  # NATIVE_DIRECT (ADR 0253): while a caller emits exact-class arms for every
  # native class answering `name` (CodeGen#guarded_fallback_line), the native
  # registrations no longer make the fallback's receiver unknowable.
  def with_native_arms(name)
    previous = @native_arms_name
    @native_arms_name = name
    yield
  ensure
    @native_arms_name = previous
  end

  # NATIVE_CORE_DIRECT (ADR 0257): nothing outside the registry (an outside Ruby
  # definition, alias, visibility change or prepend on `owner`, a dynamic
  # installer) can replace core `owner`'s native `name`.
  def core_native_arm_safe?(name, owner)
    return false if @global_refusal || @unknown_defs.include?(name)

    !ForeignDefiners.defines?(@ruby_paths, owner, name)
  end

  # NATIVE_EXACT_DIRECT (ADR 0281): nothing outside the registry can replace or
  # hide the RGSS native `name` on the class it is registered for: it is spelled
  # only by the RGSS sources (so no outside Ruby, no other native), no dynamic
  # definer or visibility change (private, module_function ...) names it. The
  # registry-visible definers and installers are checked by the caller.
  def native_exact_direct_name_safe?(name, path_fragment)
    return false if @global_refusal || @dynamic_visibility

    !@unknown_defs.include?(name) && !@visibility_names.include?(name) && native_only_in?(name, path_fragment)
  end

  # BLOCK_CORE_DIRECT (ADR 0270): like core_native_arm_safe?, for a method that mruby's own
  # Ruby defines on `owner`. That Ruby is what the arm calls, so only an outside definer that
  # is not core source (an engine-side reopening, a dynamic installer) can replace it.
  def core_ruby_arm_safe?(name, owner)
    return false if @global_refusal || @unknown_defs.include?(name)

    !ForeignDefiners.defines?(@ruby_paths.reject { |path| CoreDefs.core_source?(path) }, owner, name)
  end

  # Names an outside (native or foreign Ruby) source defines.
  def outside_names
    @outside_names
  end

  # KERNEL_DIRECT (ADR 0274): an implicit-self send of `name` reaches the audited
  # Kernel/BasicObject native for every receiver. That needs the same name-level proof as
  # ownerless_native_dispatch_safe? plus a receiver that includes Kernel, which only a
  # BasicObject subclass lacks (the class may be declared, created or subclassed anywhere).
  def kernel_native_dispatch_safe?(name)
    return false unless ownerless_native_dispatch_safe?(name)
    return false if @dynamic_subclassed.include?('BasicObject') || @outside_ruby_supers.include?('BasicObject')

    supers = @class_decls.values.flatten.map { |decl| decl[:super] }
    supers.all? { |sup| sup == :none || sup.is_a?(String) } && supers.none? { |sup| sup.is_a?(String) && simple(sup) == 'BasicObject' }
  end

  # BLOCK_PARAM_CALL (ADR 0274): no Ruby code in the build defines or installs `name`
  # and NilClass has no method_missing, so `nil.name` can only be a NoMethodError once the
  # native registrations are read (CodeGen#block_param_nil_call_dead?).
  def nil_call_free?(name)
    return false if @global_refusal || @unknown_defs.include?(name) || @outside_ruby_names.include?(name)

    !@mm_classes.include?('NilClass')
  end

  # NIL_RECEIVER (ADR 0296): no foreign Ruby source defines, aliases or re-scopes +name+ on any of
  # +owners+ (the classes and modules nil answers through), nothing defines it by a computed name,
  # and NilClass has no method_missing. Finer than nil_call_free?, which refuses a name any outside
  # class defines (`size`, `first` on Array).
  def nil_foreign_definition_free?(name, owners, instance_scope: false)
    return false if @global_refusal || @mm_classes.include?('NilClass')
    return false if instance_scope ? instance_unknown_def?(name) : @unknown_defs.include?(name)

    owners.none? { |owner| ForeignDefiners.defines?(@ruby_paths, owner, name) }
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

  # LCF_ROW_FLOW (ADR 0294): no outside file can reopen, subclass or rebind `owner`, so a method
  # lookup that ends at one of its registry definitions cannot be redirected by a native installer.
  def untouched_class?(owner)
    !@global_refusal && !opaque?(owner)
  end

  # Is every instance whose class descends from `owner` exactly an `owner`?
  def exact_class?(owner)
    !@global_refusal && !opaque?(owner) && descendants(owner).empty?
  end

  # CHA_SELF (ADR 0254): every class whose instances can be `owner` or descend
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

  # ADR 0259: the superclass of a declared, non-opaque class: its full path, or
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
    return false if @rebound.include?(simple(owner))

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

    !@rebound.include?(simple(owner))
  end

  # ADR 0259: `self` in a `def self.x` of a declared module is that module's
  # constant object. Only Kernel#clone copies a module's singleton methods, so
  # nothing else can run them with another self; a `clone` spelled anywhere in
  # the closed world or its outside sources refuses.
  def module_object_self?(owner)
    !@global_refusal && !@clone_sent && @module_names.include?(owner) && !@class_decls.key?(owner) &&
      stable_constant_identity?(owner)
  end

  # A value constant is single-assignment only when bytecode has one binding
  # site, no outside source writes the name, and the name is not a class
  # declaration. Dynamic constant mutation poisons all such facts.
  def single_assignment_constant?(name)
    return false if @dynamic_constant_mutation || !name.is_a?(String)

    simple = name.split('::').last
    @constant_write_counts[simple] == 1 && !@class_constant_names.include?(simple) &&
      !@deferred_constant_writes.include?(simple) && !@outside_constant_writes.include?(simple)
  end

  # INSTANCE_RECEIVER (ADR 0302): instances of the declared class are never class or module
  # objects (instance_self?, stated for `self`; an exact instance has the same property).
  def instance_class?(klass)
    instance_self?(klass)
  end

  # NATIVE_RESULT_FACTS (ADR 0302): a class a native defines (RGSS::Rect) is what its constant
  # names for the whole run. Exactly one outside write binds the simple name (the native
  # definition itself; a second define, const_set, const_remove or Ruby `Name =` makes two), no
  # bytecode SETCONST binds it, and no dynamic constant mutation exists.
  # A caller auditing mutually exclusive native definitions may supply their binding count.
  def native_class_constant_stable?(full, bindings: 1)
    return false if @global_refusal || @dynamic_constant_mutation || !full.is_a?(String)

    name = simple(full)
    @constant_write_counts[name].zero? && @outside_constant_write_counts[name] == bindings
  end

  # A literal `Klass.new` has an exact-class result only while ordinary
  # construction is visible: no unresolved installer can replace `new` or
  # `allocate`, and no outside Ruby file defines either name.
  def standard_constructor_lookup?
    !@global_refusal && %w[new allocate].none? do |name|
      @unknown_defs.include?(name) || @outside_ruby_names.include?(name)
    end
  end

  # NUMERIC_RETURN_PROOF: can a call to `name` reach only the definitions the
  # registry lists? False for a name some native or foreign source defines or
  # calls a runtime installer with, or whenever a method_missing hook exists.
  def name_fully_visible?(name)
    !@global_refusal && @mm_classes.empty? && !@unknown_defs.include?(name) && !@outside_names.include?(name)
  end

  # NATIVE_RESULT_FACTS (ADR 0302): name_fully_visible?, except that natives under
  # +path_fragment+ may define the name (the caller proves what each one returns).
  def name_visible_except_natives_in?(name, path_fragment)
    return false if @global_refusal || !@mm_classes.empty? || @unknown_defs.include?(name)

    !@outside_names.include?(name) || native_only_in?(name, path_fragment)
  end

  # Audited outside Ruby aliases may join a native return table (ADR 0334).
  def native_return_sources_visible?(name, audited_ruby_paths = [])
    return false if @global_refusal || !@mm_classes.empty? || @unknown_defs.include?(name)

    outside_ruby_paths_defining(name).all? { |path| audited_ruby_paths.include?(path) }
  end

  def outside_ruby_paths_defining(name)
    @outside_return_def_paths ||= {}
    @outside_return_def_paths[name] ||= @ruby_paths.select { |path| foreign_method_names([path]).include?(name) }
  end

  # Inherited dispatch additionally needs every possible method installer for
  # this name to be represented in the registry.
  def inherited_lookup_safe?(name, owner)
    stable_class_constant?(owner) && !@unknown_defs.include?(name) && !@outside_names.include?(name)
  end

  # ADR 0297: inherited_lookup_safe? for a name the RGSS natives register, judged on
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

  # ADR 0297: the registry's visibility for `name` is the one mruby ends up with.
  # build_registry follows `private`/`public` in the defining class body only; a
  # `private :name` that names an inherited method, or one sent dynamically, makes a
  # copy it never sees.
  def visibility_stable?(name)
    !@global_refusal && !@dynamic_visibility && !@visibility_names.include?(name)
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

  # ADR 0299: no instance of a class the closed world defines can ever be frozen, so a store into
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
                               !DynamicNames.universe(@ireps).include?('freeze')
    end
    @user_objects_unfrozen
  end

  # No Array/Hash/Range/String instance can gain a singleton class or a mixin: nothing in the
  # world (mruby's own Ruby aside, which never does it to those) names a singleton-making
  # method, opens a singleton class on a non-class object, or creates one from native code.
  def exact_instances_singleton_free?
    !@global_refusal && singleton_makers.empty?
  end

  # NUMERIC_SLOW_CLOSED `%` (ADR 0367): the constant +name+ of a core class names that class in every scope
  # core Ruby looks it up from: no bytecode binds it, no outside source rebinds it (the core's own definition is
  # the one write), and no nested class of that name is declared.
  def core_constant_plain?(name)
    return false if @global_refusal || @dynamic_constant_mutation

    @constant_write_counts[name].zero? && !@deferred_constant_writes.include?(name) &&
      @outside_constant_write_counts[name] <= 1 && @class_decls.keys.none? { |key| key != name && simple(key) == name }
  end

  # No bytecode of the world spells the constant BasicObject, the one way to an object that lacks Kernel's methods
  # without a class declaration (kernel_native_dispatch_safe? covers the declared subclasses).
  def basic_object_unreferenced?
    !@global_refusal && !@basic_object_referenced
  end

  private

  def native_arms_lift?(name)
    @native_arms_name == name && native_only_in?(name, '/mruby-rgss/src/')
  end

  def note_outside_constant_write(name)
    @outside_constant_writes << name
    @outside_constant_write_counts[name] += 1
  end

  def global!(reason)
    @global_refusal ||= reason
  end

  # -- outside the closed world ------------------------------------------------

  def scan_native(paths)
    paths.each do |path|
      # Drop comments, keeping string and char literals (a "//" inside one).
      source = File.binread(path)
      text = source.gsub(%r{"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|/\*.*?\*/|//[^\n]*}m) do |tok|
        tok.start_with?('/') ? ' ' : tok
      end
      names = Set.new
      @native_code_tokens[path] = Set.new(text.scan(/[A-Za-z_]\w*/))
      merge_native_funcall_names(text)
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
            note_outside_constant_write(constant)
          else
            @dynamic_constant_mutation = true
          end
        end
        source.scan(/\bmrb_define_global_const\s*\(\s*\w+\s*,\s*"([A-Z]\w*)"/) do |m|
          names << m.first
          note_outside_constant_write(m.first)
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
            note_outside_constant_write(constant) if constant
          end
          next
        end
        names.merge(literals)
        names.merge(tokens)
        # The name argument (after mrb and the class) must be spelled out.
        args = bc2cpp_c_call_args(body)
        [args[2], (args[3] if kind == 'alias')].compact.each do |arg|
          dynamic = true unless arg.match?(/\A\s*(?:#{C_STRING}|#{MRB_SYM_TOKEN_RE})\s*\z/o)
        end
      end
      global!(:outside_dynamic_definition) if dynamic && !path.match?(NATIVE_CORE)
      # Struct members named by C strings (mruby-marshal checks for Struct).
      dynamic ||= text.match?(/"Struct"|MRB_SYM\(Struct\)/)
      text.scan(/MRB_MT_ENTRY\s*\(\s*\w+\s*,\s*#{MRB_SYM_TOKEN_RE}/o) { |m, n| names << resolve_mrb_sym_token(m, n) }
      record_native_touches(path, text, defines_class)
      @clone_sent = true if !path.match?(NATIVE_CORE) && text.match?(CLONE_SPELLING)
      @freeze_possible = true if !path.match?(NATIVE_CORE) && text.match?(NATIVE_FREEZE)
      @singleton_makers << [path, :native] if !path.match?(NATIVE_CORE) && text.match?(NATIVE_SINGLETON)
      names.merge(text.scan(C_STRING).flatten) if dynamic
      @outside_names.merge(names)
      names.each { |n| (@outside_name_paths[n] ||= Set.new) << path }
      # Only mruby's own defaults: BasicObject#method_missing, Kernel#respond_to_missing?.
      global!(:outside_method_missing) if names.include?('method_missing') && !path.end_with?('/3rd/mruby/src/class.c')
      global!(:outside_respond_to_missing) if names.include?('respond_to_missing?') &&
                                              !path.end_with?('/3rd/mruby/src/kernel.c')
    end
  end

  # Every `def name` anywhere in the text, not only at a line start: foreign_method_names
  # misses `private def loop` (mruby's Kernel#loop), which a proven miss must not call absent.
  def broad_def_names(paths)
    Array(paths).each_with_object(Set.new) do |path, names|
      text = File.read(path, encoding: 'BINARY')
      text.scan(/(?:^|[\s;(])def\s+(?:[A-Za-z_]\w*\.)?(#{FOREIGN_METHOD_NAME_RE})/o) { |(n)| names << n }
    end
  end

  def scan_outside_ruby(paths)
    ruby_names = foreign_method_names(paths)
    global!(:outside_method_missing) if ruby_names.include?('method_missing')
    global!(:outside_respond_to_missing) if ruby_names.include?('respond_to_missing?')
    @outside_ruby_names.merge(ruby_names)
    @outside_def_names.merge(broad_def_names(paths))
    @outside_names.merge(ruby_names)
    paths.each do |path|
      text = File.read(path, encoding: 'BINARY').gsub(/^\s*#.*$/, '')
      merge_outside_tokens(path, text)
      text.scan(/^\s*class\s+[\w:]+\s*<\s*([\w:]+)/) { |(sup)| @outside_ruby_supers << simple(sup) }
      record_ruby_touches(path, text)
      @clone_sent = true if text.match?(/\bclone\b/)
      @freeze_possible = true if !CoreDefs.core_source?(path) && text.match?(/\bfreeze\b/)
      @singleton_makers << [path, :ruby] if !CoreDefs.core_source?(path) && text.match?(RUBY_SINGLETON)
      text.scan(/\b(?:[A-Z]\w*::)*([A-Z]\w*)\s*=(?!=|>)/) { |m| note_outside_constant_write(m.first) }
      global!(:outside_dynamic_definition) if text.match?(RUBY_DYNAMIC)
      @dynamic_constant_mutation = true if text.match?(RUBY_CONST_DYNAMIC)
      global!(:outside_class_factory) if text.match?(/\b(?:Class|Struct)\.new\b/)
    end
  end

  # YIELD_REACH (ADR 0283): the method names outside code can call back into Ruby by. Native code
  # names them in the funcall family (a variable name is one of the send-like natives, which the
  # yield analysis treats as seeds); foreign Ruby can call any identifier it spells.
  FUNCALL_CALL = /\bmrb_(?:funcall(?:_id|_argv|_with_block)?|check_funcall|obj_respond_to|respond_to)\s*\(([^;]*)/m
  # What the VM and mruby core invoke on user objects implicitly.
  IMPLICIT_HOOKS = %w[initialize initialize_copy respond_to_missing? const_missing inherited included extended
                      prepended method_added singleton_method_added method_removed to_s inspect to_str to_ary to_a
                      to_hash to_proc to_i to_f to_int hash eql? equal? coerce exception message backtrace each
                      call].freeze

  def merge_native_funcall_names(text)
    @native_tokens.merge(IMPLICIT_HOOKS)
    text.scan(FUNCALL_CALL) do |(body)|
      arg = bc2cpp_c_call_args(body)[2].to_s
      arg.scan(MRB_SYM_TOKEN_RE) { |m, n| @native_tokens << resolve_mrb_sym_token(m, n) }
      arg.scan(C_STRING) { |(lit)| @native_tokens << lit }
    end
  end

  def merge_outside_tokens(path, text)
    tokens = (@ruby_tokens[path] = Set.new)
    text.scan(/[A-Za-z_]\w*[?!=]?/) do |tok|
      tokens << tok
      tokens << tok.chomp('=').chomp('?').chomp('!')
    end
  end

  public

  # Does any outside (foreign Ruby) source spell the identifier +token+?
  def outside_ruby_token?(token)
    @ruby_tokens.each_value.any? { |tokens| tokens.include?(token) }
  end

  # Names outside code can call Ruby methods by: native funcall names and every identifier of the
  # foreign Ruby sources, minus the Ruby files the caller analyses itself (`except_files`).
  # DEFINE_METHOD_SITES (ADR 0288): `define_method` in a class body still reaches mruby's own
  # Module#define_method, so a recognized site installs exactly the method it spells. Anything
  # that could rename, wrap or intercept that send withdraws every site.
  def define_method_sites_trusted?
    return @define_method_trusted if defined?(@define_method_trusted)

    @define_method_trusted = !@global_refusal && !define_method_intercepted?
  end

  def outside_call_names(except_files)
    names = @native_tokens.dup
    @ruby_tokens.each { |path, toks| names.merge(toks) unless except_files.include?(path) }
    names
  end

  private

  # -- the closed world's own dynamic definitions ------------------------------

  def define_method_intercepted?
    name = 'define_method'
    return true if @registry.key?(name) || @unknown_defs.include?(name)
    return true if @outside_def_names.include?(name) || @outside_ruby_names.include?(name)
    return true if @outside_name_paths.fetch(name, []).any? { |path| !path.match?(NATIVE_CORE) }

    @ireps.each_value.any? do |irep|
      irep.instructions.any? do |insn|
        (%w[ALIAS UNDEF LOADSYM].include?(insn.op) && insn.typed.any? { |operand| operand.value.to_s == name })
      end
    end
  end


  def scan_closed_world
    registered = Set.new
    @registry.each_value { |defs| defs.each { |d| registered << d.irep if d.irep } }
    children = @ireps.values.flat_map(&:reps).compact.to_set
    @ireps.each do |label, irep|
      insns = irep.instructions
      own_source = !(children.include?(label) && CoreDefs.core_source?(irep.file))
      insns.each_with_index do |insn, idx|
        scan_singleton_maker(irep, insns, idx, insn) if own_source
        case insn.op
        when 'TDEF', 'SDEF'
          child = irep.reps[insn.block_index]
          note_unknown_def(insn.sym, insn.op == 'TDEF' ? irep.label : nil) unless registered.include?(child)
        when 'DEF'
          sym = insn.sym_token
          method = insns[0...idx].reverse.find { |i| i.op == 'METHOD' }
          child = method && irep.reps[method.block_index.to_i]
          note_unknown_def(sym, irep.label) unless child && registered.include?(child)
        when *SEND_OPS
          scan_send(irep, insns, idx, insn)
        when 'LOADSYM'
          sym = insn.sym_token
          @clone_sent = true if sym == 'clone'
          @dynamic_visibility = true if VISIBILITY_SENDS.include?(sym)
          @probed_names << sym if insns[idx + 1, 3].any? { |n| SEND_OPS.include?(n.op) && PROBE_SENDS.include?(n.sym) }
          global!(:dynamic_install) if INSTALLER_SENDS.include?(sym) || CONST_REBINDERS.include?(sym)
        when 'GETCONST', 'GETMCNST'
          const = insn.const_name
          @basic_object_referenced = true if const == 'BasicObject'
          scan_factory(irep, insns, idx, insn, const) if CLASS_FACTORIES.include?(const)
        when 'CLASS', 'MODULE'
          name = insn.sym_token
          @class_constant_names << name.split('::').last if name
        when 'SETCONST', 'SETMCNST'
          name = insn.const_name.to_s
          @rebound << name
          @constant_write_counts[name] += 1
          @deferred_constant_writes << name unless @walked.include?(irep.label)
        end
      end
    end
  end

  # -- singleton classes (ADR 0280) --------------------------------------------

  # Judged after the scan: class_constant? needs every SETCONST counted.
  def singleton_makers
    @singleton_makers_all ||= @singleton_makers + @singleton_opens.filter_map do |irep, idx, insn|
      [irep.label, insn.op] unless class_object_register?(irep, idx, insn.reg.to_s)
    end
  end

  def scan_singleton_maker(irep, insns, idx, insn)
    case insn.op
    when 'SDEF', 'SCLASS'
      @singleton_opens << [irep, idx, insn]
    when 'LOADSYM'
      @singleton_makers << [irep.label, insn.sym_token] if SINGLETON_MAKERS.include?(insn.sym_token)
    when *SEND_OPS
      @singleton_makers << [irep.label, insn.sym] if SINGLETON_MAKERS.include?(insn.sym)
    end
  end

  # `reg` holds a class or module object (`self` in a class body, a constant nothing assigns a
  # value to) or a fresh `Object.new` at `idx`, never an Array/Hash/Range/String.
  def class_object_register?(irep, idx, reg)
    irep.walk_writers(idx - 1, reg, follow_moves: true) do |writer, i, cur|
      case writer.op
      when 'LOADSELF' then @walked.include?(irep.label)
      when 'GETCONST', 'GETMCNST' then class_constant?(writer.op == 'GETCONST' ? writer.const_name : writer.mcnst_name)
      when 'SEND0' then writer.sym == 'new' && fresh_object_class?(irep, i, cur)
      else false
      end
    end || false
  end

  # `reg` holds a class or module object on every path: a constant nothing assigns a value to, or `self` in a
  # class body. Unlike class_object_register? it refuses a fresh `Object.new`, whose singleton class an
  # instance of a proven set can have.
  def class_constant_target?(irep, idx, reg)
    irep.walk_writers(idx - 1, reg, follow_moves: true) do |writer|
      case writer.op
      when 'LOADSELF' then @walked.include?(irep.label)
      when 'GETCONST' then class_constant?(writer.const_name)
      when 'GETMCNST' then class_constant?(writer.mcnst_name)
      else false
      end
    end || false
  end

  # No SETCONST binds a value to the name, so it can only name a class or module.
  def class_constant?(name)
    @constant_write_counts[name].zero?
  end

  def fresh_object_class?(irep, idx, reg)
    standard_constructor_lookup? &&
      irep.constant_path(idx - 1, reg)&.then { |path| path.root == :const && path.name == 'Object' && path.segments.empty? }
  end

  def loop_installer_sites
    @loop_installer_sites ||= LoopInstallers.sites(@registry)
  end

  def scan_send(irep, insns, idx, insn)
    name = insn.sym
    @clone_sent = true if name == 'clone'
    scan_freeze_send(irep, idx, insn) if name == 'freeze'
    scan_visibility_send(insns, idx, insn) if VISIBILITY_SENDS.include?(name)
    @self_rebound = true if SELF_REBINDERS.include?(name)
    if CONST_REBINDERS.include?(name)
      @dynamic_constant_mutation = true
      global!(:dynamic_install)
    end
    if MIXIN_SENDS.include?(name)
      # Class-body include/prepend is separately represented by build_registry
      # (or marked unknown_mixins); runtime mixin changes are not.
      class_body_mixin = %w[include prepend].include?(name) && @walked.include?(irep.label) &&
                         insn.op.start_with?('SSEND')
      global!(:dynamic_mixin) unless class_body_mixin

      return
    end
    return unless INSTALLER_SENDS.include?(name)
    # LOOP_INSTALLERS (ADR 0304): the registry holds every name this send installs.
    return if loop_installer_sites.include?([irep.label, idx])

    n = insn.argc
    syms = n ? literal_syms(insns, idx, n) : packed_syms(insns, idx, insn)
    return global!(:dynamic_install) unless syms

    # build_registry only attributes a self-implicit attr_* in a class body.
    trusted = name.start_with?('attr') && @walked.include?(irep.label) && insn.op.start_with?('SSEND')
    return if trusted

    scoped_label = insn.op.start_with?('SSEND') ? irep.label : nil
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
    harmless = insn.op.start_with?('SEND') && insn.argc.to_i.zero? &&
               irep.walk_dominating_writers(idx - 1, insn.reg.to_s, use: idx, follow_moves: true) do |writer|
                 case writer.op
                 when *FREEZE_LITERAL_WRITERS then true
                 when 'GETCONST' then (constant = writer.const_name) && true
                 when 'GETMCNST' then (constant = writer.mcnst_name) && true
                 end
               end
    return @freeze_possible = true unless harmless == true

    @frozen_constants << constant if constant
  end

  # `private :a, :b` / `private def a`: the names it hides. Any other argument
  # shape could name anything.
  def scan_visibility_send(insns, idx, insn)
    n = insn.op.end_with?('0') ? 0 : insn.argc
    return if n&.zero?

    syms = n ? preceding_name_args(insns, idx, n) : packed_syms(insns, idx, insn)
    syms ? @visibility_names.merge(syms) : @dynamic_visibility = true
  end

  # The n names LOADSYM'd (or `def`ed) right before the send at idx, skipping the
  # EXT prefix of a wide operand; nil when anything else feeds an argument.
  def preceding_name_args(insns, idx, n)
    syms = []
    (idx - 1).downto(0) do |i|
      break if syms.size == n

      op = insns[i].op
      next if op.start_with?('EXT')
      return nil unless %w[LOADSYM DEF].include?(op)

      syms.unshift(insns[i].sym_token)
    end
    syms if syms.size == n
  end

  # The n Symbol arguments LOADSYM'd right before the send at idx, or nil.
  def literal_syms(insns, idx, n)
    return [] if n.zero?

    run = insns[(idx - n).clamp(0, idx)...idx]
    return nil unless run.size == n && run.all? { |i| i.op == 'LOADSYM' }

    run.map { |i| i.sym_token }
  end

  # 15+ arguments arrive packed: `ARRAY Ra k` right before an `n=*` send.
  def packed_syms(insns, idx, insn)
    arr = idx.positive? && insns[idx - 1]
    return nil unless insn.pure_splat? && arr && arr.op == 'ARRAY'

    k = arr.uint_operand.to_i
    k.positive? ? literal_syms(insns, idx - 1, k) : nil
  end

  # Sends that only compare or name a factory constant (`x.is_a?(Class)`,
  # `when Struct`), never make anything with it.
  FACTORY_READS = %w[=== == != equal? is_a? kind_of? instance_of? name to_s inspect].freeze

  # `Struct.new(:a, ...)`, `Class.new(Base)`: the constant must feed one `new`
  # directly, whose members/superclass are then recorded.
  def scan_factory(irep, insns, idx, insn, const)
    reg = insn.reg.to_i
    send_idx = nil
    compared = false
    ((idx + 1)...insns.size).each do |j|
      ins = insns[j]
      break if ins.op.match?(STOP_OPS)
      next unless reads_register?(ins, reg)

      name = SEND_OPS.include?(ins.op) && ins.sym_token
      next compared = true if FACTORY_READS.include?(name)

      send_idx = j if name == 'new' && !ins.op.start_with?('SS') && ins.reg.to_i == reg
      break
    end
    return if send_idx.nil? && compared
    return global!(:class_factory_escape) unless send_idx
    return global!(:class_factory_escape) if const == 'Data'

    between = insns[(idx + 1)...send_idx]
    case const
    when 'Struct'
      between.each do |i|
        next unless i.op == 'LOADSYM'

        s = i.sym_token
        note_unknown_def(s, nil)
        note_unknown_def("#{s}=", nil)
      end
    when 'Class'
      n = insns[send_idx].argc
      return global!(:class_factory_escape) if n.nil?
      return if n.zero?

      sup = "R#{reg.to_i + 1}"
      writer = between.reverse.find { |i| i.reg_token == sup }
      base = writer && %w[GETCONST GETMCNST].include?(writer.op) && writer.const_name
      return global!(:class_factory_escape) unless base

      @dynamic_subclassed << base
    end
  end

  # Ops that only write their first register (any source is spelled out).
  PURE_WRITES = /\A(?:LOAD\w*|GET(?:CONST|GV|IV|SV|CV|UPVAR)|MOVE|STRING|LAMBDA|BLOCK|METHOD|TCLASS|OCLASS)\z/

  # Could `ins` read register `reg`? Over-approximate: a spelled-out operand,
  # or the window after its first register that sends and packing ops use.
  def reads_register?(ins, reg)
    first = ins.reg&.to_i
    return true if (first ? ins.regs.drop(1) : ins.regs).include?(reg.to_s)
    return false if first.nil? || ins.op.match?(PURE_WRITES)

    count = ins.argc || ins.uint_operand || 1
    count = 15 if ins.n_spec == '*'
    reg.between?(first, first + (2 * count) + 2)
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
    return true unless @class_decls.key?(owner)
    return true if @rebound.include?(simple(owner)) || @dynamic_subclassed.include?(simple(owner))

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

  # ADR 0256: a native file touches what it subclasses, mixes into or rebinds by
  # name. Any construct TouchScan cannot classify keeps the old rule, gated as
  # before on the file defining classes or constants at all.
  def record_native_touches(path, text, defines_class)
    scan = TouchScan.native(text, @class_decls.keys.map { |k| simple(k) }.uniq)
    if scan.legacy && defines_class
      names = (text.scan(C_STRING).flatten + text.scan(/MRB_SYM\(([A-Z]\w*)\)/).flatten)
              .grep(/\A[A-Z]/).flat_map { |s| s.split('::') }.to_set
      @touches << Touch.new(path, names, {}, "legacy (#{scan.reasons.uniq.first(3).join('; ')}): spells #{names.size} constants", false)
    end
    @touches << Touch.new(path, scan.hard, scan.evidence, '', false) unless scan.hard.empty?
    @touches << Touch.new(path, scan.origin, scan.evidence, '', true) unless scan.origin.empty?
  end

  def build_hierarchy
    global!(:qualified_class_definition) if @class_decls.values.flatten.any? { |d| !d[:outer_nil] }
    by_simple = Hash.new { |h, k| h[k] = [] }
    @class_decls.each_key { |c| by_simple[simple(c)] << c }
    @by_simple = by_simple
    @children = Hash.new { |h, k| h[k] = Set.new }
    # A superclass the walk could not resolve could be any class.
    @wild = Set.new
    @class_decls.each do |klass, decls|
      decls.each do |d|
        case d[:super]
        when nil then @wild << klass
        when String
          # Constant lookup is lexical then by ancestry: any class of that
          # simple name may be the one meant.
          by_simple[simple(d[:super])].each { |parent| @children[parent] << klass unless parent == klass }
        end
      end
    end
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

  # SINGLETON_ARMS (ADR 0369): the modules whose `.singleton` definition of `name` a guard chain can
  # answer with an identity arm, or nil when some singleton definer cannot be armed. A module object is
  # reached only by its own constant: no subclasses (module_object_self? also bars a class and any
  # `clone`, the one way to copy singleton methods). The caller proves the singleton chain has no mixin.
  public def singleton_arm_modules(name)
    return nil if @global_refusal

    owners = @registry.fetch(name, []).map(&:owner).select { |o| o.end_with?('.singleton') }.uniq
    return nil if owners.empty?

    modules = owners.map { |o| o.delete_suffix('.singleton') }
    return nil unless modules.all? { |m| module_object_self?(m) }

    modules
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

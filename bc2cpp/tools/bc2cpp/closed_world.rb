# frozen_string_literal: true

require 'set'
require_relative 'compiled_gems'
require_relative 'touch_scan'
require_relative 'foreign_definers'
require_relative 'core_defs'

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

  attr_reader :global_refusal

  def initialize(ireps:, registry:, class_decls:, walked:, native_paths:, ruby_paths:, module_names: Set.new)
    @ireps = ireps
    @module_names = module_names.to_set
    @clone_sent = false
    @registry = registry
    @class_decls = class_decls
    @walked = walked
    @global_refusal = nil
    @outside_names = Set.new
    @outside_ruby_names = Set.new
    @outside_name_paths = {}
    @outside_ruby_supers = Set.new
    @native_arms_name = nil
    @ruby_paths = ruby_paths
    # Per outside file: the constants it can create, reopen, subclass or rebind
    # (TouchScan, ADR 0256).
    @touches = []
    @unknown_defs = Set.new
    @visibility_names = Set.new
    @dynamic_visibility = false
    @rebound = Set.new
    @constant_write_counts = Hash.new(0)
    @class_constant_names = Set.new
    @deferred_constant_writes = Set.new
    @dynamic_constant_mutation = false
    @outside_constant_writes = Set.new
    @dynamic_subclassed = Set.new
    @memo = {}
    @desc_memo = {}
    scan_native(native_paths)
    scan_outside_ruby(ruby_paths)
    scan_closed_world
    build_hierarchy
    build_method_missing
    warn touch_report.join("\n") if ENV['BC2CPP_TOUCH_REPORT'] == '1'
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
  def refusal(name, listed, self_owner, installed)
    return @global_refusal if @global_refusal
    return :dynamic_install if installed.nil? || installed.include?(name)
    return :unknown_definer if @unknown_defs.include?(name)
    return :core_or_native if @outside_names.include?(name) && !native_arms_lift?(name)

    reason, required = required_classes(name, instance_self?(self_owner))
    return reason if reason
    return :unlisted_class unless required.subset?(listed.to_set)
    return :method_missing_receiver unless method_missing_free?(self_owner)

    nil
  end

  def method_missing_classes
    @mm_classes
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
  def unlisted_classes(name, listed, self_owner, installed)
    return [] unless refusal(name, listed, self_owner, installed) == :unlisted_class
    return [] unless method_missing_free?(self_owner)

    _reason, required = required_classes(name, instance_self?(self_owner))
    (required - listed.to_set).to_a.sort
  end

  # A `class` (never a module) declared in the closed world: the only owners an
  # exact-class guard can name, since modules never are `mrb_obj_class`.
  def class_declared?(owner)
    @class_decls.key?(owner)
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

  # A literal `Klass.new` has an exact-class result only while ordinary
  # construction is visible: no unresolved installer can replace `new` or
  # `allocate`, and no outside Ruby file defines either name.
  def standard_constructor_lookup?
    !@global_refusal && %w[new allocate].none? do |name|
      @unknown_defs.include?(name) || @outside_ruby_names.include?(name)
    end
  end

  # Inherited dispatch additionally needs every possible method installer for
  # this name to be represented in the registry.
  def inherited_lookup_safe?(name, owner)
    stable_class_constant?(owner) && !@unknown_defs.include?(name) && !@outside_names.include?(name)
  end

  # OWNERLESS_NATIVE_DISPATCH: class-independent native bodies may bypass
  # method lookup only when the closed inputs prove there is no competing Ruby
  # definition or unresolved dynamic installation for the same name.
  def ownerless_native_dispatch_safe?(name)
    return false if @global_refusal || @unknown_defs.include?(name) || @outside_ruby_names.include?(name)

    @registry.fetch(name, []).all? { |definition| definition.owner == '<native>' }
  end

  private

  def native_arms_lift?(name)
    @native_arms_name == name && native_only_in?(name, '/mruby-rgss/src/')
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
            @outside_constant_writes << constant
          else
            @dynamic_constant_mutation = true
          end
        end
        source.scan(/\bmrb_define_global_const\s*\(\s*\w+\s*,\s*"([A-Z]\w*)"/) do |m|
          names << m.first
          @outside_constant_writes << m.first
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
            @outside_constant_writes << constant if constant
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
      names.merge(text.scan(C_STRING).flatten) if dynamic
      @outside_names.merge(names)
      names.each { |n| (@outside_name_paths[n] ||= Set.new) << path }
      # Only mruby's own defaults: BasicObject#method_missing, Kernel#respond_to_missing?.
      global!(:outside_method_missing) if names.include?('method_missing') && !path.end_with?('/3rd/mruby/src/class.c')
      global!(:outside_respond_to_missing) if names.include?('respond_to_missing?') &&
                                              !path.end_with?('/3rd/mruby/src/kernel.c')
    end
  end

  def scan_outside_ruby(paths)
    ruby_names = foreign_method_names(paths)
    global!(:outside_method_missing) if ruby_names.include?('method_missing')
    global!(:outside_respond_to_missing) if ruby_names.include?('respond_to_missing?')
    @outside_ruby_names.merge(ruby_names)
    @outside_names.merge(ruby_names)
    paths.each do |path|
      text = File.read(path, encoding: 'BINARY').gsub(/^\s*#.*$/, '')
      text.scan(/^\s*class\s+[\w:]+\s*<\s*([\w:]+)/) { |(sup)| @outside_ruby_supers << simple(sup) }
      record_ruby_touches(path, text)
      @clone_sent = true if text.match?(/\bclone\b/)
      text.scan(/\b(?:[A-Z]\w*::)*([A-Z]\w*)\s*=(?!=|>)/) { |m| @outside_constant_writes << m.first }
      global!(:outside_dynamic_definition) if text.match?(RUBY_DYNAMIC)
      @dynamic_constant_mutation = true if text.match?(RUBY_CONST_DYNAMIC)
      global!(:outside_class_factory) if text.match?(/\b(?:Class|Struct)\.new\b/)
    end
  end

  # -- the closed world's own dynamic definitions ------------------------------

  def scan_closed_world
    registered = Set.new
    @registry.each_value { |defs| defs.each { |d| registered << d.irep if d.irep } }
    @ireps.each_value do |irep|
      insns = irep.instructions
      insns.each_with_index do |insn, idx|
        case insn.op
        when 'TDEF', 'SDEF'
          child = irep.reps[insn.block_index]
          @unknown_defs << insn.sym unless registered.include?(child)
        when 'DEF'
          sym = insn.sym_token
          method = insns[0...idx].reverse.find { |i| i.op == 'METHOD' }
          child = method && irep.reps[method.block_index.to_i]
          @unknown_defs << sym unless child && registered.include?(child)
        when *SEND_OPS
          scan_send(irep, insns, idx, insn)
        when 'LOADSYM'
          sym = insn.sym_token
          @clone_sent = true if sym == 'clone'
          @dynamic_visibility = true if VISIBILITY_SENDS.include?(sym)
          global!(:dynamic_install) if INSTALLER_SENDS.include?(sym) || CONST_REBINDERS.include?(sym)
        when 'GETCONST', 'GETMCNST'
          const = insn.const_name
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

  def scan_send(irep, insns, idx, insn)
    name = insn.sym
    @clone_sent = true if name == 'clone'
    scan_visibility_send(insns, idx, insn) if VISIBILITY_SENDS.include?(name)
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

    n = insn.argc
    syms = n ? literal_syms(insns, idx, n) : packed_syms(insns, idx, insn)
    return global!(:dynamic_install) unless syms

    # build_registry only attributes a self-implicit attr_* in a class body.
    trusted = name.start_with?('attr') && @walked.include?(irep.label) && insn.op.start_with?('SSEND')
    return if trusted

    syms.each do |s|
      @unknown_defs << s
      @unknown_defs << "#{s}="
    end
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
        @unknown_defs << s
        @unknown_defs << "#{s}="
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

  def required_classes(name, instance_self = false)
    @memo[[name, instance_self]] ||= begin
      defs = @registry.fetch(name, []).reject { |d| d.owner == '<native>' }
      required = Set.new
      reason = nil
      defs.each do |d|
        if d.owner.end_with?('.singleton')
          next if instance_self

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
  def method_missing_free?(self_owner)
    return true if @mm_classes.empty?
    return false unless self_owner
    # A class or module object: only a hook on Class/Module/Object or a
    # singleton method_missing reaches it, and both are global refusals.
    return true if self_owner.end_with?('.singleton')
    return false if opaque?(self_owner)

    ([self_owner] + descendants(self_owner).to_a).none? { |c| @mm_classes.include?(c) }
  end
end

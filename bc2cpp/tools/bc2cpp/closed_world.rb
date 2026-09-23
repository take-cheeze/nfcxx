# frozen_string_literal: true

require 'set'
require_relative 'compiled_gems'

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

  attr_reader :global_refusal

  def initialize(ireps:, registry:, class_decls:, walked:, native_paths:, ruby_paths:)
    @ireps = ireps
    @registry = registry
    @class_decls = class_decls
    @walked = walked
    @global_refusal = nil
    @outside_names = Set.new
    # Per outside file that could reach a class: the constant names it spells.
    @touch_sets = []
    @unknown_defs = Set.new
    @rebound = Set.new
    @dynamic_subclassed = Set.new
    @memo = {}
    @desc_memo = {}
    scan_native(native_paths)
    scan_outside_ruby(ruby_paths)
    scan_closed_world
    build_hierarchy
    build_method_missing
  end

  # nil when a fallback for `name` on a chain listing `listed` can only raise
  # NoMethodError, else why not. `self_owner` is the enclosing method's owner
  # when the receiver is its `self`; `installed` is CodeGen#symbol_installed_names.
  def refusal(name, listed, self_owner, installed)
    return @global_refusal if @global_refusal
    return :dynamic_install if installed.nil? || installed.include?(name)
    return :unknown_definer if @unknown_defs.include?(name)
    return :core_or_native if @outside_names.include?(name)

    reason, required = required_classes(name)
    return reason if reason
    return :unlisted_class unless required.subset?(listed.to_set)
    return :method_missing_receiver unless method_missing_free?(self_owner)

    nil
  end

  def method_missing_classes
    @mm_classes
  end

  # Is every instance whose class descends from `owner` exactly an `owner`?
  def exact_class?(owner)
    !@global_refusal && !opaque?(owner) && descendants(owner).empty?
  end

  private

  def global!(reason)
    @global_refusal ||= reason
  end

  # -- outside the closed world ------------------------------------------------

  def scan_native(paths)
    paths.each do |path|
      # Drop comments, keeping string and char literals (a "//" inside one).
      text = File.binread(path).gsub(%r{"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|/\*.*?\*/|//[^\n]*}m) do |tok|
        tok.start_with?('/') ? ' ' : tok
      end
      names = Set.new
      dynamic = text.match?(NATIVE_DYNAMIC)
      defines_class = text.match?(/\bmrb_(?:const_set|const_remove|define_global_const)\b/)
      text.scan(/\bmrb_define_(\w+)\s*\(([^;]*)/m) do |kind, body|
        literals = body.scan(C_STRING).flatten
        tokens = body.scan(MRB_SYM_TOKEN_RE).map { |m, n| resolve_mrb_sym_token(m, n) }
        if kind.match?(/\A(?:(?:class|module)(?:_under)?(?:_id)?|(?:global_)?const(?:_id)?)\z/)
          defines_class = true
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
      # A file that defines or rebinds constants may reach any class it names.
      if defines_class
        @touch_sets << (text.scan(C_STRING).flatten + text.scan(/MRB_SYM\(([A-Z]\w*)\)/).flatten)
                       .grep(/\A[A-Z]/).flat_map { |s| s.split('::') }.to_set
      end
      names.merge(text.scan(C_STRING).flatten) if dynamic
      @outside_names.merge(names)
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
    @outside_names.merge(ruby_names)
    paths.each do |path|
      text = File.read(path, encoding: 'BINARY').gsub(/^\s*#.*$/, '')
      @touch_sets << text.scan(/\b[A-Z]\w*/).to_set
      global!(:outside_dynamic_definition) if text.match?(RUBY_DYNAMIC)
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
          _reg, sym, ref = insn.args.split(/\s+/, 3)
          child = irep.reps[ref.to_s[/I\[(\d+)\]/, 1].to_i]
          @unknown_defs << sym.delete_prefix(':') unless registered.include?(child)
        when 'DEF'
          sym = insn.args[/:(\S+)/, 1]
          method = insns[0...idx].reverse.find { |i| i.op == 'METHOD' }
          child = method && irep.reps[method.args[/I\[(\d+)\]/, 1].to_i]
          @unknown_defs << sym unless child && registered.include?(child)
        when *SEND_OPS
          scan_send(irep, insns, idx, insn)
        when 'LOADSYM'
          sym = insn.args[/:(\S+)/, 1]
          global!(:dynamic_install) if INSTALLER_SENDS.include?(sym) || CONST_REBINDERS.include?(sym)
        when 'GETCONST', 'GETMCNST'
          const = insn.args[/(?:::|\s)(\w+)\s*\z/, 1]
          scan_factory(irep, insns, idx, insn, const) if CLASS_FACTORIES.include?(const)
        when 'SETCONST', 'SETMCNST'
          @rebound << insn.args[/(?:::|\A)(\w+)\s+R\d+/, 1].to_s
        end
      end
    end
  end

  def scan_send(irep, insns, idx, insn)
    name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
    global!(:dynamic_install) if CONST_REBINDERS.include?(name)
    return unless INSTALLER_SENDS.include?(name)

    n = insn.args[/n=(\d+)/, 1]&.to_i
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

  # The n Symbol arguments LOADSYM'd right before the send at idx, or nil.
  def literal_syms(insns, idx, n)
    return [] if n.zero?

    run = insns[(idx - n).clamp(0, idx)...idx]
    return nil unless run.size == n && run.all? { |i| i.op == 'LOADSYM' }

    run.map { |i| i.args[/:(\S+)/, 1] }
  end

  # 15+ arguments arrive packed: `ARRAY Ra k` right before an `n=*` send.
  def packed_syms(insns, idx, insn)
    arr = idx.positive? && insns[idx - 1]
    return nil unless insn.args.match?(/n=\*(?!\|)/) && arr && arr.op == 'ARRAY'

    k = arr.args[/\AR\d+\s+(\d+)/, 1].to_i
    k.positive? ? literal_syms(insns, idx - 1, k) : nil
  end

  # Sends that only compare or name a factory constant (`x.is_a?(Class)`,
  # `when Struct`), never make anything with it.
  FACTORY_READS = %w[=== == != equal? is_a? kind_of? instance_of? name to_s inspect].freeze

  # `Struct.new(:a, ...)`, `Class.new(Base)`: the constant must feed one `new`
  # directly, whose members/superclass are then recorded.
  def scan_factory(irep, insns, idx, insn, const)
    reg = insn.args[/\AR(\d+)/, 1].to_i
    send_idx = nil
    compared = false
    ((idx + 1)...insns.size).each do |j|
      ins = insns[j]
      break if ins.op.match?(STOP_OPS)
      next unless reads_register?(ins, reg)

      name = SEND_OPS.include?(ins.op) && ins.args[/:(\S+)/, 1]
      next compared = true if FACTORY_READS.include?(name)

      send_idx = j if name == 'new' && !ins.op.start_with?('SS') && ins.args[/\AR(\d+)/, 1].to_i == reg
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

        s = i.args[/:(\S+)/, 1]
        @unknown_defs << s
        @unknown_defs << "#{s}="
      end
    when 'Class'
      n = insns[send_idx].args[/n=(\d+)/, 1]&.to_i
      return global!(:class_factory_escape) if n.nil?
      return if n.zero?

      sup = "R#{reg.to_i + 1}"
      writer = between.reverse.find { |i| i.args.match?(/\A#{sup}\b/) }
      base = writer && %w[GETCONST GETMCNST].include?(writer.op) && writer.args[/(?:::|\s)(\w+)\s*\z/, 1]
      return global!(:class_factory_escape) unless base

      @dynamic_subclassed << base
    end
  end

  # Ops that only write their first register (any source is spelled out).
  PURE_WRITES = /\A(?:LOAD\w*|GET(?:CONST|GV|IV|SV|CV|UPVAR)|MOVE|STRING|LAMBDA|BLOCK|METHOD|TCLASS|OCLASS)\z/

  # Could `ins` read register `reg`? Over-approximate: a spelled-out operand,
  # or the window after its first register that sends and packing ops use.
  def reads_register?(ins, reg)
    first = ins.args[/\AR(\d+)/, 1]&.to_i
    rest = first ? ins.args.sub(/\AR\d+/, '') : ins.args
    return true if rest.match?(/\bR#{reg}\b/)
    return false if first.nil? || ins.op.match?(PURE_WRITES)

    count = ins.args[/n=(\d+)/, 1]&.to_i || ins.args[/\AR\d+\s+(\d+)/, 1]&.to_i || 1
    count = 15 if ins.args.include?('n=*')
    reg.between?(first, first + (2 * count) + 2)
  end

  # -- the class hierarchy -----------------------------------------------------

  def simple(name)
    name.split('::').last
  end

  # A class whose instances this analysis can enumerate: declared by a CLASS
  # op, not also created or subclassed outside, never rebound or subclassed
  # dynamically, and named by a plain constant path.
  def opaque?(owner)
    return true if owner.include?('.') || owner.include?('<') || BOOT_CLASSES.include?(owner)
    return true unless @class_decls.key?(owner)
    return true if @rebound.include?(simple(owner)) || @dynamic_subclassed.include?(simple(owner))

    # Outside code reaches a class only through its path, so a file that could
    # create, reopen or subclass it spells both the root and the last segment.
    spelled = [owner.split('::').first, simple(owner)].uniq
    @touch_sets.any? { |set| spelled.all? { |s| set.include?(s) } }
  end

  def build_hierarchy
    global!(:qualified_class_definition) if @class_decls.values.flatten.any? { |d| !d[:outer_nil] }
    by_simple = Hash.new { |h, k| h[k] = [] }
    @class_decls.each_key { |c| by_simple[simple(c)] << c }
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
  def required_classes(name)
    @memo[name] ||= begin
      defs = @registry.fetch(name, []).reject { |d| d.owner == '<native>' }
      required = Set.new
      reason = nil
      defs.each do |d|
        break reason = :singleton_definer if d.owner.end_with?('.singleton')
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

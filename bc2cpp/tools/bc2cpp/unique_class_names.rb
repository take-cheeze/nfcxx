# frozen_string_literal: true
require_relative 'native_expression_devirt'
require_relative 'source_text'

# UNIQUE_CLASS_NAME: maps a bare class name N (e.g. `Bitmap` written in RPG2k
# code, which reaches RGSS::Bitmap through `class Object; include RGSS; end`)
# to "P::N" when the closed world, NATIVE_SRCS and FOREIGN_RUBY_SRCS give N
# exactly one binding, P::N, that nothing reassigns, and no const_set,
# remove_const or const_missing exists. A lookup of N that succeeds
# can then only return P::N.
module UniqueClassNames
  BINDING_CALLS = [
    /mrb_define_(?:global_)?const(?:_id)?\s*\([^;]{0,200}/m,
    /mrb_const_set\s*\([^;]{0,200}/m,
    /mrb_define_(?:class|module)(?:_under)?(?:_id)?\s*\([^;]{0,200}/m
  ].freeze
  UNDER_DEFINITION = /\Amrb_define_(?:class|module)_under(?:_id)?\s*\(\s*\w+\s*,\s*(\w+)\s*,\s*(?:"(\w+)"|MRB_SYM\((\w+)\))/
  FUNCTION_HEADER = /^(?:[\w:<>*&"]+[ \t]+)*[*&]?(\w+)\s*\(([^;{}()]*)\)\s*(?:const\s*)?\{/m

  class << self
    # bare name => "P::N"; nil (the default) disables canonicalization.
    attr_accessor :table
    # The closed world's class facts for lookup_name (set by analyze; nil when analyze refuses).
    attr_accessor :lexical
    # Modules the closed world includes into Object; entries may be qualified
    # as `Object::RGSS` or already normalized to `RGSS`.
    attr_accessor :object_mixins
  end

  module_function

  # The class `name` names inside `owner` (a class name, `.singleton` allowed), or nil when the closed world does not
  # settle it. The unique table answers first (one binding, so no other class can be found); otherwise lookup_name
  # follows Ruby's order over the facts analyze recorded.
  def resolve(name, owner)
    canonical = UniqueClassNames.table&.[](name)
    if canonical && owner
      scope = canonical.delete_suffix("::#{name}")
      site = owner.to_s.delete_suffix('.singleton')
      lexical = site == scope || site.start_with?("#{scope}::")
      mixins = Array(UniqueClassNames.object_mixins).map { |mixin| mixin.delete_prefix('Object::') }
      return canonical if lexical || mixins.include?(scope)
    end
    lookup_name(name, owner)
  end

  # Ruby's constant lookup from a method of `owner` (vm.c): the lexically enclosing classes, innermost first and
  # excluding the top level; then the ancestors of `owner` (superclass chain); then Object. Each step asks the closed
  # world's own table, so a step that cannot be settled returns nil. Only a name bound in the closed world (no
  # native, foreign or assigned binding) is answered, and a class with an included module is never walked past.
  # The ancestor steps need the superclass chain: a missing entry means the superclass is unknown.
  def lookup_name(name, owner)
    facts = UniqueClassNames.lexical
    return nil unless facts && owner
    return nil if facts[:refused].include?(name)

    site = owner.to_s.delete_suffix('.singleton')
    parts = site.split('::')
    return nil if facts[:unknown].include?(parts.last) # a compact `class A::B`: its lexical scope is not in the bytecode
    defined = facts[:defined]
    parts.size.downto(1) do |k|
      candidate = (parts[0, k] + [name]).join('::')
      return candidate if defined.include?(candidate)
    end

    # Ancestors in MRO order: the class, its included modules (last include first), its superclass, and so on.
    # A prepended module sits before the class's own table, so a class with one is never walked past.
    cursor = site
    seen = Set.new
    loop do
      return nil unless seen.add?(cursor)
      return nil if facts[:prepended].key?(cursor) || facts[:unknown_mixins].include?(cursor)

      mixins_of(facts, cursor).reverse_each do |mixin|
        return nil unless closed_module?(facts, mixin)

        candidate = "#{mixin}::#{name}"
        return candidate if defined.include?(candidate)
      end

      # A module has no superclass: after its includes, the search goes to Object.
      sup = facts[:modules].include?(cursor) ? :none : facts[:superclass_of].fetch(cursor) { return nil }
      break if sup == :none
      return nil unless sup.is_a?(String)

      candidate = "#{sup}::#{name}"
      return candidate if defined.include?(candidate)

      cursor = sup
    end
    # Object's own constants come before its mixins; the mixins (`include RGSS` at top level) come last, last include first.
    return name if defined.include?(name)
    return nil if facts[:unknown_mixins].include?('Object')

    Array(UniqueClassNames.object_mixins).map { |mixin| mixin.delete_prefix('Object::') }.reverse_each do |mixin|
      return nil unless closed_module?(facts, mixin)

      candidate = "#{mixin}::#{name}"
      return candidate if defined.include?(candidate)
    end
    nil
  end

  # The modules `owner` includes, in include order.
  def mixins_of(facts, owner)
    Array(facts[:included][owner])
  end

  # A module whose own constant table is the whole story: declared in the closed world and including nothing,
  # prepending nothing, and with no unresolved include.
  def closed_module?(facts, mod)
    facts[:defined].include?(mod) && mixins_of(facts, mod).empty? && !facts[:prepended].key?(mod) &&
      !facts[:unknown_mixins].include?(mod)
  end

  # ruby_sources: { ireps:, root: } for the Ruby sources the build does not compile, as bytecode (bc2cpp.rb). Without
  # it, a native-only class is not admitted: its writes in those sources are unknown.
  def analyze(ireps, root_label, native_paths, foreign_paths, superclass_of: {}, included: {}, prepended: {},
              unknown_mixins: Set.new, ruby_sources: nil)
    UniqueClassNames.lexical = nil
    return {} unless native_paths && foreign_paths

    modules = Set.new
    paths = bytecode_class_paths(ireps, root_label, modules)
    assigned = Set.new
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        case insn.op
        when 'SETCONST' then assigned << insn.const_name
        when 'SETMCNST' then assigned << insn.mcnst_name
        when 'SEND', 'SEND0', 'SSEND', 'SSEND0', 'SENDB', 'SSENDB', 'LOADSYM'
          return {} if insn.sym.to_s.match?(StableClassConstants::DYNAMIC_MUTATION)
        end
        return {} if insn.sym == 'const_missing'
      end
    end
    Array(foreign_paths).each do |path|
      text = File.read(path, encoding: 'UTF-8')
      return {} if text.match?(StableClassConstants::DYNAMIC_MUTATION) ||
                    text.match?(/\bdef\s+(?:self\.)?const_missing\b/)
    rescue SystemCallError => e
      warn "[bc2cpp] UniqueClassNames: cannot read #{path}: #{e.message}"
      return {}
    end

    sources = Array(native_paths).select { |path| File.file?(path) }
                                 .map { |path| File.read(path, encoding: 'UTF-8') }
    bindings = native_bindings(sources)
    # A native class or module (kind 2 of BINDING_CALLS) is a candidate at its full path; a native value constant, or a
    # class whose outer namespace is not known, refuses the name.
    native_classes = Set.new
    native_refused = Set.new
    bindings.each do |name, list|
      list.each do |source, pos, var, kind|
        if kind != 2
          native_refused << name
        elsif var.nil?
          native_classes << name
        elsif (outer = native_module_binding(sources, source, pos, var))
          native_classes << "#{outer}::#{name}"
        else
          native_refused << name
        end
      end
    end
    defined = paths.values.flat_map { |defs| defs.grep(String) }.to_set | native_classes
    # A foreign top-level `class X < Y` that the closed world does not compile (mruby's 10error.rb, which
    # is kept out for speed) still binds X at top level under Y: it is defined with that superclass. Its own
    # includes are unknown, so the ancestor walk never passes through it.
    top_level, nested = foreign_class_names(foreign_paths)
    closed_top = defined.reject { |n| n.include?('::') }
    foreign_classes = top_level.reject { |name, sup| closed_top.include?(name) || sup.nil? }
    rebound_text = foreign_rebound_names(foreign_paths)
    foreign = rebound_text | nested | (top_level.keys.to_set - closed_top - foreign_classes.keys)
    defined |= foreign_classes.keys.to_set
    superclass_of = superclass_of.merge(foreign_classes)
    unknown_mixins = unknown_mixins.to_set | foreign_classes.keys
    UniqueClassNames.lexical = {
      defined: defined,
      unknown: paths.select { |_, defs| defs.any? { |d| !d.is_a?(String) } }.keys.to_set,
      refused: assigned | Set.new(Array(foreign)) | native_refused,
      superclass_of: superclass_of,
      modules: modules,
      included: included,
      prepended: prepended,
      unknown_mixins: unknown_mixins.to_set
    }
    table = paths.each_with_object({}) do |(name, defs), out|
      next unless defs.size == 1 && defs.first.is_a?(String)
      next if defs.first.split('::').any? { |segment| assigned.include?(segment) || foreign.include?(segment) }
      # A top-level module (`module LCF`) is reachable from every lexical scope through Object: its one binding is
      # the answer when no native source binds the name too.
      unless defs.first.include?('::')
        out[name] = name if bindings[name].empty? && !assigned.include?(name) && !foreign.include?(name)
        next
      end

      scope = defs.first.delete_suffix("::#{name}")
      agree = bindings[name].all? do |source, pos, var|
        var && native_module_binding(sources, source, pos, var) == scope
      end
      out[name] = defs.first if agree
    end
    native_only_classes(ireps, root_label, native_paths, ruby_sources, paths, defined, native_classes, native_refused,
                        bindings, top_level, nested, rebound_text).each { |name, full| table[name] = full }
    table
  end

  # NATIVE_ONLY_CLASS: a class or module that one native binding defines and that no other binding of the closed world
  # can reach, so its bare name denotes that class for the whole run (the same claim the bytecode table makes).
  # Admitted only when:
  #   - exactly one native binding names it, and it is a class/module definition (kind 2), at one full path P;
  #   - the closed world has no bytecode or Ruby class/module statement of that bare name, and no `:unknown` one;
  #   - nothing writes that bare name: no SETCONST/SETMCNST in the bytecode or in the Ruby sources this build reads as
  #     bytecode (ruby_sources), and no foreign text assignment or text class/module statement names it;
  #   - the scope of P is itself a unique native scope (unique_native_scope?), so P is not reached through a rebound
  #     module;
  #   - no constant mutation the closed world cannot see: a const_set/remove_const/eval send or LOADSYM, a string
  #     instance_eval/class_eval/module_eval, or a native mrb_const_set/remove with a computed name or mrb_load_*
  #     anywhere (constant_rebinding_dynamic?). The core's own C sources are trusted, as in the closed-world scan.
  # Without ruby_sources (the Ruby sources did not compile) nothing is admitted.
  def native_only_classes(ireps, root_label, native_paths, ruby_sources, paths, defined, native_classes, native_refused,
                          bindings, top_level, nested, rebound_text)
    return {} unless ruby_sources && ruby_sources[:ireps] && native_paths
    ruby_ireps = ruby_sources[:ireps]
    return {} if constant_rebinding_dynamic?(ireps, ruby_ireps, native_paths)

    written = Set.new
    [ireps, ruby_ireps].each do |set|
      set.each_value do |irep|
        irep.instructions.each do |insn|
          case insn.op
          when 'SETCONST' then written << insn.const_name
          when 'SETMCNST' then written << insn.mcnst_name
          end
        end
      end
    end
    return {} if written.include?(nil)

    ruby_defs = ruby_ireps.empty? ? {} : bytecode_class_paths(ruby_ireps, ruby_sources[:root])
    definitions = Hash.new { |hash, name| hash[name] = Set.new }
    defined.each { |full| definitions[full.split('::').last] << full }
    unknown = Set.new
    [paths, ruby_defs].each do |class_table|
      class_table.each do |key, list|
        bare = key.to_s.split('::').last
        unknown << bare unless list.all?(String)
        list.grep(String) { |full| definitions[bare] << full }
      end
    end
    text_classes = top_level.keys.to_set | nested
    context = { definitions: definitions, unknown: unknown, refused: native_refused, text: text_classes,
                written: written, rebound: rebound_text }

    admitted = {}
    native_classes.group_by { |full| full.split('::').last }.each do |name, fulls|
      next unless fulls.size == 1
      full = fulls.first
      list = bindings[name]
      next unless list.size == 1 && list.first[3] == 2
      next if paths.key?(name) || unknown.include?(name) || native_refused.include?(name)
      next if text_classes.include?(name) || rebound_text.include?(name) || written.include?(name)
      next unless definitions[name] == Set[full]

      scope = full.delete_suffix("::#{name}")
      admitted[name] = full if scope == full || unique_native_scope?(scope, context)
    end
    admitted
  end

  # A scope a native-only class is reached through: one definition, never written, and itself reached through a
  # unique scope. depth bounds a cyclic or deep chain (refused).
  def unique_native_scope?(full, context, depth = 0)
    bare = full.split('::').last
    return false if depth > 8 || context[:unknown].include?(bare) || context[:refused].include?(bare) ||
                    context[:text].include?(bare) || context[:rebound].include?(bare) || context[:written].include?(bare)
    return false unless context[:definitions][bare] == Set[full]

    scope = full.delete_suffix("::#{bare}")
    scope == full || unique_native_scope?(scope, context, depth + 1)
  end

  # A send or symbol that can rebind a constant by name the closed-world scan does not model: const_set, remove_const,
  # a string eval (eval, or instance_eval/class_eval/module_eval with an argument and no block), in bytecode, or a
  # native mrb_const_set/remove whose name is not a literal, or mrb_load_string/nstring/file, outside the core's C.
  CONST_REBINDING_SENDS = %w[const_set remove_const eval].freeze
  STRING_EVAL_SENDS = %w[instance_eval class_eval module_eval].freeze
  NATIVE_CONST_WRITE = /\bmrb_const_(?:set|remove)\s*\(([^;]*)\)\s*;/
  NATIVE_CONST_LITERAL = /\bmrb_intern_(?:lit|cstr|static)\s*\(|\bMRB_SYM\(/
  NATIVE_LOAD = /\bmrb_load_(?:string|nstring|file)\s*\(/

  def constant_rebinding_dynamic?(ireps, ruby_ireps, native_paths)
    (ireps.each_value.to_a + ruby_ireps.each_value.to_a).any? do |irep|
      irep.instructions.any? { |insn| constant_rebinding_insn?(insn) }
    end || Array(native_paths).any? do |path|
      next false if path.include?('/3rd/mruby/') || !File.file?(path)

      text = File.read(path, encoding: 'UTF-8')
      text.match?(NATIVE_LOAD) || text.scan(NATIVE_CONST_WRITE).any? { |(args)| !args.match?(NATIVE_CONST_LITERAL) }
    end
  end

  def constant_rebinding_insn?(insn)
    name = case insn.op
           when 'LOADSYM' then insn.sym_token.to_s
           when *BytecodeIR::Ops::SEND then insn.sym.to_s
           end
    return false unless name

    return true if CONST_REBINDING_SENDS.include?(name)

    STRING_EVAL_SENDS.include?(name) && !BytecodeIR::Ops::BLOCK_SEND.include?(insn.op) && insn.argc != 0
  end

  # Names a foreign Ruby source assigns (`NAME = value`): the binding changes, so the name is refused.
  def foreign_rebound_names(paths)
    names = Set.new
    Array(paths).each do |path|
      src = SourceText.read(path, 'UniqueClassNames.foreign_rebound_names') or next
      src.scan(/^\s*([A-Z][A-Za-z_0-9]*)\s*=[^=~]/) { names << Regexp.last_match(1) }
    end
    names
  end

  # [top-level, nested] names foreign Ruby sources open with `class`/`module`. top-level maps each name to its
  # superclass name (nil when the definition has none written). A column-0 definition is top-level; a nested
  # (indented) one may bind a new constant in its scope, so its name is always refused.
  def foreign_class_names(paths)
    top_level = {}
    nested = Set.new
    Array(paths).each do |path|
      src = SourceText.read(path, 'UniqueClassNames.foreign_class_names') or next
      src.scan(/^(?:class|module)\s+([A-Z][A-Za-z_0-9]*)(?:\s*<\s*([A-Z][A-Za-z_0-9]*)\b)?/) do |name, sup|
        top_level[name] = top_level.key?(name) && top_level[name] != sup ? nil : sup # conflicting supers: unknown
      end
      src.scan(/^[ \t]+(?:class|module)\s+([A-Z][A-Za-z_0-9]*)/) { nested << Regexp.last_match(1) }
    end
    [top_level, nested]
  end

  # bare name => [[source, offset, outer variable or nil], ...] for every native
  # constant binding naming it; the variable is set only for an `_under` form.
  def native_bindings(sources)
    out = Hash.new { |hash, name| hash[name] = [] }
    sources.each do |source|
      BINDING_CALLS.each_with_index do |pattern, kind|
        source.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          segment = match[0]
          args, = NativeExpressionDevirt.split_call_arguments(source, match.begin(0) + segment.index('('))
          under = segment.match(UNDER_DEFINITION)
          # Only the argument that binds the name counts; the others may be lookups (`mrb_module_get(M, "RGSS")`).
          index = binding_name_index(segment, kind)
          name = binding_name(args&.[](index))
          next unless name

          var = under && (under[2] || under[3]) == name ? under[1] : nil
          out[name] << [source, match.begin(0), var, kind]
        end
      end
    end
    out
  end

  # The position of the name argument: after `mrb` for a constant or class registration, after `mrb` and the outer
  # module for a `_under` form, and first for `mrb_define_global_const`.
  def binding_name_index(segment, kind)
    case kind
    when 0 then segment.start_with?('mrb_define_global') ? 1 : 2
    when 1 then 2
    else segment.match?(/\Amrb_define_(?:class|module)_under/) ? 2 : 1
    end
  end

  # The constant a name argument spells: "Name", MRB_SYM(Name) or mrb_intern_lit(mrb, "Name"). Anything else is nil.
  def binding_name(arg)
    arg = arg&.strip
    return nil unless arg

    name = arg[/\A"(\w+)"\z/, 1] || arg[/\AMRB_SYM[A-Z_]*\(\s*(\w+)\s*\)\z/, 1] ||
           arg[/\Amrb_intern_(?:lit|cstr)\(\s*\w+\s*,\s*"(\w+)"\s*\)\z/, 1]
    name if name&.match?(/\A[A-Z]\w*\z/)
  end

  # bare name => Set of full paths opened by its CLASS/MODULE statements, with
  # :unknown for a statement whose outer scope is not the lexical one.
  def bytecode_class_paths(ireps, root_label, modules = nil)
    paths = Hash.new { |hash, name| hash[name] = Set.new }
    seen = Set.new
    walk = lambda do |label, namespace|
      irep = ireps.fetch(label)
      bodies = BytecodeIR.class_bodies(irep, 'CLASS', 'MODULE')
      irep.each_with_op('CLASS', 'MODULE') do |insn, idx|
        full = BytecodeIR.class_body_path(irep, idx, namespace) || :unknown
        paths[insn.sym] << full
        modules << full if modules && insn.op == 'MODULE' && full.is_a?(String)
        seen << [label, idx]
        # Walked at the opener: its body EXEC is the next instruction, so no
        # other instruction of this irep runs between the two.
        walk.call(bodies[idx], full) if bodies.key?(idx) && full.is_a?(String)
      end
    end
    walk.call(root_label, nil)
    ireps.each do |label, irep|
      irep.each_with_op('CLASS', 'MODULE') do |insn, idx|
        next if seen.include?([label, idx])

        paths[insn.sym_token] << :unknown
      end
    end
    paths
  end

  # The module name `var` holds at `pos`: every assignment to it in the
  # enclosing function is `mrb_define_module(M, "P")`, or it is an RClass*
  # parameter every caller in `sources` passes such a variable to.
  def native_module_binding(sources, source, pos, var, depth = 2)
    header = nil
    source.to_enum(:scan, FUNCTION_HEADER).each do
      match = Regexp.last_match
      break if match.begin(0) > pos

      header = match
    end
    return nil unless header

    body_end = source.index(/^\}/, header.end(0))
    return nil unless body_end && pos < body_end

    body = source[header.end(0)...body_end]
    rhs = body.scan(/(?<![\w>.])#{Regexp.escape(var)}\s*=(?!=)\s*([^;]+);/).flatten
    unless rhs.empty?
      modules = rhs.map { |expr| expr.strip[/\Amrb_define_module\s*\(\s*\w+\s*,\s*"(\w+)"\s*\)\z/, 1] }
      return modules.uniq.size == 1 ? modules.first : nil
    end
    params = header[2].split(',').map(&:strip)
    index = params.index { |param| param.match?(/\A(?:struct\s+)?RClass\s*\*\s*#{Regexp.escape(var)}\z/) }
    return nil unless index && depth.positive?

    callers = []
    sources.each do |caller_source|
      caller_source.to_enum(:scan, /\b#{Regexp.escape(header[1])}\s*\(/).each do
        call = Regexp.last_match
        next if caller_source.equal?(source) && call.begin(0) == header.begin(1)

        args, = NativeExpressionDevirt.split_call_arguments(caller_source, call.end(0) - 1)
        arg = args&.[](index)
        return nil unless arg&.match?(/\A\w+\z/)

        callers << native_module_binding(sources, caller_source, call.begin(0), arg, depth - 1)
      end
    end
    callers.uniq.size == 1 ? callers.first : nil
  end
end

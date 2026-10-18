# frozen_string_literal: true

# UNIQUE_CLASS_NAME: maps a bare class name N (e.g. `Bitmap` written in RPG2k
# code, which reaches RGSS::Bitmap through `class Object; include RGSS; end`)
# to "P::N" when the closed world, NATIVE_SRCS and FOREIGN_RUBY_SRCS give N
# exactly one binding, P::N, that nothing reassigns, and no const_set,
# remove_const, autoload or const_missing exists. A lookup of N that succeeds
# can then only return P::N. See docs/adr/0203-bc2cpp-unique-class-names.md.
module UniqueClassNames
  BINDING_CALLS = [
    /mrb_define_(?:global_)?const(?:_id)?\s*\([^;]{0,200}/m,
    /mrb_const_set\s*\([^;]{0,200}/m,
    /mrb_define_(?:class|module)(?:_[a-z_]*)?\s*\([^;]{0,200}/m
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

    cursor = site
    seen = Set.new
    loop do
      return nil if facts[:included].key?(cursor) || !seen.add?(cursor)

      sup = facts[:superclass_of].fetch(cursor) { return nil }
      break if sup == :none
      return nil unless sup.is_a?(String)

      candidate = "#{sup}::#{name}"
      return candidate if defined.include?(candidate)

      cursor = sup
    end
    # Object's own constants come before its mixins (object_mixins), so a top-level definition is the answer.
    defined.include?(name) ? name : nil
  end

  def analyze(ireps, root_label, native_paths, foreign_paths, superclass_of: {}, included: {})
    UniqueClassNames.lexical = nil
    return {} unless native_paths && foreign_paths

    paths = bytecode_class_paths(ireps, root_label)
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

    foreign = IntegerConstants.foreign_const_names(foreign_paths)
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
    UniqueClassNames.lexical = {
      defined: paths.values.flat_map { |defs| defs.grep(String) }.to_set | native_classes,
      unknown: paths.select { |_, defs| defs.any? { |d| !d.is_a?(String) } }.keys.to_set,
      refused: assigned | Set.new(Array(foreign)) | native_refused,
      superclass_of: superclass_of,
      included: included
    }
    paths.each_with_object({}) do |(name, defs), out|
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
          names = segment.scan(/"([A-Z]\w*)"/).flatten | segment.scan(/MRB_SYM[A-Z_]*\(\s*(\w+)\s*\)/).flatten
          under = segment.match(UNDER_DEFINITION)
          names.each do |name|
            var = under && (under[2] || under[3]) == name ? under[1] : nil
            out[name] << [source, match.begin(0), var, kind]
          end
        end
      end
    end
    out
  end

  # bare name => Set of full paths opened by its CLASS/MODULE statements, with
  # :unknown for a statement whose outer scope is not the lexical one.
  def bytecode_class_paths(ireps, root_label)
    paths = Hash.new { |hash, name| hash[name] = Set.new }
    seen = Set.new
    walk = lambda do |label, namespace|
      irep = ireps.fetch(label)
      pending = nil
      irep.instructions.each_with_index do |insn, idx|
        case insn.op
        when 'CLASS', 'MODULE'
          reg = insn.reg_token
          name = insn.sym
          outer = irep.last_writer(idx - 1, insn.reg)
          full = case outer&.op
                 when 'LOADNIL' then namespace ? "#{namespace}::#{name}" : name
                 when 'OCLASS' then name
                 else :unknown
                 end
          paths[name] << full
          seen << [label, idx]
          pending = [reg, full, idx]
        when 'EXEC'
          if pending && pending[0] == insn.reg_token && pending[2] == idx - 1 && pending[1].is_a?(String)
            walk.call(irep.reps[insn.block_index], pending[1])
          end
          pending = nil
        end
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

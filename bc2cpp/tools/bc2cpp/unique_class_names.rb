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
    # Modules the closed world includes into Object (build_registry records
    # `class Object; include RGSS; end` as "Object::RGSS", which is ::RGSS).
    attr_accessor :object_mixins
  end

  module_function

  def resolve(name, owner)
    canonical = UniqueClassNames.table&.[](name)
    return nil unless canonical && owner

    scope = canonical.delete_suffix("::#{name}")
    site = owner.to_s.delete_suffix('.singleton')
    lexical = site == scope || site.start_with?("#{scope}::")
    mixins = Array(UniqueClassNames.object_mixins).map { |mixin| mixin.delete_prefix('Object::') }
    lexical || mixins.include?(scope) ? canonical : nil
  end

  def analyze(ireps, root_label, native_paths, foreign_paths)
    return {} unless native_paths && foreign_paths

    paths = bytecode_class_paths(ireps, root_label)
    assigned = Set.new
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        case insn.op
        when 'SETCONST' then assigned << insn.args[/\A(\S+)/, 1]
        when 'SETMCNST' then assigned << insn.args[/::(\S+)/, 1]
        when 'SEND', 'SEND0', 'SSEND', 'SSEND0', 'SENDB', 'SSENDB', 'LOADSYM'
          return {} if insn.args.match?(StableClassConstants::DYNAMIC_MUTATION)
        end
        return {} if insn.args.match?(/:const_missing\b/)
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
    paths.each_with_object({}) do |(name, defs), out|
      next unless defs.size == 1 && defs.first.is_a?(String) && defs.first.include?('::')
      next if defs.first.split('::').any? { |segment| assigned.include?(segment) || foreign.include?(segment) }

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
      BINDING_CALLS.each do |pattern|
        source.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          segment = match[0]
          names = segment.scan(/"([A-Z]\w*)"/).flatten | segment.scan(/MRB_SYM[A-Z_]*\(\s*(\w+)\s*\)/).flatten
          under = segment.match(UNDER_DEFINITION)
          names.each do |name|
            var = under && (under[2] || under[3]) == name ? under[1] : nil
            out[name] << [source, match.begin(0), var]
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
          reg, sym = insn.args.split(/\s+/, 3)
          name = sym.delete_prefix(':')
          outer = outer_writer(irep, idx, reg)
          full = case outer&.op
                 when 'LOADNIL' then namespace ? "#{namespace}::#{name}" : name
                 when 'OCLASS' then name
                 else :unknown
                 end
          paths[name] << full
          seen << [label, idx]
          pending = [reg, full, idx]
        when 'EXEC'
          reg, ref = insn.args.split(/\s+/, 3)
          if pending && pending[0] == reg && pending[2] == idx - 1 && pending[1].is_a?(String)
            walk.call(irep.reps[ref[/I\[(\d+)\]/, 1].to_i], pending[1])
          end
          pending = nil
        end
      end
    end
    walk.call(root_label, nil)
    ireps.each do |label, irep|
      irep.instructions.each_with_index do |insn, idx|
        next unless %w[CLASS MODULE].include?(insn.op) && !seen.include?([label, idx])

        paths[insn.args[/:(\S+)/, 1]] << :unknown
      end
    end
    paths
  end

  def outer_writer(irep, idx, reg)
    (idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      next if %w[EXT1 EXT2 EXT3].include?(insn.op)
      return insn if insn.args[/\A(R\d+)/, 1] == reg
    end
    nil
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

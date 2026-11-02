# frozen_string_literal: true

require_relative 'main_roots'
require_relative 'static_dispatch_registrations'
require_relative 'core_native_candidates'

module MainReachability
  # These expose bodies or dispatch from names not bounded by this name closure.
  REFLECTION = (MainRoots::REFLECTION | Set['const_get']).freeze
  Result = Struct.new(:labels, :dead_keys, :names, :refusals, :notes, keyword_init: true)

  module_function

  def analyze(ireps, definitions, roots, native_paths: [], prunable_keys: Set.new)
    methods = definitions.values.flatten.filter_map do |definition|
      label = definition.irep || definition.copy_irep
      next unless label

      definition.dup.tap { |copy| copy.irep = label }
    end
    body_names = Hash.new { |h, k| h[k] = Set.new }
    methods.each { |d| body_names[d.irep] << d.name.to_s }
    parent = {}
    ireps.each_value { |irep| irep.reps.each { |child| parent[child] = irep.label } }
    groups = Hash.new { |h, k| h[k] = [] }
    ireps.each_value do |irep|
      owner = irep.label
      owner = parent[owner] while owner && !body_names.key?(owner)
      groups[owner] << irep
    end
    names = roots.names | StaticDispatchRegistrations::ALWAYS_DYNAMIC.to_set | Set['initialize']
    native_impls = roots.functions | roots.names
    # Existing named-call roots survive independently of the selected host. Only the
    # checked table-omission proof authorizes a body's removal by this pass.
    methods.each { |d| names << d.name.to_s unless prunable_keys.include?("#{d.owner}##{d.name}") }
    definitions.values.flatten.each { |d| names << d.name.to_s if d.copy_irep }
    native_refusals = []
    fragments = Set.new
    macros = StaticDispatchRegistrations.naming_macros(native_paths)
    native_paths.each do |path|
      text = File.binread(path).gsub(CoreNativeCandidates::ENTRY_NAME) { "#{Regexp.last_match(1)}#{' ' * Regexp.last_match(2).size}" }
      text.scan(/[\w$]+_impl\b/) { |symbol| native_impls << symbol }
      StaticDispatchRegistrations.native_name_tokens(text, names, macros)
      native_refusals.concat(unresolved_native_lookups(path, text)) unless roots.native_paths&.include?(File.realpath(path))
    end
    names.each { |name| fragments << name if name.match?(StaticDispatchRegistrations::FRAGMENT) }
    # Direct entry wrappers can call an implementation without spelling its Ruby name.
    methods.each do |d|
      names << d.name.to_s if native_impls.include?("#{CoreNativeCandidates.cpp_name(d.owner, d.name)}_impl")
    end
    reached = Set.new
    refusals = roots.refusals + native_refusals
    notes = []
    scan = lambda do |body|
      groups.fetch(body, []).each do |irep|
        reached << irep.label
        own_names = body ? body_names.fetch(body) : [nil]
        own_names.each { |own| lookup_names(irep, own, names, fragments) }
        BytecodeIR.for(irep).each_source do |insn, index|
          if BytecodeIR::Ops::SEND.include?(insn.op) && REFLECTION.include?(insn.sym.to_s)
            literal_names = Set.new
            unsafe = StaticDispatchSymbolUses::INTROSPECTION_SENDS.include?(insn.sym) ||
                     %w[eval instance_eval instance_exec class_eval module_eval class_exec module_exec binding const_get].include?(insn.sym)
            if !unsafe && StaticDispatchSymbolUses.literal_arguments(irep, BytecodeIR.for(irep), index, insn, literal_names)
              names.merge(literal_names)
            else
              reason = "#{irep.file}:#{insn.lineno}: #{insn.sym} requires named-call roots"
              if CoreDefs.core_source?(irep.file)
                notes << reason
              else
                refusals << reason
              end
            end
          end
        end
      end
    end
    scan.call(nil)
    pending = body_names.keys.to_set
    loop do
      live = pending.select do |body|
        body_names[body].any? { |name| names.include?(name) }
      end
      break if live.empty?

      live.each { |body| pending.delete(body); scan.call(body) }
    end
    if refusals.any?
      return Result.new(labels: ireps.keys.to_set, dead_keys: Set.new, names: names, refusals: refusals.uniq, notes: notes.uniq)
    end

    dead = methods.reject { |d| reached.include?(d.irep) }.map { |d| "#{d.owner}##{d.name}" }.to_set & prunable_keys
    Result.new(labels: reached, dead_keys: dead, names: names, refusals: [], notes: notes.uniq)
  end

  def lookup_names(irep, own, names, fragments)
    BytecodeIR.for(irep).each_source do |insn, _index|
      # Definitions and aliases store a body; executing it is a separate graph edge.
      next if CoreNativeCandidates::DEF_OPS.include?(insn.op) || insn.op == :ALIAS

      names << insn.sym.to_s if insn.sym
      names << own if own && insn.op == :SUPER
      implicit = IMPLICIT_DISPATCH_NAMES[insn.op]
      names << implicit if implicit
    end
    irep.pool.grep(String).each do |value|
      names << value if value.match?(StaticDispatchRegistrations::IDENT)
      fragments << value if value.match?(StaticDispatchRegistrations::FRAGMENT)
    end
  end

  # The pinned VM's primitive dispatch is modeled by ALWAYS_DYNAMIC and its presym uses.
  # Other native sources may not dispatch from a name this source inventory cannot bound.
  def unresolved_native_lookups(path, text)
    core = File.expand_path('../../3rd/mruby', __dir__)
    return [] if File.expand_path(path).start_with?("#{core}/")

    clean = StaticDispatchRegistrations.strip_c_comments(text)
    refusals = []
    clean.to_enum(:scan, /\b(?:#{MainRoots::BRIDGES.join('|')})\b/).each do
      token = Regexp.last_match
      opening = token.end(0)
      opening += 1 while clean[opening]&.match?(/\s/)
      call = clean[opening] == '(' && NativeOwnerMap.call_args(clean, opening)
      if call && NativeOwnerMap.definition?(clean, token.begin(0), call.last)
        next
      end
      name = call && call.first[MainRoots::NAME_ARGUMENT.fetch(token[0], 2)]
      literal = name && NativeOwnerMap.name_of(name)
      if !literal && name&.match?(/\Amrb_intern_(?:lit|cstr)\s*\(/)
        args = NativeOwnerMap.call_args(name, name.index('('))
        literal = args && NativeOwnerMap.name_of(args.first[1])
      end
      if literal && MainRoots::REFLECTION.include?(literal)
        refusals << "#{path}: native call to reflective method #{literal}"
      elsif !literal
        refusals << "#{path}: unresolved native lookup through #{token[0]}"
      end
    end
    refusals
  end
end

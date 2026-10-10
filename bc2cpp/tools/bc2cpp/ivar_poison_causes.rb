# frozen_string_literal: true

# IVAR_POISON_CAUSES (ADR 0380): diagnostic only. ClassLayout.analyze joins every SETIV of an ivar; one store whose
# value trace_new_target cannot name poisons the ivar to UNKNOWN (the `== ivar-class candidates split: OPAQUE ==` list).
# This classifies each unresolved store by what produced its value and buckets every OPAQUE ivar by those causes, so the
# poisoned ivars can be counted and the next rule chosen by yield. It never feeds a fact back: ClassLayout hands it the
# stores it already read, after the fixed point.
#
# Atoms (one per reaching definition of the stored register; several joined with `+` under `join`):
#   param:ctor / param:method   an incoming mandatory argument of `initialize` / of any other method
#   param:optional              an optional, rest, keyword or block parameter
#   call:core / :project / :mixed / :unregistered   a call result; every definition native, Ruby, or both
#   integer / numeric / bool / symbol / nil / self  a literal (LOADI*, LOADL, true/false, Symbol, nil, self)
#   string / hash / array / range / proc / class_body   other literal producers
#   getiv / getidx / getconst / upvar / gv / cv     the remaining value producers
#   op:<name>                    arithmetic or a comparison on operands the flow did not type
#   unreadable:<cause>           reaching definitions refused (BytecodeIR's refusal cause)
module IvarPoisonCauses
  LITERALS = {
    'LOADT' => 'bool', 'LOADF' => 'bool', 'LOADTRUE' => 'bool', 'LOADFALSE' => 'bool', 'LOADL' => 'numeric',
    'LOADSYM' => 'symbol', 'STRING' => 'string', 'STRCAT' => 'string', 'LOADNIL' => 'nil', 'LOADSELF' => 'self',
    'GETIDX' => 'getidx', 'GETIDX0' => 'getidx', 'GETUPVAR' => 'upvar', 'GETGV' => 'gv', 'GETCV' => 'cv',
    'LAMBDA' => 'proc', 'BLOCK' => 'proc', 'METHOD' => 'proc', 'HASH' => 'hash', 'ARRAY' => 'array', 'ARRAY2' => 'array',
    'RANGE_INC' => 'range', 'RANGE_EXC' => 'range', 'GETCONST' => 'getconst', 'GETMCNST' => 'getconst',
    'OCLASS' => 'getconst', 'CLASS' => 'class_body', 'MODULE' => 'class_body', 'EXEC' => 'class_body'
  }.freeze
  CALLS = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB SUPER ARYCAT ARYPUSH].freeze
  # A literal that is an immediate (or nil): no registry class names it, so no class hint can ever hold it.
  IMMEDIATE_ATOMS = %w[integer numeric bool symbol nil].freeze
  # Buckets in priority order: an ivar is counted once, in the first bucket one of its unresolved stores falls in.
  BUCKETS = [
    ['immediate', 'every unresolved store is an Integer/Float/true/false/Symbol/nil literal (no class name exists)',
     ->(atoms) { atoms.all? { |a| IMMEDIATE_ATOMS.include?(a) } }],
    ['parameter', 'an unresolved store is an incoming argument', ->(atoms) { atoms.any? { |a| a.start_with?('param:') } }],
    ['project_call', 'an unresolved store is the result of a Ruby-defined method',
     ->(atoms) { atoms.any? { |a| a.start_with?('call:project') || a.start_with?('call:mixed') } }],
    ['core_call', 'an unresolved store is the result of a native or unregistered method',
     ->(atoms) { atoms.any? { |a| a.start_with?('call:') } }],
    ['element_read', 'an unresolved store is a Hash/Array element', ->(atoms) { atoms.include?('getidx') }],
    ['ivar_read', 'an unresolved store is another ivar whose class is unknown', ->(atoms) { atoms.include?('getiv') }],
    ['constant', 'an unresolved store is a constant', ->(atoms) { atoms.include?('getconst') }],
    ['arithmetic', 'an unresolved store is an operator on operands the flow did not type',
     ->(atoms) { atoms.any? { |a| a.start_with?('op:') } }],
    ['other_literal', 'a String/Proc/closure/self store', ->(atoms) { (atoms & %w[string proc self upvar gv cv class_body range]).any? }],
    ['unreadable', 'reaching definitions refused', ->(atoms) { atoms.any? { |a| a.start_with?('unreadable') } }]
  ].freeze

  # [cause, detail] for the value `reg` holds at `idx` in `irep`. +method_name+ is the enclosing method's name.
  def self.classify(irep, idx, reg, mand, method_name, registry, depth = 0)
    why = {}
    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s, refusal: why, through_handlers: true)
    return ['unreadable', why[:cause].to_s] if defs.nil? || defs.empty?

    parts = defs.map { |d| classify_definition(irep, d, mand, method_name, registry, depth) }.uniq
    parts.size == 1 ? parts.first : ['join', parts.map { |c, d| d ? "#{c}(#{d})" : c }.sort.join('+')]
  end

  def self.classify_definition(irep, defn, mand, method_name, registry, depth)
    if defn.entry?
      pos = defn.reg.to_i
      return ['self', nil] if pos.zero?
      return [(method_name == 'initialize' ? 'param:ctor' : 'param:method'), "arg#{pos}"] if pos.between?(1, mand)

      return ['param:optional', "r#{pos}"]
    end
    insn = irep.instructions[defn.index]
    op = insn.op
    if op == 'MOVE'
      return ['unreadable', 'move'] if depth > 6 || insn.regs[1].nil?

      return classify(irep, defn.index, insn.regs[1], mand, method_name, registry, depth + 1)
    end
    return ['integer', nil] if op.start_with?('LOADI')
    return ['getiv', insn.ivar.to_s] if op == 'GETIV'
    return [LITERALS.fetch(op), nil] if LITERALS.key?(op)
    return ["call:#{call_kind(insn.sym, registry)}", insn.sym.to_s] if CALLS.include?(op) && insn.sym

    ["op:#{op.downcase}", nil]
  end

  def self.call_kind(name, registry)
    defs = registry[name] || []
    return 'unregistered' if defs.empty?

    natives = defs.count { |d| d.owner == '<native>' }
    return 'core' if natives == defs.size

    natives.zero? ? 'project' : 'mixed'
  end

  # The atoms of one classified store (the parts of a join, each reduced to its kind).
  def self.atoms(cause, detail)
    return [cause] unless cause == 'join'

    detail.to_s.split('+').map { |part| part.sub(/\(.*/, '') }
  end

  # Unresolved stores of one ivar -> [bucket name, all atoms]. A nil arm alone says nothing about a class, so it is
  # dropped unless it is all there is.
  def self.bucket(stores)
    atoms = stores.flat_map { |cause, detail| atoms(cause, detail) }.uniq
    atoms -= ['nil'] unless atoms == ['nil']
    BUCKETS.each { |name, _why, test| return [name, atoms] if test.call(atoms) }
    ['other', atoms]
  end

  # Report lines for the OPAQUE ivars. +store_log+ is ClassLayout's (owner, label, idx) -> [ivar, found, irep, reg, mand,
  # method name]; +unknown+ the "Owner#@ivar" names of the OPAQUE list.
  def self.report(store_log, unknown, registry)
    stores = Hash.new { |h, k| h[k] = [] }
    store_log.each do |(owner, _label, idx), (ivar, found, irep, reg, mand, method_name)|
      next if found

      stores["#{owner}#@#{ivar}"] << classify(irep, idx, reg, mand, method_name, registry)
    end
    buckets = Hash.new { |h, k| h[k] = [] }
    anyc = Hash.new(0)
    unknown.each do |name|
      rows = stores[name]
      bucket, atoms = rows.empty? ? ['no_unresolved_store', []] : bucket(rows)
      buckets[bucket] << name
      atoms.each { |a| anyc[a] += 1 }
    end
    lines = []
    buckets.sort_by { |name, names| [-names.size, name] }.each do |name, names|
      why = BUCKETS.find { |n, *| n == name }&.at(1)
      lines << "  OPAQUE_CAUSE #{name} #{names.size}#{why ? " -- #{why}" : ''}"
      names.sort.first(3).each { |n| lines << "    e.g. #{n}" }
    end
    anyc.sort_by { |a, n| [-n, a] }.each { |atom, n| lines << "  OPAQUE_ATOM #{atom} #{n}" }
    [lines, buckets.transform_values(&:sort)]
  end
end

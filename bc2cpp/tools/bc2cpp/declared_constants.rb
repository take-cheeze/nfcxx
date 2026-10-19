# frozen_string_literal: true

require 'set'
require_relative 'core_hierarchy_sigs'
require_relative 'integer_constants'
require_relative 'irep_scans'
require_relative 'native_sigs'

# DECLARED_CONSTANT_CHECK (docs/adr/0455): RBS constant declarations, checked at every assignment.
#
#   FOO: Integer        every SETCONST/SETMCNST binding the bare name FOO evaluates to one Fixnum: an integer literal,
#                       a proven or declared Integer constant, or ADD/SUB/MUL/DIV/ADDI/SUBI of those whose exact value
#                       fits the narrowest Fixnum. Feeds INTEGER_CONSTANT_PROOF (bare-name keyed, as that proof is).
#   TABLE: Array[...]   the declared constant's one assignment is an Array (an ARRAY literal, or a source the array
#                       proofs accept, `.freeze` included). Feeds CONST_CONTAINER.
#   TABLE: Array[T]     as above, and the assignment is a frozen `[...]` literal whose every element proves T (Integer,
#                       Float, String or Symbol). Feeds the element bound for the bare name, when only this assignment
#                       binds that name.
#   OBJ: C              the one assignment is exactly `C.new(...)` (trace_new_target). Feeds CONST_CONTAINER.
#
# Errors (TC1011, a build abort): no assignment in the program, a second assignment of the declared name
# (reassignment refuses), an assignment whose value does not prove the declared type, an assignment control can jump
# onto (`X = c || 1`). Infos (checked, no fact): the bare name is also bound outside the program (native, foreign Ruby,
# a class or module of that name) or, for Integer, by another assignment that does not prove.
module DeclaredConstants
  Entry = Struct.new(:name, :bare, :kind, :cls, :text, :loc, :elem, keyword_init: true)
  ELEMENT_CLASSES = %w[Integer Float String Symbol].freeze
  Result = Struct.new(:integer_names, :containers, :elements, :diagnostics, :report, :locs, keyword_init: true)
  CODE = 'TC1011'
  KILL_ENV = 'BC2CPP_DECLARED_CONSTANTS'

  # Stands for "every name" (no outside-world scan).
  module AllNames
    def self.include?(_name) = true
  end

  module_function

  def enabled?
    ENV[KILL_ENV] != '0'
  end

  # Entries for the constant declarations of the signature files (RbsSignatures.load notes them as TC1005 only).
  def load(files, display_root, known_owners)
    return [] unless enabled? && files && !files.empty?

    require 'rbs'
    files.flat_map do |file|
      rel = display_root ? file.sub(%r{\A#{Regexp.escape(display_root)}/?}, '') : file
      _buf, _dirs, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: rel, content: File.read(file)))
      # Native declarations are checked by their own generators, not as the program's constants.
      collect(decls.reject { |decl| NativeSigs.native?(decl) }, [], rel, known_owners)
    rescue RBS::ParsingError
      [] # RbsSignatures.load already reports the file (TC1002)
    end
  end

  def collect(decls, scope, rel, known_owners)
    decls.flat_map do |decl|
      case decl
      when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
        inner = scope + [decl.name.to_s.delete_prefix('::')]
        collect(decl.members.grep(RBS::AST::Declarations::Base), inner, rel, known_owners)
      when RBS::AST::Declarations::Constant
        name = (scope + [decl.name.to_s.delete_prefix('::')]).join('::')
        entry_for(name, decl, rel, known_owners) || []
      else []
      end
    end
  end

  def entry_for(name, decl, rel, known_owners)
    type = decl.type
    return nil unless type.is_a?(RBS::Types::ClassInstance)

    cls = type.name.to_s.delete_prefix('::')
    kind = if cls == 'Integer' && type.args.empty? then :int
           elsif cls == 'Array' then :array
           elsif type.args.empty? && known_owners.include?(cls) then :class
           end
    return nil unless kind

    elem = element_class(type) if kind == :array
    l = decl.location
    loc = RbsSignatures::Loc.new(rel, l ? l.start_line : 1, l ? l.start_column + 1 : 1)
    Entry.new(name: name, bare: name.split('::').last, kind: kind, cls: kind == :int ? 'Integer' : cls,
              text: type.to_s, loc: loc, elem: elem)
  end

  # The element class of `Array[T]` when T is one of ELEMENT_CLASSES; nil for any other argument (no element fact).
  def element_class(type)
    arg = type.args.first
    return nil unless type.args.size == 1 && arg.is_a?(RBS::Types::ClassInstance) && arg.args.empty?

    name = arg.name.to_s.delete_prefix('::')
    ELEMENT_CLASSES.include?(name) ? name : nil
  end

  # `sites`: the registry's constant_assignment_sites ({name:, irep:, idx:, reg:}); `poisoned` the bare names bound
  # outside the program's bytecode (nil: unknown); `container_constants` is read for trace_new_target only. The
  # proven integer constants are not needed: the evaluator re-derives every binding it reads.
  def check(entries, ireps, registry, sites, _integer_constants, poisoned, container_constants, display_root,
            plus_safe:, range_safe:)
    result = Result.new(integer_names: Set.new, containers: {}, elements: {}, diagnostics: [], report: [],
                        locs: entries.map(&:loc))
    return result if entries.empty?

    qualified_at = sites.to_h { |s| [[s[:irep], s[:idx]], s[:name]] }
    bindings = Hash.new { |h, k| h[k] = [] }
    class_named = Set.new
    ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        case insn.op
        when 'SETCONST', 'SETMCNST'
          bare = insn.op == 'SETCONST' ? insn.const_name : insn.mcnst_name
          bindings[bare] << [irep, idx, insn, qualified_at[[irep.label, idx]]] if bare
        when 'CLASS', 'MODULE'
          class_named << insn.sym_token
        end
      end
    end
    # Without the outside-world scan every name may be bound elsewhere: the evaluator then reads literals only.
    blocked = poisoned ? poisoned | class_named : nil
    evaluator = Evaluator.new(bindings, blocked || AllNames)
    # The same sum names const_rows reports (ARRAY_SUM), so a declared `X: Array` accepts exactly what the rows type.
    sums = array_sum_names(ireps, sites, registry, container_constants, plus_safe, range_safe: range_safe)
    rel = ->(path) { display_root ? path.to_s.sub(%r{\A#{Regexp.escape(display_root)}/?}, '') : path.to_s }
    entries.each do |entry|
      diag = lambda do |severity, where, message|
        file, line, col = where || [entry.loc.file, entry.loc.line, entry.loc.col]
        result.diagnostics << { file: file, line: line, col: col, severity: severity, code: CODE,
                                message: "#{entry.name}: #{entry.text} (#{entry.loc.file}:#{entry.loc.line}): " \
                                         "#{message}" }
      end
      own, unresolved = bindings[entry.bare].partition { |_i, _x, _n, q| q == entry.name }
      unresolved = unresolved.select { |_i, _x, insn, q| q.nil? || insn.op == 'SETMCNST' }
      errors = result.diagnostics.size
      diag.call('error', nil, 'no assignment of this constant in the program') if own.empty?
      own.drop(1).each do |irep, idx, insn,|
        diag.call('error', [rel.call(irep.file), insn.lineno, 1], 'reassigned (a declared constant is assigned once)')
      end
      unresolved.each do |irep, _idx, insn,|
        diag.call('error', [rel.call(irep.file), insn.lineno, 1],
                  "`#{entry.bare}` is assigned in a scope the checker does not resolve; it may reassign this constant")
      end
      own.first(1).each do |irep, idx, insn,|
        why = site_failure(entry, irep, idx, insn, evaluator, registry, container_constants, sums)
        diag.call('error', [rel.call(irep.file), insn.lineno, 1], why) if why
      end
      failed = result.diagnostics.size > errors
      fact = !failed && feed(entry, bindings, poisoned, class_named, evaluator, result, diag)
      status = if failed then 'FAILED'
               elsif fact then 'checked, fact'
               else 'checked, no fact'
               end
      result.report << "  DECLARED_CONST #{entry.name}: #{entry.text}: #{status}"
    end
    result
  end

  # Records the fact for a checked entry; true when it was fed.
  def feed(entry, bindings, poisoned, class_named, evaluator, result, diag)
    case entry.kind
    when :int
      if poisoned.nil? || poisoned.include?(entry.bare) || class_named.include?(entry.bare)
        diag.call('info', nil,
                  "`#{entry.bare}` is also bound outside the program's bytecode; no INTEGER_CONSTANT_PROOF fact")
        return false
      end
      other = bindings[entry.bare].find { |irep, idx, insn,| evaluator.binding_value(irep, idx, insn).nil? }
      if other
        diag.call('info', nil, "another `#{entry.bare}` (#{other[3] || 'unresolved scope'}, line #{other[2].lineno}) " \
                               'does not prove Integer; no INTEGER_CONSTANT_PROOF fact')
        return false
      end
      result.integer_names << entry.bare
    else
      result.containers[entry.name] = entry.kind == :array ? 'Array' : entry.cls
      element_fact(entry, bindings, poisoned, class_named, result, diag) if entry.elem
    end
    true
  end

  # The element bound is keyed by the bare name, as the reader resolves GETCONST, so it is recorded only when no
  # other binding in the program or the outside world can supply that name.
  def element_fact(entry, bindings, poisoned, class_named, result, diag)
    if poisoned.nil? || poisoned.include?(entry.bare) || class_named.include?(entry.bare) ||
       !bindings[entry.bare].all? { |_i, _x, _n, q| q == entry.name }
      diag.call('info', nil, "`#{entry.bare}` is also bound elsewhere; no element fact for its Array[#{entry.elem}]")
      return
    end

    result.elements[entry.bare] = entry.elem
  end

  def site_failure(entry, irep, idx, insn, evaluator, registry, container_constants, sums)
    if evaluator.entry_site?(irep, insn)
      return 'control can jump onto the assignment, so its value is not one expression'
    end

    src = insn.regs.last
    return 'the assigned register is unknown' unless src

    case entry.kind
    when :int
      evaluator.binding_value(irep, idx, insn).nil? ? 'the assigned value is not a proven Fixnum expression' : nil
    when :array
      return element_failure(entry, irep, idx, src, registry, container_constants) if entry.elem

      traced = trace_new_target(irep, idx, src, nil, 0, nil, registry: registry,
                                                             container_constants: container_constants)
      return nil if traced == 'Array' || proven_array_source_scan(irep, idx, src, registry)
      return nil if frozen_array_source?(irep, idx, src, registry, container_constants)
      # ARRAY_SUM: the name is a sum in every assignment (array_sum_names), so this site is one too.
      return nil if sums.key?(entry.name)

      'the assigned value is not a proven Array'
    when :class
      traced = trace_new_target(irep, idx, src, nil, 0, nil, registry: registry,
                                                             container_constants: container_constants)
      return nil if traced == entry.cls

      "the assigned value is #{traced ? "a #{traced}" : 'not a proven instance'}, not exactly #{entry.cls}"
    end
  end

  # `Array[T]`: a frozen `[...]` literal (ARRAY, not ARRAY2 / ARYPUSH) whose element registers each prove exactly T
  # at the literal. Frozen, so no later write can change the element classes read back.
  def element_failure(entry, irep, idx, src, registry, container_constants)
    return 'the declared element type needs a frozen array literal (`[...].freeze`)' unless
      frozen_array_source?(irep, idx, src, registry, container_constants)

    literal_index, literal = literal_writer(irep, idx, src)
    return 'the frozen array is not an array literal' unless literal&.op == 'ARRAY' && literal.uint_operand

    types = BytecodeIR::Types.new(irep)
    want = Set[entry.elem.to_sym]
    bad = (0...literal.uint_operand).find do |offset|
      fact = types.fact_at(literal_index, (literal.reg.to_i + offset).to_s)
      fact.nil? || fact.classes != want
    end
    bad && "element #{bad} of the literal is not proven #{entry.elem}"
  end

  # The nearest writer of +reg+ before +idx+ that is not `.freeze`, as [index, instruction], or nil.
  def literal_writer(irep, idx, reg)
    irep.walk_writers(idx - 1, reg.to_s, follow_moves: true) do |insn, j, _cur|
      next IrepScans::KEEP if insn.op == 'SEND0' && insn.sym == 'freeze'

      [j, insn]
    end
  end

  # `[...].freeze` / `X.dup.freeze`: Object#freeze answers its receiver (no program `freeze`).
  def frozen_array_source?(irep, idx, reg, registry, container_constants)
    return false if (registry['freeze'] || []).any?(&:irep)

    irep.walk_writers(idx - 1, reg.to_s, follow_moves: true) do |insn, j, cur|
      next false unless insn.op == 'SEND0' && insn.sym == 'freeze'

      trace_new_target(irep, j, cur, nil, 0, nil, registry: registry,
                                                  container_constants: container_constants) == 'Array' ||
        !proven_array_source_scan(irep, j, cur, registry).nil?
    end || false
  end

  # ARRAY_SUM (type_facts const_rows): `(A + B).freeze` whose two operands both prove Array. Array#+ answers a fresh
  # Array (or raises), so the sum is an Array when `plus_safe` holds (no program or foreign `+` or `freeze` that can
  # answer something else; see TypeFacts.array_sum_safe?). An operand is proven by trace_new_target over `containers`
  # (which carries the sum constants already proven, see array_sum_names), by the array scan, by a literal Range's
  # to_a (range_to_a_source?, only when `range_safe`), or by a nested sum.
  SUM_MAX_DEPTH = 8

  # CodeGen#declared_array_plus_safe?: no Ruby `+` on Array (or a subclass), and Array is not prepended or mixed into
  # by an unknown module. The declared check runs before CodeGen is built, so the predicate lives here; CodeGen
  # delegates to it and the two cannot drift.
  def array_plus_safe?(registry, superclass_of, prepended_modules, unknown_mixins)
    defs = registry['+'] || []
    return false unless defs.any? { |d| d.owner == '<native>' && d.irep.nil? }
    return false if defs.any? { |d| d.owner == 'Array' }
    return false if !Array(prepended_modules['Array']).empty? || unknown_mixins.include?('Array')

    defs.none? { |d| d.irep && strict_ancestors(superclass_of, d.owner).include?('Array') }
  end

  def strict_ancestors(superclass_of, klass)
    seen = Set.new
    superclass = superclass_of[klass]
    superclass = superclass_of[superclass] while superclass.is_a?(String) && seen.add?(superclass)
    seen
  end

  # The array sum proof's full precondition (array_sum_names' `plus_safe`): array_plus_safe? and no Ruby `freeze`.
  def array_sum_safe?(registry, superclass_of, prepended_modules, unknown_mixins)
    array_plus_safe?(registry, superclass_of, prepended_modules, unknown_mixins) &&
      (registry['freeze'] || []).none?(&:irep)
  end

  # Range#to_a (mruby-range-ext mrblib/range.rb) answers a fresh Array: `__num_to_a` for Integer endpoints, else
  # Enumerable#to_a (`super`), which calls Range#each, whose String arm calls String#upto. Each of those must be the
  # stock definition, so no Ruby definition of these names may sit on Range, Enumerable or String, or on a module
  # mixed into them, and none of the three may have a prepend or an unresolved mixin. Scoped to those owners: a
  # program-wide name check would refuse on the engine's own `each` methods (lcf.rb, game.rb).
  # CodeGen#range_to_a_safe? delegates here, so the declared check and the rows read one predicate.
  RANGE_TO_A_NAMES = %w[to_a each upto __num_to_a].freeze
  RANGE_TO_A_OWNERS = %w[Range Enumerable String].freeze

  def range_to_a_safe?(registry, included_modules, prepended_modules, unknown_mixins)
    touched = RANGE_TO_A_OWNERS + RANGE_TO_A_OWNERS.flat_map { |owner| Array(included_modules[owner]) }
    mixins_resolved = touched.none? do |owner|
      unknown_mixins.include?(owner) || !Array(prepended_modules[owner]).empty?
    end
    defined_on_touched = RANGE_TO_A_NAMES.any? do |name|
      (registry[name] || []).any? { |d| d.irep && touched.include?(d.owner) }
    end
    mixins_resolved && !defined_on_touched
  end

  def array_sum_source?(irep, idx, reg, registry, containers, plus_safe, owner: nil, depth: 0, range_safe: false)
    return false unless plus_safe && depth < SUM_MAX_DEPTH

    j, insn = sum_writer(irep, idx, reg)
    return false unless insn&.op == 'ADD' && insn.reg && insn.paren_reg

    operand = lambda do |r|
      proven_array_value?(irep, j, r, registry, containers, plus_safe, owner, depth + 1, range_safe: range_safe)
    end
    operand.call(insn.reg) && operand.call(insn.paren_reg)
  end

  def proven_array_value?(irep, idx, reg, registry, containers, plus_safe, owner, depth, range_safe: false)
    return true if trace_new_target(irep, idx, reg, registry: registry, container_constants: containers,
                                                    owner: owner) == 'Array'
    return true if proven_array_source_scan(irep, idx, reg, registry)
    return true if range_safe && range_to_a_source?(irep, idx, reg)

    array_sum_source?(irep, idx, reg, registry, containers, plus_safe, owner: owner, depth: depth,
                                                                        range_safe: range_safe)
  end

  # `(lo..hi).to_a` over two literal endpoints of one kind, a String literal (STRING) or an Integer literal (LOADI*):
  # Range#to_a answers a fresh Array or raises (CodeGen#range_to_a_safe? holds the stock-method condition). The
  # receiver of the to_a is the dominating RANGE_INC / RANGE_EXC, and each endpoint is the dominating writer of its
  # register before that range instruction.
  LITERAL_INTEGER_OP = /\ALOADI(?:8|16|32|NEG|__1|_[0-7])\z/

  def range_to_a_source?(irep, idx, reg)
    j, call, recv = dominating_writer(irep, idx, reg)
    return false unless call&.op == 'SEND0' && call.sym == 'to_a'

    k, range = dominating_writer(irep, j, recv)
    return false unless range && %w[RANGE_INC RANGE_EXC].include?(range.op) && range.reg

    lo = literal_kind(irep, k, range.reg)
    hi = literal_kind(irep, k, (range.reg.to_i + 1).to_s)
    !lo.nil? && lo == hi
  end

  # The writer of +reg+ before +idx+ that dominates the read, skipping `.freeze` (which answers its receiver):
  # [index, instruction, register holding the value at that index], or nil.
  def dominating_writer(irep, idx, reg)
    irep.walk_dominating_writers(idx - 1, reg.to_s, use: idx, follow_moves: true) do |insn, j, cur|
      next IrepScans::KEEP if insn.op == 'SEND0' && insn.sym == 'freeze'

      [j, insn, cur]
    end
  end

  def literal_kind(irep, idx, reg)
    _j, insn = dominating_writer(irep, idx, reg)
    return nil unless insn
    return :String if insn.op == 'STRING'
    return :Integer if LITERAL_INTEGER_OP.match?(insn.op)

    nil
  end

  # The writer of +reg+ before +idx+ that is not `.freeze`, as [index, instruction], or nil. Dominating: a join between
  # the writer and the read may hold another value, and then there is no single writer to prove.
  def sum_writer(irep, idx, reg)
    irep.walk_dominating_writers(idx - 1, reg.to_s, use: idx, follow_moves: true) do |insn, j, _cur|
      next IrepScans::KEEP if insn.op == 'SEND0' && insn.sym == 'freeze'

      [j, insn]
    end
  end

  # The qualified names whose every assignment is an Array sum, as { name => 'Array' }. A sum over another sum constant
  # counts once that one is proven, so the set only grows and the loop ends when a pass adds nothing. Names already in
  # `containers` (literal or declared) are left to their own proofs.
  def array_sum_names(ireps, sites, registry, containers, plus_safe, range_safe: false)
    return {} unless plus_safe

    by_name = sites.group_by { |s| s[:name] }
    known = {}
    loop do
      merged = containers.merge(known)
      grown = by_name.select do |name, group|
        !known.key?(name) && !containers.key?(name) &&
          group.all? do |s|
            irep = ireps[s[:irep]]
            irep && array_sum_source?(irep, s[:idx], s[:reg], registry, merged, plus_safe, owner: s[:owner],
                                                                                           range_safe: range_safe)
          end
      end
      break if grown.empty?

      grown.each_key { |name| known[name] = 'Array' }
    end
    known
  end

  # ---------------------------------------------------------------------------------------------- report-level owners
  # The owner-scoped proofs below feed TypeFacts const_rows only. The declared check and CodeGen keep their own
  # program-wide predicates, so generated code is unchanged by them.

  # CORE_CONTAINERS: the exact classes whose stock methods the owner proofs cover. Integer and String join them for
  # `freeze` alone (the FREEZE_SELF fact, type_facts freeze_self_type and IntegerConstantRanges): no other owner-scoped
  # proof reads these two classes.
  CORE_CONTAINERS = %w[Array Hash].freeze
  STOCK_PROOF_CLASSES = (CORE_CONTAINERS + %w[Integer String]).freeze

  # Whether a call of +name+ on an exact +klass+ instance (STOCK_PROOF_CLASSES) is mruby's own method. The owners that answer
  # it first are the core ancestors of +klass+ (CoreHierarchySigs: Array, Enumerable, Object, Kernel, BasicObject) and
  # every module mixed into those, transitively. A Ruby definition on one of them, a prepend on one of them, or an
  # unresolved mixin into one of them refuses the proof. A Ruby definition anywhere else (Graphics.freeze, a game
  # class) cannot answer an Array or Hash receiver, so it does not. Scoped to the owners because a program-wide name
  # check refuses on the engine's own methods of the same name.
  def stock_method?(name, klass, registry, included_modules, prepended_modules, unknown_mixins)
    return false unless STOCK_PROOF_CLASSES.include?(klass)

    owners = Set.new(CoreHierarchySigs.ancestors(klass))
    loop do
      grown = owners.flat_map { |owner| Array(included_modules[owner]) }.reject { |m| owners.include?(m) }
      break if grown.empty?

      owners.merge(grown)
    end
    return false if owners.any? { |owner| unknown_mixins.include?(owner) || !Array(prepended_modules[owner]).empty? }

    (registry[name] || []).none? { |d| owners.include?(d.owner) }
  end

  # Whether the value of +reg+ at +idx+ is the result of a `.freeze` (the first writer, past moves, is a SEND0 freeze).
  # A constant whose value is frozen needs the stock freeze proof to be typed by its literal class.
  def frozen_at?(irep, idx, reg)
    found = irep.walk_writers(idx - 1, reg.to_s, follow_moves: true) do |insn, _j, _cur|
      insn.op == 'SEND0' && insn.sym == 'freeze'
    end
    found == true
  end

  # `R.merge(H)` at +idx+: the one-argument SEND `merge` whose receiver proves exactly Hash (a Hash literal, or a constant
  # the containers say is a Hash). Hash#merge answers a fresh Hash (or raises), so the result is a Hash when
  # `merge_safe` (stock_method? on Hash) and `singleton_free` hold: no singleton `merge` can sit on the receiver.
  def hash_merge_source?(irep, idx, reg, registry, containers, merge_safe:, singleton_free:, owner: nil)
    return false unless merge_safe && singleton_free

    j, insn = merge_writer(irep, idx, reg)
    return false unless insn&.op == 'SEND' && insn.sym == 'merge' && insn.argc.to_i == 1 && insn.reg

    # `owner` is the lexical scope of the assignment: a bare constant receiver (`SAVE_MOVABLE.merge`) resolves in it.
    trace_new_target(irep, j, insn.reg, registry: registry, container_constants: containers, owner: owner) == 'Hash'
  end

  # The writer of +reg+ before +idx+ that dominates the read, as [index, instruction], or nil (see sum_writer).
  def merge_writer(irep, idx, reg)
    irep.walk_dominating_writers(idx - 1, reg.to_s, use: idx, follow_moves: true) do |insn, j, _cur|
      [j, insn]
    end
  end

  # The qualified names whose every assignment is a Hash merge, as { name => 'Hash' } (see hash_merge_source?).
  def hash_merge_names(ireps, sites, registry, containers, merge_safe:, singleton_free:)
    return {} unless merge_safe && singleton_free

    by_name = sites.group_by { |s| s[:name] }
    by_name.each_with_object({}) do |(name, group), known|
      next if containers.key?(name)

      proven = group.all? do |s|
        irep = ireps[s[:irep]]
        irep && hash_merge_source?(irep, s[:idx], s[:reg], registry, containers, merge_safe: merge_safe,
                                                                               singleton_free: singleton_free,
                                                                               owner: s[:owner])
      end
      known[name] = 'Hash' if proven
    end
  end

  # Fixnum intervals of constant expressions over integer literals and other constants. A constant read is keyed by
  # its bare name, as INTEGER_CONSTANT_PROOF is (lexical lookup is not modelled), so it stands for the union of every
  # binding of that name: all must evaluate, and none may be bound outside the bytecode (`blocked`). An interval, not a
  # value, so `TEXT_COLOR` bound to 0 in one class and 1 in another still reads as a Fixnum.
  class Evaluator
    OPS = %w[ADD SUB MUL DIV ADDI SUBI].freeze
    MAX_DEPTH = 16
    MIN = -1_073_741_824 # CodeGen::LOADI_FIXNUM_MIN / MAX: the narrowest Fixnum of any shipped target
    MAX = 1_073_741_823

    def initialize(bindings, blocked)
      @bindings = bindings
      @blocked = blocked
      @entries = {}
      @memo = {}
    end

    def entry_site?(irep, insn)
      (@entries[irep.label] ||= IntegerConstants.const_entry_addrs(irep)).include?(insn.addr)
    end

    # [lo, hi] of what one binding stores, or nil.
    def binding_value(irep, idx, insn, visiting = Set.new)
      return nil if entry_site?(irep, insn)

      src = insn.regs.last
      src && value(irep, idx, src, visiting, 0)
    end

    # The union over every binding of bare `name`, or nil (also for a cycle, which is not memoized).
    def name_value(name, visiting)
      return @memo[name] if @memo.key?(name)
      return nil if visiting.include?(name) || @blocked.include?(name)

      sites = @bindings[name]
      return nil if sites.empty?

      ranges = sites.map { |irep, idx, insn,| binding_value(irep, idx, insn, visiting | [name]) }
      return nil if ranges.any?(&:nil?)

      @memo[name] = [ranges.map(&:first).min, ranges.map(&:last).max]
    end

    def value(irep, idx, reg, visiting, depth)
      return nil if depth > MAX_DEPTH

      entries = @entries[irep.label] ||= IntegerConstants.const_entry_addrs(irep)
      irep.walk_writers(idx - 1, reg.to_s, barrier: ->(insn, _cur) { entries.include?(insn.addr) },
                                           follow_moves: true) do |insn, j, cur|
        if insn.op.start_with?('LOADI')
          v = loadi(insn)
          next v && fixnum([v, v])
        end

        case insn.op
        when 'GETCONST' then name_value(insn.const_name, visiting)
        when 'GETMCNST' then name_value(insn.mcnst_name, visiting)
        when *OPS then arithmetic(irep, j, insn, cur, visiting, depth)
        end
      end
    end

    # Integer operands take vm.c's integer arms of these opcodes (no method lookup), so a redefined Integer#+ is
    # never called; DIV is Integer#/ (floored), and a divisor interval holding 0 is refused (ZeroDivisionError).
    def arithmetic(irep, j, insn, cur, visiting, depth)
      left = value(irep, j, cur, visiting, depth + 1)
      right = if %w[ADDI SUBI].include?(insn.op)
                (i = insn.imm_operand&.to_i) && [i, i]
              elsif insn.regs[1]
                value(irep, j, insn.regs[1], visiting, depth + 1)
              end
      return nil unless left && right

      corners = ->(&f) { left.product(right).map { |a, b| f.call(a, b) } }
      result = case insn.op
               when 'ADD', 'ADDI' then [left[0] + right[0], left[1] + right[1]]
               when 'SUB', 'SUBI' then [left[0] - right[1], left[1] - right[0]]
               when 'MUL' then corners.call { |a, b| a * b }.minmax
               when 'DIV'
                 return nil if right[0] <= 0 && right[1] >= 0

                 corners.call { |a, b| a / b }.minmax
               end
      fixnum(result)
    end

    # LOADI_0..LOADI_7 and LOADI__1 carry the value in the opcode; the others print it as an operand.
    def loadi(insn)
      case insn.op
      when 'LOADI__1' then -1
      when /\ALOADI_(\d)\z/ then Regexp.last_match(1).to_i
      else IntegerConstants.loadi_value(insn)
      end
    end

    def fixnum(range)
      range if range && range[0] >= MIN && range[1] <= MAX
    end
  end

  # Prints the outcome, adds the diagnostics to the signature diagnostics and aborts a build on an error.
  def report(result, sig_applied, abort_on_error:)
    return if result.report.empty?

    warn '== declared constants checked at every assignment (DECLARED_CONSTANT_CHECK, ADR 0455): ' \
         "#{result.report.size} =="
    result.report.each { |line| warn line }
    result.diagnostics.each do |d|
      warn "  #{d[:file]}:#{d[:line]}:#{d[:col]}: #{d[:severity]}: #{d[:message]} [#{d[:code]}]"
    end
    if sig_applied
      # The loader notes every constant as accepted without a hint; these are checked now.
      checked = result.locs.to_set { |l| [l.file, l.line] }
      sig_applied.diagnostics.reject! do |d|
        d.code == 'TC1005' && d.message.start_with?('Constant ') && checked.include?([d.file, d.line])
      end
      sig_applied.diagnostics.concat(result.diagnostics.map { |d| RbsSignatures::Diag.new(**d) })
    end
    errors = result.diagnostics.count { |d| d[:severity] == 'error' }
    return unless errors.positive? && abort_on_error

    abort "\n[bc2cpp] DECLARED_CONSTANT_CHECK: #{errors} constant declaration(s) do not hold (see above)."
  end
end

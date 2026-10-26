# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# BYTECODE_CONSTANT_FACTS: the class, value and Fixnum interval of every constant binding, computed on
# BytecodeIR.
#
# Each SETCONST / SETMCNST writes one register. Its reaching definitions (BytecodeIR::Program#reaching_definitions,
# which follows MOVEs and joins) give every writer that can supply that register. Each writer becomes a node: an
# Integer literal, a non-Integer literal class, an alias (GETCONST / GETMCNST of a bare name), an integer operator over
# two alternative lists, or `.freeze` of an alternative list. A writer the model does not know makes its binding unknown.
#
# Facts are keyed by the full lexical path of the binding (`Scene::Map::TILE`, from the registry's constant sites). A
# read resolves by bare name, since the VM resolves it through lexical nesting and ancestors this pass does not model,
# so a read sees the group of every binding of that name. Each fact kind (class, value, interval) is the least fixpoint
# over the group: a name is known once every binding's alternatives are. A name with a poison source (a CLASS/MODULE of
# that name, a native or foreign Ruby definition) has no fact. The soundness argument is the induction on assignment
# order that IntegerConstants and IntegerConstantRanges use.
#
# Values and intervals are bounded by the Fixnum margin: an out-of-margin literal or intermediate is an Integer class
# with no value and no interval, so it is never folded as an immediate (AGENTS.md, mrb_int width).
module BytecodeIR
  module ConstantFacts
    # The narrowest target Fixnum range (CodeGen::LOADI_FIXNUM_MIN/MAX). Bare literals: a shift or OR here would be
    # folded into a bignum pool entry that a 32-bit target cannot load (AGENTS.md).
    FIXNUM_MIN = -1_073_741_824
    FIXNUM_MAX = 1_073_741_823
    # The operators an interval may combine. The bit operators are exact-value only (as IntegerConstantRanges).
    INTERVAL_OPS = %i[ADD SUB MUL DIV ADDI SUBI].freeze
    ARITH_OPS = %i[ADD SUB MUL DIV ADDI SUBI].freeze
    # `a | b` is `SEND R(a) :| n=1` (mruby 4 has no opcode for it).
    BIT_OPS = { '|' => 'BIT_OR', '&' => 'BIT_AND', '^' => 'BIT_XOR' }.freeze
    LITERAL_CLASSES = {
      :LOADNIL => :NilClass, :LOADTRUE => :TrueClass, :LOADFALSE => :FalseClass,
      :LOADSYM => :Symbol, :SYMBOL => :Symbol, :STRING => :String,
      :ARRAY => :Array, :ARRAY2 => :Array, :HASH => :Hash,
      :RANGE_INC => :Range, :RANGE_EXC => :Range
    }.freeze
    # Only builtin literal classes are retained; arbitrary alias names stay in the build's fact tables.
    LITERAL_CLASS_SETS = (LITERAL_CLASSES.values + [:Integer, :Float]).uniq.to_h do |klass|
      [klass, Set[klass].freeze]
    end.freeze
    INTEGER_CLASSES = LITERAL_CLASS_SETS.fetch(:Integer)
    EMPTY_CLASSES = Set.new.freeze
    LOADI_OP = /\ALOADI(?:8|16|32|NEG|__1|_[0-7])\z/
    POOL_INT = /\A\.i(?:32|64)=(-?\d+)\z/

    # One binding's value. classes: Set of class symbols or nil; value: exact Integer or nil; interval: [lo, hi] or nil.
    Fact = Struct.new(:classes, :value, :interval, keyword_init: true)
    # paths: full lexical path => Fact of that path's own alternatives. groups: bare name => Fact of every binding of the
    # name (what a read sees).
    # zero_divisors: bare names with a division by an exact zero somewhere in their bindings. Such a binding raises before
    # it holds a value, so only integer_class_names leaves these out (the value and Fixnum sets are unchanged).
    Result = Struct.new(:paths, :groups, :zero_divisors, keyword_init: true) do
      # Names a read may hold as a Fixnum: every binding is an Integer with an exact value or an interval, both of
      # which are inside the Fixnum margin by construction.
      def fixnum_names
        groups.select { |_, f| f.classes == INTEGER_CLASSES && (f.value || f.interval) }.keys.to_set
      end

      # Names every binding of which is an Integer, whatever its size: the bignum-capable class proof (CLASS_INTEGER_PROOF,
      # the type check's integer-class rows). An out-of-margin literal is an Integer class with no value, so it is here.
      def integer_class_names
        groups.select { |name, f| f.classes == INTEGER_CLASSES && !zero_divisors.include?(name) }.keys.to_set
      end

      # bare name => exact Integer, for groups with one value.
      def values
        groups.filter_map { |name, f| [name, f.value] if f.value }.to_h
      end

      # bare name => [lo, hi], for groups with an interval.
      def intervals
        groups.filter_map { |name, f| [name, f.interval] if f.interval }.to_h
      end
    end
    # The gates a build sets (bc2cpp.rb): operator_safe is IntegerConstantRanges.integer_ops_safe?, freeze_safe is
    # DeclaredConstants.stock_method?('freeze', 'Integer', ...). Without an operator gate no arithmetic is a fact; without
    # the freeze gate a frozen Integer is unknown.
    # hash_lookup_safe is the `[]` proof of HASH_LOOKUP (class run only, see hash_lookup_tables): it is false in the
    # value run, which then builds exactly the nodes it built before.
    Policy = Struct.new(:operators_safe, :freeze_safe, :freeze_classes, :hash_lookup_safe, keyword_init: true)

    module_function

    # +ireps+: label => Irep. +sites+: the registry's constant_assignment_sites ({name:, irep:, idx:}); they name each
    # SETCONST by its full path. +poisoned+: bare names bound outside the bytecode (native, foreign Ruby).
    # +lookup_poisoned+ (with the poison set) is every name a native or foreign definition may bind; a Hash table is
    # read only for a name outside it. Only the class run passes hash_lookup_safe.
    def analyze(ireps, sites:, poisoned:, operators_safe:, freeze_safe: false, freeze_classes: EMPTY_CLASSES,
                hash_lookup_safe: false, lookup_poisoned: EMPTY_CLASSES)
      policy = Policy.new(operators_safe: operators_safe, freeze_safe: freeze_safe, freeze_classes: freeze_classes,
                          hash_lookup_safe: hash_lookup_safe)
      path_at = sites.to_h { |site| [[site[:irep], site[:idx]], site[:name]] }
      bindings = []
      poison = Set.new(poisoned)
      ireps.each_value do |irep|
        BytecodeIR.for(irep).each_source do |insn, idx|
          case insn.op
          when :CLASS, :MODULE
            poison << insn.sym_token if insn.sym_token
          when :SETCONST, :SETMCNST
            bare = insn.op == :SETCONST ? insn.const_name : insn.mcnst_name
            next unless bare

            src = insn.regs.last
            alts = src ? alternatives(irep, idx, src, policy) : nil
            bindings << [path_at[[irep.label, idx]] || "::#{bare}", bare, alts]
          end
        end
      end
      if policy.hash_lookup_safe
        tables = hash_lookup_tables(bindings, poison | lookup_poisoned)
        bindings = bindings.map do |path, bare, alts|
          [path, bare, alts && resolve_lookups(alts, tables)]
        end
      end
      by_bare = Hash.new { |h, k| h[k] = [] }
      bindings.each { |_path, bare, alts| by_bare[bare] << alts }
      classes = fixpoint(by_bare, poison) { |alts, known| union_classes(alts, known) }
      values = fixpoint(by_bare, poison) { |alts, known| exact_of(alts, known) }
      intervals = fixpoint(by_bare, poison) { |alts, known| hull(alts, known) }
      groups = by_bare.keys.to_h do |bare|
        [bare, Fact.new(classes: classes[bare], value: values[bare], interval: intervals[bare]).freeze]
      end
      paths = bindings.group_by(&:first).to_h do |path, rows|
        all = rows.map(&:last)
        own = if all.any?(&:nil?)
                Fact.new(classes: nil, value: nil, interval: nil)
              else
                alts = all.flatten(1)
                Fact.new(classes: union_classes(alts, classes), value: exact_of(alts, values),
                         interval: hull(alts, intervals))
              end
        [path, own.freeze]
      end
      zero_divisors = by_bare.filter_map { |bare, lists| bare if lists.any? { |list| list && zero_divisor?(list, values) } }
      Result.new(paths: paths.sort.to_h.freeze, groups: groups.freeze, zero_divisors: zero_divisors.to_set.freeze)
    end

    # Least fixpoint of one fact kind over the bare-name groups. +block+ gives a group's fact from its alternatives and
    # the facts known so far, or nil while some alternative is not yet known.
    def fixpoint(by_bare, poison)
      known = {}
      loop do
        grew = false
        by_bare.each do |bare, alts_list|
          next if known.key?(bare) || poison.include?(bare) || alts_list.any?(&:nil?)

          # `Scene::Map::TILE = Game::TILE` reads its own bare name: by induction it adds nothing the other bindings
          # bound, so the self-alias is dropped (IntegerConstantRanges.resolve).
          alts = alts_list.flat_map { |list| list.reject { |node| node == [:alias, bare] } }
          next if alts.empty?

          value = yield alts, known
          next if value.nil?

          known[bare] = value
          grew = true
        end
        break unless grew
      end
      known
    end

    # The alternatives (one node per reaching writer) of register +reg+ read at instruction +index+ of +irep+, or nil.
    def alternatives(irep, index, reg, policy, depth: 0)
      return nil if depth > 64

      defs = BytecodeIR.for(irep).reaching_definitions(index, reg, shared: true, origin_transfers: true)
      return nil unless defs && !defs.empty?

      nodes = defs.map do |definition|
        next nil if definition.entry? || definition.built

        node_of(irep, definition.index, definition.reg, policy, depth)
      end
      nodes.any?(&:nil?) ? nil : nodes.uniq.freeze
    end

    # The node a writer at +index+ gives to +reg+, or nil when the writer is not a modelled literal or operator.
    def node_of(irep, index, reg, policy, depth)
      insn = BytecodeIR.for(irep).source_at(index)
      return nil unless insn.reg == reg

      op = insn.op
      return int_node(loadi_value(insn)) if BytecodeIR::Ops::LOADI_OPS.include?(op)
      return hash_node(irep, index, insn, policy, depth) if op == :HASH && policy.hash_lookup_safe
      return [:cls, LITERAL_CLASSES[op]].freeze if LITERAL_CLASSES.key?(op)

      case op
      when :LOADL then pool_node(irep, insn)
      when :GETCONST then (name = insn.const_name) && [:alias, name].freeze
      when :GETMCNST then (name = insn.mcnst_name) && [:alias, name].freeze
      when *ARITH_OPS then policy.operators_safe ? arith_node(irep, index, insn, policy, depth) : nil
      when :GETIDX then policy.hash_lookup_safe ? hash_lookup_node(irep, index, insn, policy, depth) : nil
      when :SEND0
        # Object#freeze answers its receiver, for the classes whose freeze is stock (freeze_classes; freeze_safe is
        # the Integer case). The node carries the classes it may answer for, and node_classes checks the receiver.
        return nil unless insn.sym == 'freeze'

        allowed = policy.freeze_classes | (policy.freeze_safe ? INTEGER_CLASSES : EMPTY_CLASSES)
        return nil if allowed.empty?

        receiver = alternatives(irep, index, insn.reg, policy, depth: depth + 1)
        return nil if receiver.nil? || (policy.hash_lookup_safe && !hash_frozen_in_place?(irep, index, receiver))

        receiver && [:freeze, receiver, allowed].freeze
      when :SEND
        name = BIT_OPS[insn.sym]
        return nil unless name && insn.argc == 1 && policy.operators_safe

        left = alternatives(irep, index, insn.reg, policy, depth: depth + 1)
        right = alternatives(irep, index, (insn.reg + 1), policy, depth: depth + 1)
        left && right ? [:arith, name, left, right].freeze : nil
      end
    end

    # HASH_LOOKUP (class run only). A Hash literal is a node that carries its keys when every key is an exact Integer
    # literal (no duplicate) and every value an Integer literal, read from the registers BytecodeIR's ContainerLiteral
    # names. Otherwise its keys are nil and no lookup is proven from it. The index is kept for hash_frozen_in_place?.
    def hash_node(irep, index, insn, policy, depth)
      literal = BytecodeIR.for(irep).container_literal(index)
      keys = literal && literal_hash_keys(irep, index, literal, policy, depth)
      [:hash, keys, index].freeze
    end

    # The exact keys of a Hash literal, or nil. Each value must be an Integer literal node; a key must be an exact
    # Integer (a bignum or out-of-margin key has no value to match a lookup against).
    def literal_hash_keys(irep, index, literal, policy, depth)
      keys = []
      literal.key_regs.zip(literal.value_regs) do |key_reg, value_reg|
        key = single_alternative(irep, index, key_reg, policy, depth)
        value = single_alternative(irep, index, value_reg, policy, depth)
        return nil unless key && key[0] == :int && key[1] && value && %i[int bigint].include?(value[0])

        keys << key[1]
      end
      keys.uniq.size == keys.size ? keys.freeze : nil
    end

    # `R[k]` (GETIDX R(a) R(a+1)): the receiver is a bare constant name and the key an exact Integer literal. The node
    # is resolved after every binding is known (resolve_lookups); the receiver name and key are kept until then.
    def hash_lookup_node(irep, index, insn, policy, depth)
      receiver = single_alternative(irep, index, insn.reg, policy, depth)
      key = single_alternative(irep, index, (insn.reg + 1), policy, depth)
      return nil unless receiver && receiver[0] == :alias && key && key[0] == :int && key[1]

      [:hash_lookup, receiver[1], key[1]].freeze
    end

    def single_alternative(irep, index, reg, policy, depth)
      list = alternatives(irep, index, reg, policy, depth: depth + 1)
      list && list.size == 1 ? list[0] : nil
    end

    # The Hash literal a `.freeze` receives is frozen in place only when nothing between the literal and the freeze can
    # run a method or copy the object (Program#quiet_span?, the container-literal proof). A receiver that is not a
    # single Hash literal is not refused here; it is simply not a Hash table.
    def hash_frozen_in_place?(irep, index, receiver)
      return true unless receiver.size == 1 && receiver[0][0] == :hash

      BytecodeIR.for(irep).quiet_span?(receiver[0][2], index)
    end

    # Per bare name, the exact keys of every binding when each binding is a frozen Hash literal (a single freeze node on
    # one `:hash` node with keys). A name with a poison source, or a binding that is not such a literal, has no table.
    def hash_lookup_tables(bindings, poison)
      tables = {}
      bindings.group_by { |_path, bare, _alts| bare }.each do |bare, rows|
        next if poison.include?(bare)

        found = rows.map { |_path, _bare, alts| frozen_hash_keys(alts) }
        tables[bare] = found.freeze unless found.any?(&:nil?)
      end
      tables
    end

    def frozen_hash_keys(alts)
      return nil unless alts&.size == 1

      freeze = alts[0]
      return nil unless freeze[0] == :freeze && freeze[2].include?(:Hash) && freeze[1].size == 1

      hash = freeze[1][0]
      hash[0] == :hash && hash[1] ? hash[1] : nil
    end

    # Replaces each resolvable `R[k]` by an Integer class node: every table of R holds k, and every table value is an
    # Integer literal (frozen_hash_keys). An unresolved lookup stays a node no class rule answers, so it is unknown.
    def resolve_lookups(list, tables)
      list.map { |node| resolve_lookup(node, tables) }.uniq.freeze
    end

    def resolve_lookup(node, tables)
      case node[0]
      when :hash_lookup
        found = tables[node[1]]
        found && found.all? { |keys| keys.include?(node[2]) } ? [:cls, :Integer].freeze : node
      when :freeze then [:freeze, resolve_lookups(node[1], tables), node[2]].freeze
      when :arith then [:arith, node[1], resolve_lookups(node[2], tables), resolve_lookups(node[3], tables)].freeze
      else node
      end
    end

    def arith_node(irep, index, insn, policy, depth)
      op = insn.op
      left = alternatives(irep, index, insn.reg, policy, depth: depth + 1)
      right = if %i[ADDI SUBI].include?(op)
                imm = insn.imm_operand
                imm && [int_node(imm)].freeze
              else
                insn.regs[1] && alternatives(irep, index, insn.regs[1], policy, depth: depth + 1)
              end
      left && right ? [:arith, op, left, right].freeze : nil
    end

    def int_node(value)
      return [:bigint].freeze if value.nil?

      [:int, value.between?(FIXNUM_MIN, FIXNUM_MAX) ? value : nil].freeze
    end

    # LOADL: an int32 or int64 pool entry carries its value in the C initializer (irep.rb, `.i32=N`); a bignum is an
    # Integer of no known value, a float a Float, a string a String.
    def pool_node(irep, insn)
      index = insn.pool_index
      entry = index && irep.pool && irep.pool[index]
      case entry
      when String then [:cls, :String].freeze
      when Hash
        case entry[:type]
        when :int32, :int64
          digits = entry[:raw].to_s[POOL_INT, 1]
          digits && int_node(digits.to_i)
        when :bigint then [:bigint].freeze
        when :float then [:cls, :Float].freeze
        end
      end
    end

    def loadi_value(insn)
      return BytecodeIR::Ops::LOADI_SLOT_VALUE[insn.op] if BytecodeIR::Ops::LOADI_SLOT.include?(insn.op)
      return -1 if insn.op == :LOADI__1

      insn.imm_operand
    end

    # The fact as the report prints it: `classes=A,B` ('?' unknown), `value=N` ('-' none), `interval=lo..hi` ('-' none).
    def report_fields(fact)
      classes = fact.classes ? fact.classes.map(&:to_s).sort.join(',') : '?'
      value = fact.value.nil? ? '-' : fact.value.to_s
      interval = fact.interval ? "#{fact.interval[0]}..#{fact.interval[1]}" : '-'
      ["classes=#{classes}", "value=#{value}", "interval=#{interval}"]
    end

    # The class set of the alternatives, or nil while one is not known. Integer forms are Integer.
    def union_classes(alts, known)
      out = Set.new
      alts.each do |node|
        classes = node_classes(node, known)
        return nil unless classes

        out.merge(classes)
      end
      out.freeze
    end

    def node_classes(node, known)
      case node[0]
      when :int, :bigint then INTEGER_CLASSES
      when :cls then LITERAL_CLASS_SETS.fetch(node[1]) { Set[node[1]].freeze }
      when :hash then LITERAL_CLASS_SETS.fetch(:Hash)
      when :alias then known[node[1]]
      when :freeze
        classes = union_classes(node[1], known)
        classes if classes && !classes.empty? && classes.subset?(node[2])
      when :arith
        left = union_classes(node[2], known)
        right = union_classes(node[3], known)
        integer = INTEGER_CLASSES
        left && right && !left.empty? && !right.empty? && left.subset?(integer) && right.subset?(integer) ? integer : nil
      end
    end

    # Whether some division in +alts+ has a divisor whose exact value is 0 (see Result#zero_divisors).
    def zero_divisor?(alts, known)
      alts.any? do |node|
        case node[0]
        when :freeze then zero_divisor?(node[1], known)
        when :arith
          (node[1] == :DIV && exact_of(node[3], known) == 0) || zero_divisor?(node[2], known) || zero_divisor?(node[3], known)
        else false
        end
      end
    end

    # The exact value every alternative holds (nil when one is unknown, out of margin, or they differ).
    def exact_of(alts, known)
      values = alts.map { |node| node_value(node, known) }
      return nil if values.any?(&:nil?) || values.uniq.size != 1

      values.first
    end

    def node_value(node, known)
      case node[0]
      when :int then node[1]
      when :alias then known[node[1]]
      when :freeze then node[2].include?(:Integer) ? exact_of(node[1], known) : nil
      when :arith
        left = exact_of(node[2], known)
        right = exact_of(node[3], known)
        return nil if left.nil? || right.nil?

        value = arith_value(node[1], left, right)
        value if value && value.between?(FIXNUM_MIN, FIXNUM_MAX)
      end
    end

    # mruby's fixnum DIV floors (-7 / 2 == -4); a zero divisor raises at run time, so it has no value.
    def arith_value(op, left, right)
      case op
      when :ADD, :ADDI then left + right
      when :SUB, :SUBI then left - right
      when :MUL then left * right
      when :DIV then right.zero? ? nil : left.div(right)
      when 'BIT_OR' then left | right
      when 'BIT_AND' then left & right
      when 'BIT_XOR' then left ^ right
      end
    end

    # The hull of the alternatives' intervals, or nil while one is unknown.
    def hull(alts, known)
      ranges = alts.map { |node| node_interval(node, known) }
      return nil if ranges.any?(&:nil?)

      [ranges.map(&:first).min, ranges.map(&:last).max].freeze
    end

    def node_interval(node, known)
      case node[0]
      when :int then node[1] && [node[1], node[1]].freeze
      when :alias then known[node[1]]
      when :freeze then node[2].include?(:Integer) ? hull(node[1], known) : nil
      when :arith
        return nil unless INTERVAL_OPS.include?(node[1])

        left = hull(node[2], known)
        right = hull(node[3], known)
        left && right ? combine(node[1], left, right) : nil
      end
    end

    def combine(op, left, right)
      case op
      when :ADD, :ADDI then fit([left[0] + right[0], left[1] + right[1]])
      when :SUB, :SUBI then fit([left[0] - right[1], left[1] - right[0]])
      when :MUL then corners(left, right) { |a, b| a * b }
      when :DIV
        # A divisor interval holding 0 raises or is unknown: no interval.
        return nil if right[0] <= 0 && right[1] >= 0

        corners(left, right) { |a, b| a.div(b) }
      end
    end

    def corners(left, right)
      values = left.product(right).map { |a, b| yield a, b }
      fit([values.min, values.max])
    end

    # Every intermediate has to be a Fixnum on the narrowest target.
    def fit(range)
      range[0] >= FIXNUM_MIN && range[1] <= FIXNUM_MAX ? range.freeze : nil
    end
  end
end

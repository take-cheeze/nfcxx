#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Path B e-graph pass over the SSA form (docs/notes/pathb-egraph.md). It reads the text printed by
# scripts/pathb-ssa.rb. Each basic block gets an e-graph of its pure `let`s: rewrite rules add equal forms
# (equality saturation with an iteration and a node budget), and a cost model picks the cheapest form of every
# value that is in scope. The output is the same SSA text, verified again: single definitions, dominance of every
# use, phi arity.
#
#   scripts/pathb-egraph.rb [--iters N] [--nodes N] [--cost nodes|weighted] [--stats] FILE.ssa   optimized SSA on stdout (- reads stdin)
#   scripts/pathb-egraph.rb --check FILE.ssa                             verify only (exit 1 on a failed check)
#
# Reuses the reader, printer, PURE_OPS, Phi and the interpreter (Machine) of pathb-ssa.rb.

require_relative 'pathb-ssa'

Machine.function_parser = ->(form) { PathbEgraph.parse_fn(form) }

module PathbEgraph
  INF = Float::INFINITY
  TERMINATORS = %w[br condbr switch ret unreachable].freeze
  TYPE_HEADS = %w[ptr struct union array fn].freeze
  # Ops that compute a value from their operands and may be evaluated in any order (no trap, no effect).
  COMMUTATIVE = %w[wadd wmul and or xor eq ne].freeze
  # Checked operators: they may trap, so they are never removed while they can trap. A node of one is built only
  # when its operands are pure values; it is never merged with another node of the same operator (each one keeps
  # its own site, see build_checked), and it is folded only where it cannot trap (fold_checked).
  CHECKED_OPS = %w[cdiv crem cshl cshr wshl].freeze
  # Float operations that cannot trap (fadd and the rest; cf2i traps on NaN and on overflow, so it stays opaque).
  FLOAT_OPS = %w[fadd fsub fmul fdiv fneg fconv i2f u2f lt.f le.f].freeze
  KidRef = Struct.new(:i)                  # an operand of a node: the i-th class of its kids
  Node = Struct.new(:op, :ty, :args, :kids, :cls, :value)
  EFn = Struct.new(:name, :ret, :params, :header, :blocks)   # blocks: id => { phis:, instrs:, term: }

  # ---- reader, printer and verifier ----------------------------------------------------------------------------

  def self.parse_fn(form)
    header = []
    blocks = {}
    form[2..].each do |x|
      if head(x) == "bb"
        blocks[Integer(x[1], 10)] = parse_block(x[2..])
      else
        header << x
      end
    end
    EFn.new(form[1], header.find { |x| head(x) == "ret" }, header.find { |x| head(x) == "params" }, header, blocks)
  end

  def self.parse_block(items)
    phis = []
    instrs = []
    term = nil
    items.each do |x|
      if head(x) == "phi"
        phis << Phi.new(nil, x[1], x[2], x[3..].to_h { |p| [Integer(p[0], 10), p[1]] })
      elsif TERMINATORS.include?(head(x))
        term = parse_term(x)
      else
        instrs << x
      end
    end
    raise Fail, "block without a terminator" unless term

    { phis: phis, instrs: instrs, term: term }
  end

  # In memory a switch is ["switch", OP, [[V, B]...], D] with V and B integers; the text has `(case V B)` markers
  # and a final `(default B)`.
  def self.parse_term(x)
    case x[0]
    when "br" then ["br", Integer(x[1], 10)]
    when "condbr" then ["condbr", x[1], Integer(x[2], 10), Integer(x[3], 10)]
    when "switch" then parse_switch(x)
    else x.dup
    end
  end

  def self.parse_switch(x)
    cases = x[2...-1].map do |c|
      raise Fail, "switch arm #{sx(c)}" unless head(c) == "case" && c.size == 3

      [Integer(c[1], 10), Integer(c[2], 10)]
    end
    dflt = x[-1]
    raise Fail, "switch without a default arm" unless head(dflt) == "default" && dflt.size == 2

    ["switch", x[1], cases, Integer(dflt[1], 10)]
  end

  def self.term_sx(t)
    return sx(t) unless t[0] == "switch"

    arms = t[2].map { |v, b| "(case #{v} #{b})" } + ["(default #{t[3]})"]
    "(switch #{sx(t[1])} #{arms.join(' ')})"
  end

  def self.render(fn)
    lines = ["(ssa-function #{sx(fn.name)}"]
    fn.header.each { |x| lines << "  #{sx(x)}" }
    fn.blocks.keys.sort.each do |b|
      blk = fn.blocks[b]
      lines << "  (bb #{b}"
      blk[:phis].each do |ph|
        incs = ph.inc.keys.sort.map { |p| sx([p, ph.inc[p]]) }.join(" ")
        lines << "    (phi #{ph.name} #{sx(ph.type)} #{incs})"
      end
      blk[:instrs].each { |i| lines << "    #{sx(i)}" }
      lines << "    #{term_sx(blk[:term])})"
    end
    lines << ")"
    lines.join("\n")
  end

  def self.atoms(x, out = [])
    case x
    when Array then x.each { |y| atoms(y, out) }
    when String then out << x if reg?(x)
    end
    out
  end

  def self.reverse_postorder(fn)
    seen = {}
    post = []
    stack = [[0, false]]
    until stack.empty?
      b, expanded = stack.pop
      if expanded
        post << b
        next
      end
      next if seen[b]

      seen[b] = true
      stack.push([b, true])
      succs(fn.blocks.fetch(b)[:term]).reverse_each { |s| stack.push([s, false]) unless seen[s] }
    end
    post.reverse
  end

  # Cooper, Harvey and Kennedy's iterative dominators over the reachable blocks.
  def self.idoms(fn, rpo)
    idx = rpo.each_with_index.to_h
    preds = Hash.new { |h, k| h[k] = [] }
    rpo.each { |b| succs(fn.blocks[b][:term]).uniq.each { |s| preds[s] << b } }
    idom = { 0 => 0 }
    intersect = lambda do |a, b|
      while a != b
        a = idom[a] while idx[a] > idx[b]
        b = idom[b] while idx[b] > idx[a]
      end
      a
    end
    changed = true
    while changed
      changed = false
      rpo.drop(1).each do |b|
        new_idom = nil
        preds[b].each do |p|
          next unless idom.key?(p)

          new_idom = new_idom.nil? ? p : intersect.(p, new_idom)
        end
        next if idom[b] == new_idom

        idom[b] = new_idom
        changed = true
      end
    end
    [preds, idom]
  end

  # Raises Fail unless every reachable block is well formed: each name defined once, each use dominated by its
  # definition (a phi argument by the end of its predecessor), phi arguments exactly one per predecessor.
  def self.verify(fn)
    rpo = reverse_postorder(fn)
    preds, idom = idoms(fn, rpo)
    # (a while loop: a return inside a block inside a lambda is not taken as the lambda's return by the compiled world)
    dominates = lambda do |a, b|
      found = nil
      while found.nil?
        if a == b then found = true
        elsif b.zero? then found = false
        else b = idom[b]
        end
      end
      found
    end
    params = fn.params[1..].filter_map { |p| p[1] if p.is_a?(Array) && reg?(p[1]) }
    defs = {}
    define = lambda do |name, b, k|
      raise Fail, "#{name} is defined twice" if defs.key?(name)

      defs[name] = [b, k]
    end
    rpo.each do |b|
      fn.blocks[b][:phis].each { |ph| define.(ph.name, b, -1) }
      fn.blocks[b][:instrs].each_with_index { |i, k| define.(i[1], b, k) if head(i) == "let" }
    end
    check = lambda do |a, b, k|
      next if params.include?(a)
      raise Fail, "#{a} is used in B#{b} but never defined" unless defs.key?(a)

      db, di = defs[a]
      ok = db == b ? di < k : dominates.(db, b)
      raise Fail, "#{a} (defined in B#{db}) does not dominate its use in B#{b}" unless ok
    end
    rpo.each do |b|
      blk = fn.blocks[b]
      blk[:phis].each do |ph|
        unless ph.inc.keys.sort == preds[b].sort
          raise Fail, "phi #{ph.name} in B#{b}: arguments from #{ph.inc.keys.sort}, predecessors #{preds[b].sort}"
        end

        ph.inc.each { |p, v| atoms(v).each { |a| check.(a, p, INF) } }
      end
      blk[:instrs].each_with_index do |i, k|
        atoms(head(i) == "let" ? i[2..] : i[1..]).each { |a| check.(a, b, k) }
      end
      atoms(blk[:term][1..]).each { |a| check.(a, b, blk[:instrs].size) }
    end
    fn
  end

  # ---- driver --------------------------------------------------------------------------------------------------

  def self.optimize_fn(fn, iters: 8, nodes: 2000, cost: :nodes, passes: Optimizer::PASSES, check: false)
    verify(fn)
    opt = Optimizer.new(fn, iters: iters, nodes: nodes, cost: cost)
    out = opt.run(passes: passes, check: check)
    verify(out)
    [out, opt.stats]
  end

  # Optimizes every ssa-function of a module text; other forms are printed unchanged.
  def self.optimize_module(text, dispatch: false, **opts)
    optimize_forms(read_forms(text), dispatch: dispatch, **opts)
  end

  # The same for the module's forms, already read (scripts/pathb-ssa-build holds them: no second read of the text).
  def self.optimize_forms(forms, dispatch: false, **opts)
    stats = Hash.new(0)
    lines = forms.map do |form|
      next sx(form) unless head(form) == "ssa-function"

      out, st = optimize_fn(parse_fn(form), **opts)
      out = dispatch_structurize(out) || out if dispatch # nil: the function has no dispatch form, keep it
      st.each { |k, v| stats[k] += v }
      render(out)
    end
    [lines.join("\n"), stats]
  end

  # The interpreter of pathb-ssa.rb, with the shifts added here: pathb-ssa.rb's Machine does not model cshl and
  # cshr (docs/notes/pathb-stage2.md section 4). cshl and cshr trap unless 0 <= count < the bit width of the type;
  # cshl shifts the two's complement pattern and wraps to the type, cshr is arithmetic for signed types and logical
  # for unsigned ones (a canonical unsigned value is never negative, so Ruby's >> is the logical shift).
  class CheckedMachine < Machine
    private

    def eval_rv(f)
      return super unless %w[cshl cshr].include?(head(f))

      w, = int_info(f[1])
      a = val(f[2])
      n = val(f[3])
      raise Trap, "shift count #{n} of #{w} bits" unless n >= 0 && n < w

      canon(head(f) == "cshl" ? a << n : a >> n, f[1])
    end
  end

  # Runs `main`-like function fn on integer arguments in the interpreter; returns the value or "trap". budget: nil, or
  # the step budget of the run (Machine#initialize); a run over it raises StepLimit (an Unsupported).
  def self.run(efn, args, budget: nil)
    fn = Fn.new(efn.name, efn.ret, efn.params, efn.header, [])
    CheckedMachine.new(fn, args, nil, budget: budget).run_ssa(efn.blocks)
  rescue Trap
    "trap"
  end

  # Number of `let`s in a function, and how many of them are pure (removable when unused).
  def self.let_counts(efn)
    lets = efn.blocks.values.flat_map { |b| b[:instrs].select { |i| head(i) == "let" } }
    [lets.size, lets.count { |i| pure_rv?(i[3]) }]
  end

  # ---- the optimizer: one e-graph per basic block --------------------------------------------------------------

  class Optimizer
    attr_reader :stats

    # The cost model of extraction (docs/notes/pathb-egraph.md, "Cost model"): :nodes counts every operation as 1 and a
    # constant as 0; :weighted charges the operations in WEIGHTS their weight, and a constant that does not fit a 12-bit
    # immediate 1. Ties still go to the node created first, under either model.
    COST_MODELS = %i[nodes weighted].freeze
    WEIGHTS = { "wmul" => 3, "fmul" => 3, "fdiv" => 8 }.freeze

    def initialize(fn, iters:, nodes:, cost: :nodes)
      raise ArgumentError, "cost model #{cost.inspect} (one of #{COST_MODELS.join(', ')})" unless COST_MODELS.include?(cost)
      @fn = fn
      @cost = cost
      @max_iters = iters
      @max_nodes = nodes
      @types = {}
      fn.params[1..].each { |p| @types[p[1]] = p[3] }
      fn.blocks.each_value do |blk|
        blk[:phis].each { |ph| @types[ph.name] = ph.type }
        blk[:instrs].each { |i| @types[i[1]] = i[2] if head(i) == "let" }
      end
      @subst = {}      # a dropped let => the operand that replaces it (global; registers are unique)
      @fresh = 0
      @stats = Hash.new(0)
      @read_slots = {}  # slot keys that some instruction reads or takes the address of (see dead_stores)
      fn.blocks.each_value { |blk| blk[:instrs].each { |i| collect_slot_reads(i, @read_slots) } }
      analyze_addresses
    end

    # The global passes that run after the per-block e-graphs, in this order. Each one takes the blocks and changes them
    # in place. PathbEgraph.optimize_fn can run another list (passes:), and can verify the form after each pass (check:).
    PASSES = %i[cse_dominator apply_subst hoist_invariants fold_control dce].freeze

    def run(passes: PASSES, check: false)
      before = PathbEgraph.let_counts(@fn)
      out = {}
      # Reverse postorder: a dominator is processed before the blocks it dominates, so a register it replaced
      # is already known (see reg_class).
      rpo = PathbEgraph.reverse_postorder(@fn)
      preds, = PathbEgraph.idoms(@fn, rpo)
      # A block with one predecessor starts with the memory the predecessor ends with: every path to it goes through
      # that predecessor, and it comes before the block in reverse postorder. A block with several predecessors starts
      # with the locations that all of them hold the same register for (merged_memory).
      @mem_out = {}
      rpo.each do |b|
        inherited = preds[b].size == 1 ? @mem_out[preds[b][0]] : merged_memory(preds[b])
        out[b] = block(@fn.blocks[b], inherited)
        @mem_out[b] = @mem
      end
      passes.each do |name|
        lets = lets_of(out)
        send(name, out)
        # Lets a pass removed, per pass: the statistics say what each one does.
        @stats[:"removed_#{name}"] += lets - lets_of(out)
        verify_after(name, out) if check
      end
      efn = EFn.new(@fn.name, @fn.ret, @fn.params, @fn.header, out)
      after = PathbEgraph.let_counts(efn)
      @stats[:functions] += 1
      @stats[:blocks] += out.size
      @stats[:lets_before] += before[0]
      @stats[:pure_before] += before[1]
      @stats[:lets_after] += after[0]
      @stats[:pure_after] += after[1]
      efn
    end

    private

    def lets_of(out) = PathbEgraph.let_counts(EFn.new(@fn.name, @fn.ret, @fn.params, @fn.header, out))[0]

    # The form after a pass must be well formed (PathbEgraph.verify). A failure names the pass that made it. cse_dominator
    # only records its replacements (@subst), and the uses are rewritten by apply_subst: its output is not a form yet,
    # so it is checked from apply_subst on.
    def verify_after(name, out)
      return if name == :cse_dominator

      PathbEgraph.verify(EFn.new(@fn.name, @fn.ret, @fn.params, @fn.header, out))
    rescue Fail => e
      raise Fail, "after pass #{name}: #{e.message}"
    end

    # ---- per block ---------------------------------------------------------------------------------------------

    def block(blk, inherited = nil)
      @nodes = []
      @parent = []
      @cty = {}
      @cval = {}
      @members = {}
      @memo = {}
      @bound = {}      # class => register that holds its value here (phis, parameters, emitted lets)
      @rc = {}         # register => class
      @opaque = {}     # register => true when its let is not a pure operation
      @checked = {}    # register => true when its let is a checked operation with a node (CHECKED_OPS)
      @out = []
      @cap = nil
      @mem = {}        # slot key => { type:, cls:, from:, op: } the value the slot holds here (see "Memory")
      inherit_memory(inherited) if inherited
      dead = dead_stores(blk[:instrs])
      @stats[:stores_removed] += dead.size
      blk[:phis].each { |ph| @rc[ph.name] = leaf(ph.name) }
      blk[:instrs].each do |i|
        memory_step(i)
        classify(i) if head(i) == "let"
      end
      saturate
      @memo_best = {}
      blk[:instrs].each_with_index do |ins, idx|
        next if dead[idx]

        unless head(ins) == "let"
          @out << subst_deep(ins)
          next
        end
        r, t, rv = ins[1], ins[2], ins[3]
        c = find(@rc[r])
        # A checked let that is neither folded nor available here is emitted as it was written: it stays where it
        # is, and only its operands are rewritten.
        if @opaque[r] || (@checked[r] && !@cval.key?(c) && !@bound.key?(c))
          @out << ["let", r, t, subst_deep(rv)]
          @bound[c] = r
        else
          ensure_let(r, c)
        end
      end
      # The phis are copies: the control-flow pass changes them, and the input function may be optimized again.
      { phis: blk[:phis].map { |ph| Phi.new(ph.var, ph.name, ph.type, ph.inc.dup) }, instrs: @out, term: blk[:term] }
    end

    # Adds the let's value to the e-graph: a register copy shares its operand's class, a constant or a pure
    # operation becomes a node, anything else (loads, calls, checked ops) is an opaque class of its own.
    def classify(ins)
      r, t, rv = ins[1], ins[2], ins[3]
      k = plain_slot_load(rv)
      return classify_slot_load(r, t, k) if k

      c = nil
      if reg?(rv)
        c = operand_class(rv)
      elsif (cv = const_value(t, rv))
        c = hashcons("const", cv[0], nil, [], cv[1])
      elsif rv.is_a?(Array) && PURE_OPS.include?(head(rv)) && !%w[load const null].include?(head(rv))
        c = build_node(t, rv)
      elsif (c = build_checked(r, t, rv))
        @checked[r] = true
      end
      unless c
        c = new_node("opaque", t, r, [])
        @opaque[r] = true
      end
      @rc[r] = c
    end

    def build_node(t, rv)
      args = []
      kids = []
      rv[1..].each do |x|
        if reg?(x) || const_operand?(x)
          kids << operand_class(x)
          args << KidRef.new(kids.size - 1)
        elsif x.is_a?(String) || (x.is_a?(Array) && TYPE_HEADS.include?(head(x)))
          args << x
        else
          return nil
        end
      end
      hashcons(head(rv), t, args, kids)
    end

    # A node for a checked operation `(OP T A B)` on integer type T with register or constant operands. The site
    # (the let's register) is part of the node's literal operands, so two checked lets never share a class by
    # hash-consing: a trap is then never moved to, or shared with, another place. Returns nil when not applicable.
    def build_checked(r, t, rv)
      return nil unless rv.is_a?(Array) && CHECKED_OPS.include?(head(rv)) && rv.size == 4 && rv[1] == t
      return nil unless int_ty?(t) && t != "bool"
      return nil unless rv[2..3].all? { |x| reg?(x) || const_operand?(x) }

      kids = rv[2..3].map { |x| operand_class(x) }
      new_node(head(rv), t, [t, "site:#{r}"], kids)
    end

    def operand_class(x)
      return(@rc[x] ||= reg_class(x)) if reg?(x)

      cv = const_value(x[1], x)
      hashcons("const", cv[0], nil, [], cv[1])
    end

    # A register from another block is a leaf. If a dominating block replaced it by a constant or by another
    # register (@subst), the leaf is that constant or register, so its identities are seen here too.
    def reg_class(x)
      s = resolve(x)
      return leaf(x) if s == x
      return operand_class(s) if reg?(s)

      cv = const_value(s[1], s)
      hashcons("const", cv[0], nil, [], cv[1])
    end

    def resolve(x)
      x = @subst[x] while x.is_a?(String) && @subst.key?(x)
      x
    end

    def leaf(reg)
      t = @types.fetch(reg) { raise Fail, "#{reg} is used but never defined" }
      c = new_node("leaf", t, reg, [])
      @bound[c] = reg
      c
    end

    # [type, canonical value] of a constant `let` right-hand side, or nil.
    def const_value(t, rv)
      return nil unless rv.is_a?(Array)

      if rv[0] == "const" && rv.size == 3 && rv[1] == t && rv[2].is_a?(String) && (int_ty?(t) || ptr_ty?(t)) &&
         (v = literal_int(rv[2]))
        [t, canon(v, t)]
      elsif rv[0] == "const" && rv.size == 3 && rv[1] == t && float_type?(t) && rv[2].is_a?(String) &&
            float_literal?(rv[2])
        v = round_float(Float(rv[2]), t)
        [t, v] if v.finite?
      elsif rv[0] == "null" && rv.size == 2 && rv[1] == t && ptr_ty?(t)
        [t, 0]
      end
    end

    # A float constant's text: the shortest that reads back to the same value of its type (a `float` is read back
    # as single precision). Infinities have no text, so they are never constants.
    def float_text(v, t)
      return v.to_s if t == "double"

      (1..9).each do |digits|
        s = format("%.#{digits}g", v)
        return s if round_float(Float(s), t) == v
      end
      format("%.9g", v)
    end

    def const_operand?(x)
      x.is_a?(Array) && %w[const null].include?(head(x)) && !const_value(x[1], x).nil?
    end

    def int_ty?(t) = t.is_a?(String) && INT_TYPES.key?(t)
    def ptr_ty?(t) = t.is_a?(Array) && t[0] == "ptr"

    def const_op(t, v)
      return ["null", t] if ptr_ty?(t) && v.zero?
      return ["const", t, float_text(v, t)] if v.is_a?(Float)

      ["const", t, v.to_s]
    end

    # Ruby hashes 0.0 and -0.0 alike, and IEEE does not: a float constant's key keeps the sign of a zero.
    def const_key(v)
      return v unless v.is_a?(Float)

      [v, v.zero? ? (1.0 / v).negative? : v.negative?]
    end

    # ---- the e-graph: classes, nodes, hash-consing, union-find ---------------------------------------------------

    def find(c)
      c = @parent[c] while @parent[c] != c
      c
    end

    def cval(k) = @cval[find(k)]
    def cty(k) = @cty[find(k)]

    def new_node(op, ty, args, kids, value = nil)
      cid = @parent.size
      @parent << cid
      @cty[cid] = ty
      @members[cid] = []
      @cval[cid] = value if op == "const"
      @nodes << Node.new(op, ty, args, kids, cid, value)
      @members[cid] << @nodes.size - 1
      cid
    end

    # The class of a node, reusing an existing node with the same operator, type, operands and literals.
    def hashcons(op, ty, args, kids, value = nil)
      kids = kids.map { |k| find(k) }
      key = op == "const" ? [op, sx(ty), const_key(value)] : [op, sx(ty), args_key(args), kids]
      return find(@nodes[@memo[key]].cls) if @memo.key?(key)
      return nil if @cap && @nodes.size >= @cap

      cid = new_node(op, ty, args, kids, value)
      @memo[key] = @nodes.size - 1
      @changed = true
      cid
    end

    def args_key(args) = args.map { |a| a.is_a?(KidRef) ? "#k#{a.i}" : sx(a) }.join(" ")

    def const_class(t, v) = hashcons("const", t, nil, [], v)

    def add_equal(c, other) = (merge(c, other) if other)

    def merge_const(c, t, v) = add_equal(c, const_class(t, v))

    def forward(c, x, t)
      merge(c, x) if sx(cty(x)) == sx(t)
    end

    def merge(a, b)
      a = find(a)
      b = find(b)
      return false if a == b
      raise Fail, "classes of types #{sx(@cty[a])} and #{sx(@cty[b])} merged" unless sx(@cty[a]) == sx(@cty[b])

      a, b = b, a if b < a
      @parent[b] = a
      @members[a].concat(@members.delete(b))
      if @cval.key?(b)
        raise Fail, "constants #{@cval[a]} and #{@cval[b]} merged" if @cval.key?(a) && @cval[a] != @cval[b]

        @cval[a] = @cval[b]
      end
      @bound[a] = @bound.delete(b) if @bound.key?(b) && !@bound.key?(a)
      @stats[:merges] += 1
      @changed = true
      true
    end

    # Congruence closure: nodes with equal operators and canonical operands are merged, until nothing changes.
    def rebuild
      loop do
        memo = {}
        progressed = false
        @nodes.each_index do |nid|
          nd = @nodes[nid]
          next if nd.op == "leaf" || nd.op == "opaque"

          key = node_key(nd)
          if memo.key?(key)
            progressed = true if merge(nd.cls, @nodes[memo[key]].cls)
          else
            memo[key] = nid
          end
        end
        @memo = memo
        break unless progressed
      end
    end

    def node_key(nd)
      nd.op == "const" ? [nd.op, sx(nd.ty), const_key(nd.value)] : [nd.op, sx(nd.ty), args_key(nd.args), nd.kids.map { |k| find(k) }]
    end

    # ---- equality saturation -----------------------------------------------------------------------------------

    def saturate
      input = @nodes.size
      @cap = input + @max_nodes
      iters = 0
      status = :saturated
      loop do
        @changed = false
        @nodes.size.times { |nid| apply_rules(nid) }
        rebuild
        iters += 1
        break unless @changed

        if iters >= @max_iters
          status = :cut_iters
          break
        end
        if @nodes.size >= @cap
          status = :cut_nodes
          break
        end
      end
      @stats[status] += 1
      @stats[:iterations] += iters
      @stats[:enodes_input] += input
      @stats[:enodes_added] += @nodes.size - input
    end

    def apply_rules(nid)
      nd = @nodes[nid]
      return if %w[leaf opaque const].include?(nd.op)

      c = find(nd.cls)
      kids = nd.kids.map { |k| find(k) }
      if COMMUTATIVE.include?(nd.op) && kids.size == 2 && kids[0] != kids[1]
        add_equal(c, hashcons(nd.op, nd.ty, nd.args, kids.reverse))
      end
      v = fold_value(nd, kids)
      merge_const(c, nd.ty, v) unless v.nil?
      identities(nd, c, kids)
      checked_identities(nd, c, kids) if CHECKED_OPS.include?(nd.op)
      reassoc(nd, c, kids)
      multiply_to_shift(nd, c, kids) if nd.op == "wmul"
    end

    # The value of a node whose operands are all constants, with the interpreter's semantics (canon wraps to the
    # type); nil when it is not folded. Compares fold only when the signedness matches the operator.
    def fold_value(nd, kids)
      vals = kids.map { |k| cval(k) }
      return nil if vals.empty? || vals.any?(&:nil?)
      return fold_checked(nd, vals) if CHECKED_OPS.include?(nd.op)
      return fold_float(nd, vals, kids) if FLOAT_OPS.include?(nd.op) || (%w[eq ne].include?(nd.op) && float_type?(nd.args[0]))

      t = nd.ty
      case nd.op
      when "wadd", "wsub", "wmul", "and", "or", "xor"
        return nil unless vals.size == 2 && int_ty?(t) && nd.args[0] == t

        a, b = vals
        canon(
          case nd.op
          when "wadd" then a + b
          when "wsub" then a - b
          when "wmul" then a * b
          when "and" then a & b
          when "or" then a | b
          else a ^ b
          end,
          t
        )
      when "wneg"
        return nil unless vals.size == 1 && int_ty?(t) && nd.args[0] == t

        canon(-vals[0], t)
      when "not"
        return nil unless vals.size == 1 && int_ty?(t) && nd.args[0] == t

        canon(t == "bool" ? (vals[0].zero? ? 1 : 0) : ~vals[0], t)
      when "iconv"
        return nil unless vals.size == 1 && int_ty?(t) && nd.args[0] == t && int_ty?(cty(kids[0]))

        canon(vals[0], t)
      when "lt.s", "le.s", "lt.u", "le.u", "eq", "ne"
        ot = nd.args[0]
        return nil unless vals.size == 2 && t == "bool" && int_ty?(ot)

        signed = INT_TYPES[ot][1]
        return nil if signed && nd.op.end_with?(".u")
        return nil if !signed && nd.op.end_with?(".s")

        a, b = vals
        res = case nd.op
              when "lt.s", "lt.u" then a < b
              when "le.s", "le.u" then a <= b
              when "eq" then a == b
              else a != b
              end
        res ? 1 : 0
      end
    end

    # The value of a checked node whose operands are constants, or nil when it may trap (then it is kept).
    # cdiv and crem: the divisor is nonzero and, for a signed type, not -1 (INT_MIN / -1 traps); the value is the
    # interpreter's: truncation toward zero, crem with the sign of the dividend (a - q*b). cshl and cshr: the count
    # is in [0, bit width); cshl wraps to the type, cshr is arithmetic for signed and logical for unsigned types.
    def fold_checked(nd, vals)
      t = nd.ty
      return nil unless vals.size == 2 && int_ty?(t) && t != "bool" && nd.args[0] == t

      a, b = vals
      w, signed = INT_TYPES[t]
      case nd.op
      when "cshl", "cshr", "wshl"
        return nil unless b >= 0 && b < w

        canon(nd.op == "cshr" ? a >> b : a << b, t)
      when "cdiv", "crem"
        return nil if b.zero? || (signed && b == -1)

        q = a.abs / b.abs
        q = -q if a.negative? ^ b.negative?
        canon(nd.op == "cdiv" ? q : a - q * b, t)
      end
    end

    # Float operations on constants, with the interpreter's semantics: a float result is rounded to its type after the
    # operation, and the comparisons are IEEE's (NaN is unordered: lt.f, le.f, eq are false and ne is true). A result
    # that is not finite is not folded, since an infinity has no constant text; i2f beyond 2**53 is not folded, since
    # the interpreter does not model that conversion (see int_to_float).
    def fold_float(nd, vals, kids)
      t = nd.ty
      case nd.op
      when "fadd", "fsub", "fmul", "fdiv"
        return nil unless vals.size == 2 && float_type?(t) && nd.args[0] == t && vals.all?(Float)

        a, b = vals
        r = round_float(a.send({ "fadd" => :+, "fsub" => :-, "fmul" => :*, "fdiv" => :/ }[nd.op], b), t)
        r if r.finite?
      when "fneg"
        return nil unless vals.size == 1 && float_type?(t) && nd.args[0] == t && vals[0].is_a?(Float)

        -vals[0]
      when "fconv"
        return nil unless vals.size == 1 && float_type?(t) && vals[0].is_a?(Float)

        r = round_float(vals[0], t)
        r if r.finite?
      when "i2f", "u2f"
        return nil unless vals.size == 1 && float_type?(t) && int_ty?(cty(kids[0])) && vals[0].is_a?(Integer)
        return nil if vals[0].abs > 2**53

        r = round_float(vals[0], t)
        r if r.finite?
      when "lt.f", "le.f", "eq", "ne"
        ot = nd.args[0]
        return nil unless vals.size == 2 && t == "bool" && float_type?(ot) && vals.all?(Float)

        a, b = vals
        res = case nd.op
              when "lt.f" then a < b
              when "le.f" then a <= b
              when "eq" then a == b
              else a != b
              end
        res ? 1 : 0
      end
    end

    # Identities of checked nodes that cannot trap: x << 0 = x and x >> 0 = x (the count is in range), and x / 1 = x
    # (the divisor is not zero and not -1). A division by a variable or by -1 is left alone.
    def checked_identities(nd, c, kids)
      t = nd.ty
      return unless int_ty?(t) && t != "bool" && nd.args[0] == t

      a, b = kids
      case nd.op
      when "cshl", "cshr", "wshl" then forward(c, a, t) if cval(b) == 0
      when "cdiv" then forward(c, a, t) if cval(b) == 1
      end
    end

    # Identities that hold for every integer value (bit-exact under wrapping): x+0, x-0, x-x, x*1, x*0, x&all-ones,
    # x&0, x&x, x|0, x|all-ones, x|x, x^0, x^x, iconv to the same type, and eq/ne of a value with itself.
    def identities(nd, c, kids)
      t = nd.ty
      if %w[eq ne].include?(nd.op)
        merge_const(c, t, nd.op == "eq" ? 1 : 0) if int_ty?(nd.args[0]) && t == "bool" && kids[0] == kids[1]
        return
      end
      return unless int_ty?(t) && nd.args[0] == t

      a, b = kids
      case nd.op
      when "iconv"
        forward(c, a, t)
      when "wadd"
        forward(c, a, t) if cval(b) == 0
        forward(c, b, t) if cval(a) == 0
      when "wsub"
        forward(c, a, t) if cval(b) == 0
        merge_const(c, t, 0) if a == b
      when "wmul"
        forward(c, a, t) if cval(b) == 1
        forward(c, b, t) if cval(a) == 1
        merge_const(c, t, 0) if cval(a) == 0 || cval(b) == 0
      when "and"
        ones = canon(-1, t)
        forward(c, a, t) if a == b || cval(b) == ones
        forward(c, b, t) if cval(a) == ones
        merge_const(c, t, 0) if cval(a) == 0 || cval(b) == 0
      when "or"
        ones = canon(-1, t)
        forward(c, a, t) if a == b || cval(b) == 0
        forward(c, b, t) if cval(a) == 0
        merge_const(c, t, ones) if cval(a) == ones || cval(b) == ones
      when "xor"
        forward(c, a, t) if cval(b) == 0
        forward(c, b, t) if cval(a) == 0
        merge_const(c, t, 0) if a == b
      end
    end

    # Constant addends are reassociated: (x + c1) + c2 = x + (c1 + c2), and x - c = x + (-c), all wrapping.
    def reassoc(nd, c, kids)
      t = nd.ty
      return unless int_ty?(t) && nd.args[0] == t

      a, b = kids
      if nd.op == "wsub" && cval(b)
        n = const_class(t, canon(-cval(b), t))
        add_equal(c, hashcons("wadd", t, [t, KidRef.new(0), KidRef.new(1)], [a, n])) if n
      elsif nd.op == "wadd"
        [[a, b], [b, a]].each do |base, addend|
          c2 = cval(addend)
          next unless c2

          @members[find(base)].dup.each do |mid|
            m = @nodes[mid]
            next unless m.op == "wadd" && m.args[0] == t && m.kids.size == 2

            2.times do |j|
              inner = find(m.kids[1 - j])
              c1 = cval(m.kids[j])
              next unless c1

              n = const_class(t, canon(c1 + c2, t))
              add_equal(c, hashcons("wadd", t, [t, KidRef.new(0), KidRef.new(1)], [inner, n])) if n
            end
          end
        end
      end
    end

    # ---- memory: the slots of a block (docs/notes/pathb-egraph.md, "Memory") ---------------------------------------

    # Operators that read or compute but never write memory; a `let` of one of them keeps the memory state.
    MEMORY_FREE = (PURE_OPS + %w[bitcast bfload cshl cshr wshl cdiv crem pdiff fconv cf2i p2i i2p lt.f le.f fadd fsub fmul
                                fdiv fneg i2f u2f]).freeze
    # Operators that read memory (a silent instruction neither reads nor writes it).
    READS_MEMORY = %w[load load.v bfload bfload.v call vaarg].freeze

    # The slot key of a plain load `(load T $"x")`, or nil.
    def plain_slot_load(rv) = head(rv) == "load" ? mem_key(rv[2]) : nil

    # True when x contains an operator that may write memory. Type forms carry no operations.
    def memory_write?(x)
      return false unless x.is_a?(Array)

      h = head(x)
      return false if TYPE_HEADS.include?(h)
      return true if h && !MEMORY_FREE.include?(h)

      x.any? { |y| memory_write?(y) }
    end

    # True when a statement may write memory other than by a store to a known location (a call, a copy, a volatile or
    # bit-field store, a store through an unknown pointer, a barrier). Any statement that is not a `let`, a store, a `set`,
    # `nonnull` or `bounds` is conservatively such a write. An address computation writes nothing: whether the slot it
    # names can be written through a pointer is decided by the escape analysis (analyze_addresses).
    def clobbers?(ins)
      case head(ins)
      when "let" then memory_write?(ins[3])
      when "store"
        return true unless slot_key(ins[2])

        memory_write?(ins[3])
      when "set" then memory_write?(ins[2])
      when "nonnull", "bounds", "life-start", "life-end" then false   # the lifetime facts neither read nor write memory
      else true
      end
    end

    # ---- addresses of the slots: derived pointers and escape analysis ---------------------------------------------
    # A register is a derived address of a slot when its let is `(offset P K)`, `(index P I SIZE)` or `(bitcast T P)`
    # with P a slot's address or another derived address. @roots maps the register to [slot key, byte offset], the
    # offset nil when an index is not a constant. A slot escapes when its address, or a derived address, is used other
    # than as the address of a load or store, as the base of a derivation, or as a nonnull check. Only an escaping slot
    # can be written through a pointer, or by a call that receives its address; a slot that does not escape is written
    # only by the stores that name it, and keeps its remembered values across calls and pointer writes.
    DERIVE_BASE = { "offset" => 1, "index" => 1, "bitcast" => 2 }.freeze

    def analyze_addresses
      @roots = {}
      @escaping = {}
      @all_escape = @fn.blocks.each_value.any? { |b| b[:instrs].any? { |i| calls_setjmp?(i) } }
      changed = true
      while changed
        changed = false
        each_let do |r, rv|
          next if @roots.key?(r)

          base, delta = derivation(rv)
          root = base && root_of(base)
          next unless root

          @roots[r] = [root[0], root[1] && delta ? root[1] + delta : nil]
          changed = true
        end
      end
      @fn.blocks.each_value do |blk|
        blk[:instrs].each do |i|
          case head(i)
          when "let"
            rv = i[3]
            base, = derivation(rv)
            if base && root_of(base)
              escape_in(rv, rv[DERIVE_BASE[head(rv)]])
            elsif head(rv) == "load"
              escape_in(rv, rv[2])
            else
              escape_in(rv)
            end
          when "store" then escape_in(i, i[2])
          when "nonnull" then escape_in(i, i[1])
          when "life-start", "life-end" then nil   # a lifetime fact names a slot without taking its address
          else escape_in(i)
          end
        end
        blk[:phis].each { |ph| ph.inc.each_value { |v| escape_in(v) } }
        escape_in(blk[:term])
      end
    end

    def each_let
      @fn.blocks.each_value do |blk|
        blk[:instrs].each { |i| yield i[1], i[3] if head(i) == "let" }
      end
    end

    # The base operand and the byte offset of a derivation, or nil when rv is not one.
    def derivation(rv)
      return nil unless rv.is_a?(Array) && DERIVE_BASE.key?(head(rv))

      case head(rv)
      when "offset" then [rv[1], int_or_nil(rv[2])]
      when "index"
        i = rv[2].is_a?(Array) && head(rv[2]) == "const" ? int_or_nil(rv[2][2]) : nil
        size = int_or_nil(rv[3])
        [rv[1], i && size ? i * size : nil]
      else [rv[2], 0]
      end
    end

    def int_or_nil(x)
      Integer(x.to_s, 10)
    rescue ArgumentError
      nil
    end

    # [slot key, offset] of an address operand: a slot's own address, or a derived address; nil otherwise.
    def root_of(op)
      return [slot_key(op), 0] if slot_key(op)

      @roots[op] if reg?(op)
    end

    # Marks the slots that escape through the operands of x, other than the operand `allowed` (identity).
    def escape_in(x, allowed = nil)
      case x
      when Array then x.each { |y| escape_in(y, allowed) }
      when Ref
        k = slot_key(x)
        @escaping[k] = true if k && !x.equal?(allowed)
      when String
        if reg?(x) && @roots.key?(x) && !x.equal?(allowed)
          @escaping[@roots[x][0]] = true
        end
      end
    end

    def calls_setjmp?(x)
      return false unless x.is_a?(Array)
      return true if x.any? { |y| y.is_a?(Ref) && y.sigil == "&" && SETJMP_NAMES.include?(y.raw) }

      x.any? { |y| calls_setjmp?(y) }
    end

    # The memory location of an address operand: a slot's own address (its key), or a derived address with a known
    # offset (the slot key and the offset). nil for an unknown location.
    def mem_key(op)
      return slot_key(op) if slot_key(op)
      return nil unless reg?(op) && @roots[op] && @roots[op][1]

      root, off = @roots[op]
      off.zero? ? root : "#{root}\u0001#{off}"
    end

    # The slot an address operand names (its own key, or a derived address's), or nil.
    def addr_root(op)
      root_of(op)&.first
    end

    def root_key(k) = k.split("\u0001", 2).first

    # A store through an address of slot `root` may overlap any other location of that slot: those are forgotten.
    def kill_root(root, keep)
      @mem.delete_if { |k, _| k != keep && root_key(k) == root }
    end

    # The slots that escape lose their remembered values (a call or a pointer write may write them).
    def forget_escaping
      @mem.delete_if { |k, _| @all_escape || @escaping.key?(root_key(k)) }
    end

    # True when an instruction contains a read of memory (a load of any kind, a call).
    def reads_memory?(x)
      return false unless x.is_a?(Array)
      return true if READS_MEMORY.include?(head(x))

      x.any? { |y| reads_memory?(y) }
    end

    # Runs before the instruction's own value is classified: a write that may touch any slot forgets every
    # remembered value, and a plain store records the value its slot now holds.
    def memory_step(ins)
      if head(ins) == "store" && (root = addr_root(ins[2]))
        forget_escaping if memory_write?(ins[3])
        kill_root(root, mem_key(ins[2]))
        note_store(ins)
        return
      end
      forget_escaping if clobbers?(ins)
    end

    def forget_memory = (@mem = {})

    # The memory that a block with several predecessors starts with: the locations that every predecessor holds, each
    # with the same register and type. A register is defined once and dominates every use, so when all the predecessors
    # hold the same register it dominates the block, and the value is the same on every path. A predecessor that is not
    # processed yet (a back edge) gives nothing: the state is not known there.
    def merged_memory(preds)
      states = preds.map { |p| @mem_out[p] }
      return nil if preds.empty? || states.any?(&:nil?)

      first, *rest = states
      first.select do |k, e|
        e[:op] && rest.all? { |s| (f = s[k]) && f[:op] == e[:op] && sx(f[:type]) == sx(e[:type]) }
      end
    end

    # The slots a predecessor leaves hold their values here too. The class of a value is a node of the predecessor's
    # e-graph, so the value is re-resolved from its operand (a register of an earlier block is a leaf, see reg_class).
    def inherit_memory(from)
      from.each do |k, e|
        cls = nil
        if e[:op]
          c = operand_class(e[:op])
          cls = c if sx(cty(c)) == sx(e[:type])
        end
        @mem[k] = { type: e[:type], cls: cls, from: e[:from], op: e[:op] }
      end
    end

    # The slot holds the stored value. The value is remembered as a class only when it is a register or a constant
    # of the store's type; any other value (an expression) leaves the slot's value unknown.
    def note_store(ins)
      k = mem_key(ins[2])
      return unless k

      t, v = ins[1], ins[3]
      cls = nil
      if reg?(v) || const_operand?(v)
        c = operand_class(v)
        cls = c if sx(cty(c)) == sx(t)
      end
      op = reg?(v) || const_operand?(v) ? v : nil
      @mem[k] = { type: t, cls: cls, from: :store, op: op }
    end

    # A plain load of a slot. When the slot's value is known here with the same type, the load has that value:
    # it shares the class, and no let is emitted for it (ensure_let substitutes the register). Otherwise the load
    # is an opaque value, and the slot holds it from now on.
    def classify_slot_load(r, t, k)
      seen = @mem[k]
      if seen && seen[:cls] && sx(seen[:type]) == sx(t)
        @rc[r] = seen[:cls]
        @stats[seen[:from] == :store ? :stores_forwarded : :loads_merged] += 1
      else
        c = new_node("opaque", t, r, [])
        @opaque[r] = true
        @rc[r] = c
        @mem[k] = { type: t, cls: c, from: :load, op: r }
      end
    end

    # The stores that are dead: a plain store to a slot that no instruction of the function reads, followed in the
    # block by another store to that slot, with no instruction in between that reads memory or may write it. The
    # stored value must be a register or a constant, so the store cannot trap and nothing else depends on it.
    # Returns { index of the statement => true }.
    def dead_stores(instrs)
      dead = {}
      pending = {}   # slot key => index of a removable store with no read after it
      instrs.each_with_index do |ins, idx|
        unless !clobbers?(ins) && !reads_memory?(ins)
          pending.clear
          next
        end
        next unless head(ins) == "store" && slot_key(ins[2])

        k = slot_key(ins[2])
        next if @read_slots.include?(k)

        dead[pending[k]] = true if pending.key?(k)
        pending.delete(k)
        pending[k] = idx if reg?(ins[3]) || const_operand?(ins[3])
      end
      dead
    end

    # Slot keys that some instruction of the function reads or takes the address of: any `$"x"` except the address
    # of a plain store.
    def collect_slot_reads(x, out)
      case x
      when Ref then out[slot_key(x)] = true if x.sigil == "$"
      when Array
        if head(x) == "store" && slot_key(x[2])
          collect_slot_reads(x[3], out)
        elsif head(x) == "life-start" || head(x) == "life-end"
          nil   # a lifetime fact reads nothing
        else
          x.each { |y| collect_slot_reads(y, out) }
        end
      end
      out
    end

    # ---- extraction and emission -------------------------------------------------------------------------------

    def ensure_let(r, c)
      c = find(c)
      if @cval.key?(c)
        @subst[r] = const_op(@cty[c], @cval[c])
      elsif @bound.key?(c)
        @subst[r] = @bound[c]
      else
        @memo_best = {}
        materialize(c, r)
      end
    end

    # Cheapest form of class c whose operands are available here. Constants and values already in a register cost
    # 0; an operation costs 1 plus its operands; an opaque value that is not yet bound is unavailable.
    def best(c)
      c = find(c)
      return [const_cost(c), nil] if @cval.key?(c)
      return [0, nil] if @bound.key?(c)
      return @memo_best[c] if @memo_best.key?(c)

      @memo_best[c] = [INF, nil]
      bestc = [INF, nil]
      @members[c].each do |nid|
        nd = @nodes[nid]
        next if nd.op == "opaque" || nd.op == "leaf" || (CHECKED_OPS.include?(nd.op) && sited?(nd))

        total = node_cost(nd)
        nd.kids.each do |k|
          kc, = best(k)
          if kc == INF
            total = INF
            break
          end
          total += kc
        end
        bestc = [total, nid] if total < bestc[0]
      end
      @memo_best[c] = bestc
    end

    # A checked node made by build_checked carries its site (its let's register) and is never extracted: its trap stays
    # where it was written. A site-free checked node (multiply_to_shift) has a constant count in range, so it cannot
    # trap, and extraction may choose it.
    def sited?(nd) = nd.args.any? { |a| a.is_a?(String) && a.start_with?("site:") }

    # x * 2^k = x << k for a constant 2^k with 1 <= k <= w-2, wrapping in both. Only under the weighted cost model,
    # where a multiply costs 3 (WEIGHTS) and a shift 1. The count is a constant of type int in range, so the new wshl
    # cannot trap and has no site (see sited?).
    def multiply_to_shift(nd, c, kids)
      t = nd.ty
      return unless @cost == :weighted && int_ty?(t) && t != "bool" && nd.args[0] == t

      w, = INT_TYPES[t]
      kids.each_with_index do |x, i|
        v = cval(x)
        next unless v.is_a?(Integer) && v.positive?

        k = v.bit_length - 1
        next unless v == (1 << k) && k >= 1 && k <= w - 2

        n = const_class("int", k)
        add_equal(c, hashcons("wshl", t, [t, KidRef.new(0), KidRef.new(1)], [kids[1 - i], n]))
        return
      end
    end

    # The cost of one operation (the node itself, not its operands) and of a constant, under the cost model.
    def node_cost(nd)
      @cost == :weighted ? WEIGHTS.fetch(nd.op, 1) : 1
    end

    def const_cost(c)
      return 0 if @cost == :nodes
      v = @cval[c]
      v.is_a?(Integer) && v.abs < 4096 ? 0 : 1
    end

    def materialize(c, name = nil)
      c = find(c)
      return const_op(@cty[c], @cval[c]) if @cval.key?(c)
      return @bound[c] if name.nil? && @bound.key?(c)

      _cost, nid = best(c)
      raise Fail, "no form of a value is available in its block" unless nid

      nd = @nodes[nid]
      ops = nd.kids.map { |k| materialize(k) }
      name ||= fresh
      @out << ["let", name, nd.ty, [nd.op, *nd.args.map { |a| a.is_a?(KidRef) ? ops[a.i] : a }]]
      @bound[c] = name
      name
    end

    def fresh
      loop do
        @fresh += 1
        name = "%g#{@fresh}"
        return name unless @types.key?(name)
      end
    end

    # ---- common subexpressions across blocks (dominator tree) --------------------------------------------------

    # A pure `let` whose right-hand side (after the substitution so far) and type equal those of a `let` of a block
    # that dominates it is removed, and the later register takes the earlier one's value. The table of definitions
    # is scoped by the dominator tree: a block's definitions are pushed when it is entered and popped when it is
    # left, so the register found in the table is defined by a dominator of every use it replaces (a definition
    # earlier in the same block also qualifies). Only the whitelist of pure operations is keyed: loads, constants,
    # checked operations (division, shifts, bounds) and everything else are never merged. A phi is never a
    # replacement, and no operation is moved. The substitution itself is applied by run.
    def cse_dominator(out)
      efn = EFn.new(@fn.name, @fn.ret, @fn.params, @fn.header, out)
      rpo = PathbEgraph.reverse_postorder(efn)
      _preds, idom = PathbEgraph.idoms(efn, rpo)
      children = Hash.new { |h, k| h[k] = [] }
      rpo.drop(1).each { |b| children[idom[b]] << b }
      table = {}      # [type, right-hand side] => register defined by a dominating let
      pushed = {}     # block => keys it added to the table
      stack = [[0, true]]
      until stack.empty?
        b, entering = stack.pop
        unless entering
          (pushed.delete(b) || []).each { |key| table.delete(key) }
          next
        end

        keys = []
        out[b][:instrs].each do |ins|
          next unless head(ins) == "let" && cse_operation?(ins[3])

          key = [ins[2], subst_deep(ins[3])]
          if table.key?(key)
            @subst[ins[1]] = table[key]
            @stats[:cse] += 1
          else
            table[key] = ins[1]
            keys << key
          end
        end
        pushed[b] = keys
        stack << [b, false]
        children[b].each { |c| stack << [c, true] }
      end
    end

    # Operations that hoisting may move: pure, and they cannot trap or read memory (division, shifts and the checked
    # forms can, and load reads the memory), so running them on a path that would not have run them changes nothing.
    HOISTABLE = %w[const null iconv wadd wsub wmul wneg lt.s lt.u le.s le.u eq ne and or xor not index offset
                   fadd fsub fmul fdiv fneg fconv i2f u2f lt.f le.f].freeze

    # Loop-invariant code motion: a hoistable let in a loop whose operands are all defined outside the loop moves to the
    # loop's preheader (the one block outside the loop that is the header's only other predecessor, and ends in a br to
    # the header). The preheader dominates the loop, so the operands still dominate the moved let, and the moved let runs
    # once rather than once per iteration. Moved lets can make the next ones invariant, so the loop repeats until nothing
    # moves. A loop with no preheader is left as it is.
    def hoist_invariants(out)
      efn = EFn.new(@fn.name, @fn.ret, @fn.params, @fn.header, out)
      rpo = PathbEgraph.reverse_postorder(efn)
      preds, idom = PathbEgraph.idoms(efn, rpo)
      dominates = lambda do |a, b|
        x = b
        found = nil
        while found.nil?
          if x == a then found = true
          elsif x == 0 || !idom.key?(x) then found = false
          else x = idom[x]
          end
        end
        found
      end
      def_block = {}
      out.each do |id, blk|
        blk[:phis].each { |ph| def_block[ph.name] = id }
        blk[:instrs].each { |ins| def_block[ins[1]] = id if head(ins) == "let" }
      end
      out.each_key do |h|
        latches = (preds[h] || []).select { |p| dominates.call(h, p) }
        next if latches.empty?

        body = [h]
        stack = latches.dup
        until stack.empty?
          b = stack.pop
          next if body.include?(b)

          body << b
          stack.concat(preds[b] || [])
        end
        outside = (preds[h] || []).reject { |p| body.include?(p) }
        next unless outside.size == 1

        pre = outside[0]
        next unless out[pre][:term][0] == "br" && out[pre][:term][1] == h

        loop do
          moved = false
          body.sort.each do |b|
            keep = []
            out[b][:instrs].each do |ins|
              movable = head(ins) == "let" && HOISTABLE.include?(head(ins[3])) &&
                PathbEgraph.regs_of(ins[3]).all? { |r| !body.include?(def_block[r]) }
              if movable
                out[pre][:instrs] << ins
                def_block[ins[1]] = pre
                @stats[:hoisted] += 1
                moved = true
              else
                keep << ins
              end
            end
            out[b][:instrs] = keep
          end
          break unless moved
        end
      end
    end

    def cse_operation?(rv)
      rv.is_a?(Array) && PURE_OPS.include?(head(rv)) && !%w[load const null].include?(head(rv))
    end

    # ---- substitution and dead code --------------------------------------------------------------------------

    def subst_deep(x)
      case x
      when Array then x.map { |y| subst_deep(y) }
      when String
        x = @subst[x] while x.is_a?(String) && @subst.key?(x)
        x
      else x
      end
    end

    def count_regs(x, uses)
      case x
      when Array then x.each { |y| count_regs(y, uses) }
      when String then uses[x] += 1 if reg?(x)
      end
    end

    # Removes pure lets with no use, repeatedly (the same rule as pathb-ssa.rb's cleanup).
    def dce(out)
      loop do
        uses = Hash.new(0)
        out.each_value do |blk|
          blk[:phis].each { |ph| ph.inc.each_value { |v| count_regs(v, uses) } }
          blk[:instrs].each { |i| count_regs(head(i) == "let" ? i[2..] : i[1..], uses) }
          count_regs(blk[:term][1..], uses)
        end
        removed = false
        out.each_value do |blk|
          blk[:instrs].reject! do |i|
            dead = head(i) == "let" && uses[i[1]].zero? && pure_rv?(i[3])
            removed ||= dead
            dead
          end
        end
        break unless removed
      end
    end

    # ---- control flow: constant branches, unreachable blocks, phis ----------------------------------------------

    # Applies @subst (the replaced registers) to every phi argument, instruction and terminator.
    def apply_subst(out)
      out.each_value do |blk|
        blk[:phis].each { |ph| ph.inc.transform_values! { |v| subst_deep(v) } }
        blk[:instrs] = blk[:instrs].map { |i| head(i) == "let" ? ["let", i[1], i[2], subst_deep(i[3])] : subst_deep(i) }
        blk[:term] = subst_deep(blk[:term])
      end
    end

    # Each round: a condbr or switch on a constant becomes a br to the arm it selects; blocks no longer reachable
    # are removed; phi arguments from removed edges are dropped; a phi whose arguments are all one operand (self
    # references ignored) is replaced by it; a phi nothing uses is removed. Repeats until nothing changes, because a
    # replaced phi can make a branch constant. Every edge removed takes its phi arguments with it, so each phi keeps
    # exactly one argument per predecessor.
    def fold_control(out)
      loop do
        changed = fold_branches(out)
        changed |= remove_unreachable(out)
        changed |= prune_phi_args(out)
        changed |= replace_phis(out)
        apply_subst(out)
        changed |= remove_dead_phis(out)
        break unless changed
      end
    end

    # The value of a constant operand, canonical for its type (the interpreter's `val`), or nil for anything else.
    # The literal may be decimal or hexadecimal (`0x1`, the printer's form of many bool and unsigned constants).
    def const_int(op)
      return nil unless op.is_a?(Array) && %w[const null].include?(head(op))
      return 0 if op[0] == "null" && op.size == 2 && ptr_ty?(op[1])
      return nil unless op[0] == "const" && op.size == 3 && (int_ty?(op[1]) || ptr_ty?(op[1]))

      v = literal_int(op[2])
      v.nil? ? nil : canon(v, op[1])
    end

    # /\A-?\d+\z/ and /\A-?0x\h+\z/i and the float literal /\A-?\d+(\.\d+)?([eE][-+]?\d+)?\z/ as character scans: the
    # script world has no Regexp. digits_from(s, i) is the index after the run of digits starting at i (i when none).
    def digits_from(s, i)
      i += 1 while i < s.size && s[i] >= "0" && s[i] <= "9"
      i
    end

    def decimal_literal?(s)
      i = s.start_with?("-") ? 1 : 0
      j = digits_from(s, i)
      j > i && j == s.size
    end

    def hex_literal?(s)
      i = s.start_with?("-") ? 1 : 0
      return false unless s.size > i + 2 && s[i] == "0" && (s[i + 1] == "x" || s[i + 1] == "X")
      s[(i + 2)..].each_char.all? { |c| (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F") }
    end

    # A float literal as printed in the IR: an integer or a decimal, with an optional exponent.
    def float_literal?(s)
      i = s.start_with?("-") ? 1 : 0
      j = digits_from(s, i)
      return false if j == i
      if s[j] == "."
        k = digits_from(s, j + 1)
        return false if k == j + 1
        j = k
      end
      if s[j] == "e" || s[j] == "E"
        j += 1
        j += 1 if s[j] == "-" || s[j] == "+"
        k = digits_from(s, j)
        return false if k == j
        j = k
      end
      j == s.size
    end

    def literal_int(s)
      return Integer(s, 10) if decimal_literal?(s)
      return nil unless hex_literal?(s)

      s.start_with?("-") ? -s.delete("-")[2..].hex : s[2..].hex
    end

    # The br that a constant condbr or switch selects: a condbr takes its true arm when the value is nonzero; a
    # switch takes the first case equal to the value, else the default (the interpreter's rule).
    def selected_br(term)
      case term[0]
      when "condbr"
        c = const_int(term[1])
        ["br", c.zero? ? term[3] : term[2]] unless c.nil?
      when "switch"
        c = const_int(term[1])
        return nil if c.nil?

        hit = term[2].find { |v, _| v == c }
        ["br", hit ? hit[1] : term[3]]
      end
    end

    def fold_branches(out)
      changed = false
      out.each_value do |blk|
        br = selected_br(blk[:term])
        next unless br

        @stats[blk[:term][0] == "condbr" ? :condbr_folded : :switch_folded] += 1
        blk[:term] = br
        changed = true
      end
      changed
    end

    def remove_unreachable(out)
      seen = { 0 => true }
      stack = [0]
      until stack.empty?
        succs(out.fetch(stack.pop)[:term]).each do |s|
          next if seen[s]

          seen[s] = true
          stack << s
        end
      end
      dead = out.keys.reject { |b| seen[b] }
      dead.each { |b| out.delete(b) }
      @stats[:blocks_removed] += dead.size
      dead.any?
    end

    # The phi arguments of a block are exactly its predecessors (a predecessor is a block with an edge to it).
    def prune_phi_args(out)
      preds = Hash.new { |h, k| h[k] = [] }
      out.each { |b, blk| succs(blk[:term]).uniq.each { |s| preds[s] << b } }
      changed = false
      out.each do |b, blk|
        blk[:phis].each do |ph|
          before = ph.inc.size
          ph.inc.select! { |p, _| preds[b].include?(p) }
          changed ||= ph.inc.size != before
        end
      end
      changed
    end

    def replace_phis(out)
      changed = false
      out.each_value do |blk|
        blk[:phis].reject! do |ph|
          others = ph.inc.values.map { |v| subst_deep(v) }.reject { |v| v == ph.name }
          next false if others.empty? || others.map { |v| sx(v) }.uniq.size != 1

          @subst[ph.name] = others.first
          @stats[:phis_replaced] += 1
          changed = true
        end
      end
      changed
    end

    # A phi with no use is removed, as the converter's cleanup does; a phi used only by itself is kept.
    # A phi is live when a live use reads it: a use by an instruction or a terminator, or by a live phi (its operand
    # from a predecessor). A phi that is live only through a cycle of phis that nothing else reads is dead, and is removed.
    def remove_dead_phis(out)
      by_name = {}
      live = Hash.new(false)
      work = []
      out.each_value do |blk|
        blk[:phis].each { |ph| by_name[ph.name] = ph }
        blk[:instrs].each do |i|
          regs = Hash.new(0)
          count_regs(head(i) == "let" ? i[2..] : i[1..], regs)
          regs.each_key { |r| work << r }
        end
        regs = Hash.new(0)
        count_regs(blk[:term][1..], regs)
        regs.each_key { |r| work << r }
      end
      until work.empty?
        r = work.pop
        next unless by_name.key?(r) && !live[r]

        live[r] = true
        regs = Hash.new(0)
        by_name[r].inc.each_value { |v| count_regs(v, regs) }
        regs.each_key { |x| work << x }
      end
      changed = false
      out.each_value do |blk|
        blk[:phis].reject! do |ph|
          next false if live[ph.name]

          @stats[:phis_removed] += 1
          changed = true
        end
      end
      changed
    end
  end
  # ---- block chains ----------------------------------------------------------------------------------------------
  # A block whose only successor is a block that has no other predecessor and no phis is merged with it: the two are
  # one block, the one the dispatch loop runs without a transition between them. The entry (block 0) is never merged
  # into another block. Mutates fn.blocks and returns the function.
  def self.merge_chains(fn)
    blocks = fn.blocks
    succs = lambda do |t|
      case t[0]
      when "br" then [t[1]]
      when "condbr" then [t[2], t[3]]
      when "switch" then t[2].map { |_, x| x } + [t[3]]
      else []
      end
    end
    loop do
      preds = Hash.new { |h, k| h[k] = [] }
      blocks.each { |id, b| succs.call(b[:term]).uniq.each { |s| preds[s] << id } }
      merged = blocks.keys.sort.any? do |a|
        term = blocks[a][:term]
        next false unless term[0] == "br"
        b = term[1]
        next false if b == a || b == 0 || preds[b] != [a] || !blocks[b][:phis].empty?

        blocks[a][:instrs] += blocks[b][:instrs]
        blocks[a][:term] = blocks[b][:term]
        blocks.each_value do |sb|
          sb[:phis].each { |ph| ph.inc[a] = ph.inc.delete(b) if ph.inc.key?(b) }
        end
        blocks.delete(b)
        true
      end
      break unless merged
    end
    fn
  end

  # ---- the dispatch loop -----------------------------------------------------------------------------------------
  # The function as one loop. A dispatch block switches on a state slot to the block to run, and every edge goes through
  # a block that sets the state and returns to the dispatch (the unreachable block is the switch's default). A register
  # that crosses blocks, and every phi, becomes a slot: its value is stored where it is defined and loaded where it is
  # used, so no block depends on another's dominance. The result has no phis and every use is local to its block, so it
  # is valid SSA, and it runs the same as the input (the check compares them). A backend without arbitrary control flow
  # lowers it as one loop with a switch. The block 0 stays the entry: its code runs once, and a jump back to it is an arm.
  # Returns nil for a function this form does not take: a value that crosses blocks and is an aggregate (its slot would
  # need the struct layout, which the e-graph does not have). Such a function is left as it is.
  def self.dispatch_structurize(fn)
    blocks = fn.blocks
    defs = {}     # register => block that defines it (a parameter: block 0)
    types = {}    # register => IR type
    fn.params[1..].each { |p| defs[p[1]] = 0; types[p[1]] = p[3] }
    blocks.each do |id, blk|
      blk[:phis].each { |ph| defs[ph.name] = id; types[ph.name] = ph.type }
      blk[:instrs].each do |i|
        next unless head(i) == "let"

        defs[i[1]] = id
        types[i[1]] = i[2]
      end
    end
    # the uses of each register, by block: a use in a phi's operand is a use in the predecessor it comes from
    uses = Hash.new { |h, k| h[k] = [] }
    blocks.each do |id, blk|
      blk[:instrs].each { |i| regs_of(head(i) == "let" ? i[2..] : i[1..]).each { |r| uses[r] << id } }
      regs_of(blk[:term][1..]).each { |r| uses[r] << id }
    end
    blocks.each do |id, blk|
      blk[:phis].each { |ph| ph.inc.each { |pred, v| regs_of(v).each { |r| uses[r] << pred } } }
    end
    phi_names = blocks.values.flat_map { |b| b[:phis].map(&:name) }
    demoted = {}
    defs.each_key { |r| demoted[r] = true if phi_names.include?(r) || uses[r].any? { |u| u != defs[r] } }
    demoted.each_key { |r| dispatch_size(types[r]) }   # raises Unsupported for an aggregate
    # every register, not only the crossing ones: the emitter takes scalars only, so an aggregate value (a struct
    # local, which block merging can leave inside one block) refuses the function as before
    types.each_value { |t| dispatch_size(t) }

    slot = ->(r) { "__dsp#{r[1..]}" }                     # the slot of register r
    slot_ref = ->(r) { "$\"#{slot.call(r)}\"" }
    state = "$\"__dsp_state\""
    dispatch = blocks.keys.max + 1
    unreachable = dispatch + 1
    next_id = unreachable + 1
    counter = 0
    fresh = -> { counter += 1; "%dsp#{counter}" }
    edges = {}                                             # [from, to] => the block that sets the state for it

    out = {}
    blocks.each do |id, blk|
      loads = {}                                           # register => the load that gives it here
      rewrite = nil
      rewrite = lambda do |x|
        case x
        when Array then x.map { |y| rewrite.call(y) }
        when String
          if reg?(x) && demoted[x] && defs[x] != id
            loads[x] ||= begin
              name = fresh.call
              [F("(let #{name} #{sx(types[x])} (load #{sx(types[x])} #{slot_ref.call(x)}))"), name]
            end
            loads[x][1]
          else
            x
          end
        else x
        end
      end
      body = []
      blk[:instrs].each do |i|
        ri = rewrite.call(i)
        body << ri
        if head(i) == "let" && demoted[i[1]]
          body << F("(store #{sx(types[i[1]])} #{slot_ref.call(i[1])} #{i[1]})")
        end
      end
      if id == 0
        fn.params[1..].each do |p|
          body.unshift(F("(store #{sx(p[3])} #{slot_ref.call(p[1])} #{p[1]})")) if demoted[p[1]]
        end
      end
      blk[:phis].each do |ph|
        body.unshift(F("(let #{ph.name} #{sx(ph.type)} (load #{sx(ph.type)} #{slot_ref.call(ph.name)}))"))
      end
      blocks.each_value do |succ|
        succ[:phis].each do |ph|
          next unless ph.inc.key?(id)

          body << F("(store #{sx(ph.type)} #{slot_ref.call(ph.name)} #{sx(rewrite.call(ph.inc[id]))})")
        end
      end
      term = rewrite.call(blk[:term])
      target = lambda do |t|
        edges[[id, t]] ||= next_id.tap { next_id += 1 }
        edges[[id, t]]
      end
      term = case term[0]
             when "br" then ["br", target.call(term[1])]
             when "condbr" then ["condbr", term[1], target.call(term[2]), target.call(term[3])]
             when "switch"
               ["switch", term[1], term[2].map { |v, t| [v, target.call(t)] }, target.call(term[3])]
             else term
             end
      out[id] = { phis: [], instrs: loads.values.map(&:first) + body, term: term }
    end

    # the dispatch, the unreachable default, and an edge block per edge: it sets the state and returns to the dispatch
    out[dispatch] = { phis: [], instrs: [F("(let %dstate int (load int #{state}))")],
                      term: ["switch", "%dstate", blocks.keys.sort.map { |k| [k, k] }, unreachable] }
    out[unreachable] = { phis: [], instrs: [], term: ["unreachable"] }
    edges.each do |(from, to), eb|
      out[eb] = { phis: [], instrs: [F("(store int #{state} (const int #{to}))")], term: ["br", dispatch] }
    end
    header = fn.header + [F("(slot \"__dsp_state\" int 4 4)")] +
             demoted.keys.map { |r| size = dispatch_size(types[r]); F("(slot \"#{slot.call(r)}\" #{sx(types[r])} #{size} #{size})") }
    EFn.new(fn.name, fn.ret, fn.params, header, out)
  rescue Unsupported
    nil
  end

  # The size of a scalar slot of type t (the layout of INT_TYPES, pointers and the floating types).
  def self.dispatch_size(t)
    return 8 if head(t) == "ptr"

    { "float" => 4, "double" => 8, "bool" => 1 }.fetch(t) { INT_TYPES.fetch(t) { raise Unsupported, "slot of type #{sx(t)}" }[0] / 8 }
  end

  # The dispatch form as flat IR, the structured form a backend that takes flat IR lowers (scripts/pathb-wasm-emit.rb):
  # one loop around a switch on the state slot. Each original block is an arm; a jump to a block stores its id in the state
  # and continues the loop. The edge blocks of dispatch_structurize are not arms: a jump through one does its store and
  # continues. Returns the function as a flat IR form, or nil when the form is not a dispatch form.
  def self.flat_from_dispatch(dfn)
    dispatch = dfn.blocks.keys.find do |id|
      t = dfn.blocks[id][:term]
      t[0] == "switch" && t[1] == "%dstate"
    end
    return nil unless dispatch

    unreachable = dfn.blocks[dispatch][:term][3]
    edge = lambda do |id|
      b = dfn.blocks[id]
      b && b[:term] == ["br", dispatch] && b[:instrs].all? { |i| head(i) == "store" }
    end
    types = {}
    dfn.params[1..].each { |p| types[p[1]] = p[3] }
    dfn.blocks.each_value do |b|
      b[:instrs].each { |i| types[i[1]] = i[2] if head(i) == "let" }
    end
    state = "$\"__dsp_state\""
    goto = lambda do |x|
      if x == dispatch
        [F("(continue)")]
      elsif edge.call(x)
        dfn.blocks[x][:instrs] + [F("(continue)")]
      else
        [F("(store int #{state} (const int #{x}))"), F("(continue)")]
      end
    end
    term = lambda do |t, op_type|
      case t[0]
      when "br" then goto.call(t[1])
      when "condbr"
        [["if", t[1], ["then", *goto.call(t[2])], ["else", *goto.call(t[3])]]]
      when "switch"
        arms = t[2].flat_map { |v, x| [F("(case (const #{sx(op_type)} #{v}))"), *goto.call(x)] }
        [["switch", t[1], ["body", ["block", *arms, F("(default)"), *goto.call(t[3])]]]]
      when "ret" then [t[1] ? ["return", t[1]] : ["return"]]
      when "unreachable" then [["unreachable"]]
      else raise Unsupported, "terminator #{head(t)}"
      end
    end
    arms = dfn.blocks.keys.reject { |id| id == dispatch || id == unreachable || edge.call(id) }.sort.flat_map do |id|
      b = dfn.blocks[id]
      sel_type = types.fetch(b[:term][1].is_a?(String) ? b[:term][1] : "", "int")
      [F("(case (const int #{id}))"), *b[:instrs], *term.call(b[:term], sel_type)]
    end
    arms << F("(default)") << ["unreachable"]
    # The slots of the dispatch form (the registers that cross blocks, and the state) are locals of the function: a
    # slot's stores and loads are sets and reads of its local. That is the same value (each register is defined before
    # its uses, so a load reads the last store on every path), without the memory traffic of a frame in the memory, which
    # made the form several times slower than the flat IR. The locals are declared before the loop, as lets.
    locals = {}     # the slot's reference (a $"name" form) => the local's name
    dispatch_slots = []   # the raw names of the dispatch slots (the function's own slots stay)
    decls = []
    dfn.header.each do |x|
      next unless head(x) == "slot" && x[1].raw.start_with?('"__dsp')   # the dispatch's slots, not the function's own

      name = x[1].raw[1..-2]                          # the name without its quotes
      dispatch_slots << x[1].raw
      reg = "%sl#{name[1..]}"                         # __dsp0 => %sl_dsp0
      locals[F("$\"#{name}\"")] = reg
      zero = head(x[2]) == "ptr" ? F("(null)") : F("(const #{sx(x[2])} 0)")
      decls << ["let", reg, x[2], zero]
    end
    local_rewrite = lambda do |x|
      return x unless x.is_a?(Array)
      if head(x) == "load" && x.length == 3 && locals.key?(x[2])
        locals[x[2]]
      elsif head(x) == "store" && x.length == 4 && locals.key?(x[2])
        ["set", locals[x[2]], local_rewrite.call(x[3])]
      else
        x.map { |y| local_rewrite.call(y) }
      end
    end
    header = dfn.header.reject do |x|
      %w[ssa-promoted ssa-function ret params].include?(head(x)) || (head(x) == "slot" && dispatch_slots.include?(x[1].raw))
    end
    state_local = locals.fetch(F("$\"__dsp_state\""))
    body = ["block", *decls, F("(set #{state_local} (const int 0))"),
            ["loop", ["body", F("(let %dstate int #{state_local})"),
                      ["switch", "%dstate", ["body", ["block", *arms]]]],
             ["step"]]]
    ["function", dfn.name, dfn.ret, dfn.params, *header, local_rewrite.call(body)]
  end

  # The registers named in x (strings that start with %).
  def self.regs_of(x)
    case x
    when Array then x.flat_map { |y| regs_of(y) }
    when String then reg?(x) ? [x] : []
    else []
    end
  end

  # One form read from SSA text: the parts of a rewritten function are built from text, so their objects are the reader's.
  def self.F(text) = read_forms(text).first

end

# ---- command line ---------------------------------------------------------------------------------------------

def egraph_cli(argv)
  opts = { iters: 8, nodes: 2000 }
  check = false
  stats = false
  file = nil
  until argv.empty?
    a = argv.shift
    case a
    when "--check" then check = true
    when "--stats" then stats = true
    when "--iters" then opts[:iters] = Integer(argv.shift, 10)
    when "--nodes" then opts[:nodes] = Integer(argv.shift, 10)
    when "--dispatch" then opts[:dispatch] = true
    when "--cost"
      model = argv.shift.to_s.to_sym
      unless PathbEgraph::Optimizer::COST_MODELS.include?(model)
        $stderr.write "pathb-egraph: --cost nodes or weighted\n"
        return 1
      end
      opts[:cost] = model
    else file = a
    end
  end
  unless file
    $stderr.write "usage: pathb-egraph.rb [--check] [--stats] [--iters N] [--nodes N] [--cost nodes|weighted] [--dispatch] FILE.ssa\n"
    return 1
  end

  text = file == "-" ? $stdin.read : File.read(file)
  if check
    fns = read_forms(text).select { |f| head(f) == "ssa-function" }
    fns.each { |f| PathbEgraph.verify(PathbEgraph.parse_fn(f)) }
    $stderr.write "pathb-egraph: #{fns.size} functions verified\n"
    return 0
  end
  out, st = PathbEgraph.optimize_module(text, **opts)
  puts out
  if stats
    $stderr.write "pathb-egraph: #{st[:functions]} functions, lets #{st[:lets_before]} -> #{st[:lets_after]} " \
         "(pure #{st[:pure_before]} -> #{st[:pure_after]}), e-nodes #{st[:enodes_input]} + #{st[:enodes_added]} added, " \
         "#{st[:iterations]} iterations, saturated #{st[:saturated]} blocks, cut by iterations #{st[:cut_iters]}, " \
         "cut by nodes #{st[:cut_nodes]}, folded #{st[:condbr_folded]} condbr and #{st[:switch_folded]} switch, " \
         "removed #{st[:blocks_removed]} blocks, #{st[:phis_replaced]} phis replaced, #{st[:phis_removed]} dead phis, " \
         "common subexpressions across blocks #{st[:cse]}, " \
         "loads merged #{st[:loads_merged]}, " \
         "stores forwarded #{st[:stores_forwarded]}, dead stores removed #{st[:stores_removed]}\n"
  end
  0
rescue Fail, Unsupported => e
  $stderr.write "pathb-egraph: #{e.message}\n"
  1
rescue SystemCallError => e
  $stderr.write "pathb-egraph: #{e.message}\n"
  1
end

def main(argv)
  egraph_cli(argv)
end

# pathb-structure.rb requires this file for its parser, so the command line runs only as the program.
if $0 == __FILE__
  rc = main(ARGV)
  exit(rc) if rc != 0
end

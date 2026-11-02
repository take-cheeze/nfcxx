#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Path B e-graph pass over the SSA form (docs/notes/pathb-egraph.md). It reads the text printed by
# scripts/pathb-ssa.rb. Each basic block gets an e-graph of its pure `let`s: rewrite rules add equal forms
# (equality saturation with an iteration and a node budget), and a cost model picks the cheapest form of every
# value that is in scope. The output is the same SSA text, verified again: single definitions, dominance of every
# use, phi arity.
#
#   scripts/pathb-egraph.rb [--iters N] [--nodes N] [--stats] FILE.ssa   optimized SSA on stdout (- reads stdin)
#   scripts/pathb-egraph.rb --check FILE.ssa                             verify only (exit 1 on a failed check)
#
# Reuses the reader, printer, PURE_OPS, Phi and the interpreter (Machine) of pathb-ssa.rb.

require_relative 'pathb-ssa'

module PathbEgraph
  INF = Float::INFINITY
  TERMINATORS = %w[br condbr ret unreachable].freeze
  TYPE_HEADS = %w[ptr struct union array fn].freeze
  # Ops that compute a value from their operands and may be evaluated in any order (no trap, no effect).
  COMMUTATIVE = %w[wadd wmul and or xor eq ne].freeze
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

  def self.parse_term(x)
    case x[0]
    when "br" then ["br", Integer(x[1], 10)]
    when "condbr" then ["condbr", x[1], Integer(x[2], 10), Integer(x[3], 10)]
    else x.dup
    end
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
      lines << "    #{sx(blk[:term])})"
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
    dominates = lambda do |a, b|
      loop do
        return true if a == b
        return false if b.zero?

        b = idom[b]
      end
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

  def self.optimize_fn(fn, iters: 8, nodes: 2000)
    verify(fn)
    opt = Optimizer.new(fn, iters: iters, nodes: nodes)
    out = opt.run
    verify(out)
    [out, opt.stats]
  end

  # Optimizes every ssa-function of a module text; other forms are printed unchanged.
  def self.optimize_module(text, **opts)
    stats = Hash.new(0)
    lines = read_forms(text).map do |form|
      next sx(form) unless head(form) == "ssa-function"

      out, st = optimize_fn(parse_fn(form), **opts)
      st.each { |k, v| stats[k] += v }
      render(out)
    end
    [lines.join("\n"), stats]
  end

  # Runs `main`-like function fn on integer arguments in the interpreter; returns the value or "trap".
  def self.run(efn, args)
    fn = Fn.new(efn.name, efn.ret, efn.params, efn.header, [])
    Machine.new(fn, args).run_ssa(efn.blocks)
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

    def initialize(fn, iters:, nodes:)
      @fn = fn
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
    end

    def run
      before = PathbEgraph.let_counts(@fn)
      out = {}
      # Reverse postorder: a dominator is processed before the blocks it dominates, so a register it replaced
      # is already known (see reg_class).
      PathbEgraph.reverse_postorder(@fn).each { |b| out[b] = block(@fn.blocks[b]) }
      out.each_value do |blk|
        blk[:phis].each { |ph| ph.inc.transform_values! { |v| subst_deep(v) } }
        blk[:instrs] = blk[:instrs].map { |i| head(i) == "let" ? ["let", i[1], i[2], subst_deep(i[3])] : subst_deep(i) }
        blk[:term] = subst_deep(blk[:term])
      end
      dce(out)
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

    # ---- per block ---------------------------------------------------------------------------------------------

    def block(blk)
      @nodes = []
      @parent = []
      @cty = {}
      @cval = {}
      @members = {}
      @memo = {}
      @bound = {}      # class => register that holds its value here (phis, parameters, emitted lets)
      @rc = {}         # register => class
      @opaque = {}     # register => true when its let is not a pure operation
      @out = []
      @cap = nil
      blk[:phis].each { |ph| @rc[ph.name] = leaf(ph.name) }
      blk[:instrs].each { |i| classify(i) if head(i) == "let" }
      saturate
      @memo_best = {}
      blk[:instrs].each do |ins|
        unless head(ins) == "let"
          @out << subst_deep(ins)
          next
        end
        r, t, rv = ins[1], ins[2], ins[3]
        c = find(@rc[r])
        if @opaque[r]
          @out << ["let", r, t, subst_deep(rv)]
          @bound[c] = r
        else
          ensure_let(r, c)
        end
      end
      { phis: blk[:phis], instrs: @out, term: blk[:term] }
    end

    # Adds the let's value to the e-graph: a register copy shares its operand's class, a constant or a pure
    # operation becomes a node, anything else (loads, calls, checked ops) is an opaque class of its own.
    def classify(ins)
      r, t, rv = ins[1], ins[2], ins[3]
      c = nil
      if reg?(rv)
        c = operand_class(rv)
      elsif (cv = const_value(t, rv))
        c = hashcons("const", cv[0], nil, [], cv[1])
      elsif rv.is_a?(Array) && PURE_OPS.include?(head(rv)) && !%w[load const null].include?(head(rv))
        c = build_node(t, rv)
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

      if rv[0] == "const" && rv.size == 3 && rv[1] == t && rv[2].is_a?(String) && rv[2].match?(/\A-?\d+\z/) &&
         (int_ty?(t) || ptr_ty?(t))
        [t, canon(rv[2].to_i, t)]
      elsif rv[0] == "null" && rv.size == 2 && rv[1] == t && ptr_ty?(t)
        [t, 0]
      end
    end

    def const_operand?(x)
      x.is_a?(Array) && %w[const null].include?(head(x)) && !const_value(x[1], x).nil?
    end

    def int_ty?(t) = t.is_a?(String) && INT_TYPES.key?(t)
    def ptr_ty?(t) = t.is_a?(Array) && t[0] == "ptr"

    def const_op(t, v)
      ptr_ty?(t) && v.zero? ? ["null", t] : ["const", t, v.to_s]
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
      key = op == "const" ? [op, sx(ty), value] : [op, sx(ty), args_key(args), kids]
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
      nd.op == "const" ? [nd.op, sx(nd.ty), nd.value] : [nd.op, sx(nd.ty), args_key(nd.args), nd.kids.map { |k| find(k) }]
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
      reassoc(nd, c, kids)
    end

    # The value of a node whose operands are all constants, with the interpreter's semantics (canon wraps to the
    # type); nil when it is not folded. Compares fold only when the signedness matches the operator.
    def fold_value(nd, kids)
      vals = kids.map { |k| cval(k) }
      return nil if vals.empty? || vals.any?(&:nil?)

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
      return [0, nil] if @cval.key?(c) || @bound.key?(c)
      return @memo_best[c] if @memo_best.key?(c)

      @memo_best[c] = [INF, nil]
      bestc = [INF, nil]
      @members[c].each do |nid|
        nd = @nodes[nid]
        next if nd.op == "opaque" || nd.op == "leaf"

        total = 1
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
  end
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
    else file = a
    end
  end
  abort "usage: pathb-egraph.rb [--check] [--stats] [--iters N] [--nodes N] FILE.ssa" unless file

  text = file == "-" ? $stdin.read : File.read(file)
  if check
    fns = read_forms(text).select { |f| head(f) == "ssa-function" }
    fns.each { |f| PathbEgraph.verify(PathbEgraph.parse_fn(f)) }
    warn "pathb-egraph: #{fns.size} functions verified"
    return 0
  end
  out, st = PathbEgraph.optimize_module(text, **opts)
  puts out
  if stats
    warn "pathb-egraph: #{st[:functions]} functions, lets #{st[:lets_before]} -> #{st[:lets_after]} " \
         "(pure #{st[:pure_before]} -> #{st[:pure_after]}), e-nodes #{st[:enodes_input]} + #{st[:enodes_added]} added, " \
         "#{st[:iterations]} iterations, saturated #{st[:saturated]} blocks, cut by iterations #{st[:cut_iters]}, " \
         "cut by nodes #{st[:cut_nodes]}"
  end
  0
rescue Fail, Unsupported => e
  warn "pathb-egraph: #{e.message}"
  1
end

exit(egraph_cli(ARGV)) if $PROGRAM_NAME == __FILE__

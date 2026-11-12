#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Path B SSA (docs/notes/pathb-ssa.md). Converts every function of a stage 2 IR module (tests/pathb-ir/*.ir) to an
# SSA control-flow graph. Structured control flow becomes basic blocks. A scalar slot whose address is never taken,
# and a register assigned with `set`, become SSA values; `phi` joins are placed on the iterated dominance frontier
# (Cytron et al.). Stores and loads of promoted slots disappear; the other slots stay in memory.
#
#   scripts/pathb-ssa.rb FILE.ir              print the module with its functions in SSA form
#   scripts/pathb-ssa.rb --check FILE.ir      verify only; summary on stderr (exit 1 on a failed check)
#   scripts/pathb-ssa.rb --run N... FILE.ir   run `main` on integer arguments, in the structured IR and in the
#                                             SSA form, and print both results (`structured=unsupported` when the
#                                             structured interpreter does not model a construct, e.g. goto)
#
# Every converted function is verified: each name is defined once, each use is dominated by its definition, and
# each phi has exactly one argument per predecessor. A function that the converter cannot model is left as it was
# (stderr says so).
#
# A switch becomes a dispatch terminator `(switch OP (case V B)... (default B))`: V is an integer canonical for the
# operand's type, and B is the block of a `case` or `default` marker. Fallthrough is a `br` from the block still open
# before a marker. Without a default marker the default target is the block after the switch.

Ref = Struct.new(:sigil, :raw)   # $"x", @"x", &"f": raw is the quoted name, quotes included
Str = Struct.new(:raw)           # a quoted string token, quotes included
Fn = Struct.new(:name, :ret, :params, :slots, :body, :attrs)
Blk = Struct.new(:instrs, :term, :loc)  # loc: the (loc FILE LINE) statement the block's last instruction was given under
Phi = Struct.new(:var, :name, :type, :inc)
Unsupported = Class.new(StandardError)
# A run that takes more steps than its budget (Machine#initialize). An Unsupported, so a caller that does not budget
# a run sees the same outcome as for any other run it cannot model.
StepLimit = Class.new(Unsupported)
Fail = Class.new(StandardError)
Trap = Class.new(StandardError)
# A longjmp: the jump buffer's address and the value. The frame that holds the matching _setjmp resumes there.
LongJump = Class.new(StandardError) do
  attr_reader :buf, :value

  def initialize(buf, value)
    @buf = buf
    @value = value
    super("longjmp")
  end
end

SETJMP_NAMES = ['"_setjmp"', '"setjmp"', '"sigsetjmp"', '"__sigsetjmp"'].freeze
AGG_HEADS = %w[struct union array fn].freeze
# Operations that cannot trap or have effects: a `let` of one with no use is removed.
PURE_OPS = %w[const null load iconv wadd wsub wmul wneg lt.s lt.u le.s le.u eq ne and or xor not index offset
              fadd fsub fmul fdiv fneg fconv i2f u2f lt.f le.f].freeze

# ---- reader and printer ---------------------------------------------------------------------------------------------

def quoted_end(s, i)
  j = i + 1
  while j < s.size
    return j if s[j] == '"'

    j += s[j] == "\\" ? 2 : 1
  end
  raise Fail, "unterminated string at #{i}"
end

# The same tokens as a character loop: a parenthesis, a string, a $ @ or & prefixed string, or a run of other characters
# (which stops before a quote). One scan: the loop tested every character with a regex, which dominated the run time.
TOKEN_WS = " \t\r\n\f\v"

# The end (after the closing quote) of the string that starts at i, or nil: a backslash escapes the next character
# except a newline, as `.` does not match one.
def token_string_end(s, i)
  j = i + 1
  while j < s.size
    if s[j] == "\\"
      return nil unless j + 1 < s.size && s[j + 1] != "\n"

      j += 2
    elsif s[j] == '"'
      return j + 1
    else
      j += 1
    end
  end
  nil
end

def scan_tokens(s)
  out = []
  i = 0
  n = s.size
  while i < n
    c = s[i]
    if c == "(" || c == ")"
      out << c
      i += 1
    elsif c == '"' && (e = token_string_end(s, i))
      out << s[i...e]
      i = e
    elsif "$@&".include?(c) && i + 1 < n && s[i + 1] == '"' && (e = token_string_end(s, i + 1))
      out << s[i...e]
      i = e
    elsif c != '"' && !TOKEN_WS.include?(c)
      j = i + 1
      j += 1 while j < n && !TOKEN_WS.include?(s[j]) && s[j] != "(" && s[j] != ")" && s[j] != '"'
      out << s[i...j]
      i = j
    else
      i += 1
    end
  end
  out
end

def tokenize(s)
  out = scan_tokens(s)
  out.map do |t|
    if t.start_with?('"')
      Str.new(t)
    elsif t.length > 1 && t[1] == '"' && "$@&".include?(t[0])
      Ref.new(t[0], t[1..])
    else
      t
    end
  end
end

# A literal the IR writes in a form Integer() or Float() does not read: a hex integer (the value of its type, as canon
# gives it) and an infinity (1e999 is read by Float as the same value). NaN is left as written: Float() cannot read it.
def normalise_literals(x)
  return x unless x.is_a?(Array)

  x = x.map { |y| normalise_literals(y) }
  return x unless head(x) == "const" && x.size >= 3 && x[1].is_a?(String) && x[2].is_a?(String)

  type, val = x[1], x[2]
  if float_type?(type) || type == "std::float16_t"
    x[2] = "1e999" if val == "+Infinity"
    x[2] = "-1e999" if val == "-Infinity"
  elsif hex_literal?(val) && INT_TYPES.key?(type)
    x[2] = canon(Integer(val, 16), type).to_s
  elsif hex_literal?(val) && type == "bool"
    x[2] = canon(Integer(val, 16), type).to_s
  end
  x
end

def read_forms(text)
  stack = [[]]
  tokenize(text).each do |t|
    case t
    when "(" then stack.push([])
    when ")"
      raise Fail, "unbalanced parentheses" if stack.size < 2

      done = stack.pop
      stack.last << done
    else stack.last << t
    end
  end
  raise Fail, "unbalanced parentheses" unless stack.size == 1

  normalise_literals(stack[0])
end

def sx(x)
  case x
  when Array then "(#{x.map { |y| sx(y) }.join(' ')})"
  when Ref then x.sigil + x.raw
  when Str then x.raw
  else x.to_s
  end
end

def head(x) = x.is_a?(Array) && x[0].is_a?(String) ? x[0] : nil
def reg?(x) = x.is_a?(String) && x.start_with?("%")
def slot_key(a) = a.is_a?(Ref) && a.sigil == "$" ? "$#{a.raw}" : nil
def scalar_type?(t) = !(AGG_HEADS.include?(head(t)) || t == "long_double" || t == "void")
def succs(term)
  case term[0]
  when "br" then [term[1]]
  when "condbr" then [term[2], term[3]]
  when "switch" then term[2].map { |_, b| b } + [term[3]]
  else []
  end
end

def clause(s, name)
  c = s.find { |x| head(x) == name }
  c ? c[1..] : []
end

# Linkage markers and constructor/destructor attributes follow the parameters; they have no runtime meaning in the body.
FN_ATTR_HEADS = %w[static weak constructor destructor].freeze

def fn_of(form)
  Fn.new(form[1], form.find { |x| head(x) == "ret" }, form.find { |x| head(x) == "params" },
         form.select { |x| head(x) == "slot" },
         form[2..].reject { |x| (%w[ret params slot] + FN_ATTR_HEADS).include?(head(x)) },
         form[2..].select { |x| FN_ATTR_HEADS.include?(head(x)) })
end

# ---- structured IR to basic blocks ----------------------------------------------------------------------------------

class Cfg
  attr_reader :blocks

  def initialize
    @blocks = []
    @labels = {}
    @targets = []   # [break target, continue target or nil] for each enclosing loop and switch, innermost last
    @switches = []  # { cases: [[value, block]], default: block or nil } for each enclosing switch
  end

  def build(body, void)
    entry = new_block
    cur = lower_list(body, entry)
    set_term(cur, void ? ["ret"] : ["unreachable"]) if @blocks[cur].term.nil?
    @blocks.each { |b| b.term ||= ["unreachable"] }
    self
  end

  private

  def new_block
    @blocks << Blk.new([], nil)
    @blocks.size - 1
  end

  def set_term(b, t)
    raise Fail, "B#{b} terminated twice" if @blocks[b].term

    @blocks[b].term = t
  end

  def lower_list(stmts, cur)
    stmts.each { |s| cur = lower_stmt(s, cur) }
    cur
  end

  def label_block(name) = (@labels[name] ||= new_block)

  # Every case returns the block where control continues; that block is always open. After a jump the
  # continuation is a fresh block with no predecessor, which the converter drops.
  def lower_stmt(s, cur)
    case head(s)
    when "block" then lower_list(s[1..], cur)
    when "if"
      t = new_block
      e = new_block
      j = new_block
      set_term(cur, ["condbr", s[1], t, e])
      set_term(lower_list(clause(s, "then"), t), ["br", j])
      set_term(lower_list(clause(s, "else"), e), ["br", j])
      j
    when "loop"
      h = new_block
      cont = new_block
      done = new_block
      set_term(cur, ["br", h])
      @targets.push([done, cont])
      set_term(lower_list(clause(s, "body"), h), ["br", cont])
      set_term(lower_list(clause(s, "step"), cont), ["br", h])
      @targets.pop
      done
    when "switch" then lower_switch(s, cur)
    # A case or default marker ends the open block with a fallthrough edge; the marker's block is the new open block.
    when "case", "default"
      raise Unsupported, "#{head(s)} outside a switch" if @switches.empty?

      b = new_block
      set_term(cur, ["br", b])
      sw = @switches.last
      if head(s) == "case"
        sw[:cases] << [case_value(s[1]), b]
      else
        raise Fail, "two default labels in one switch" if sw[:default]

        sw[:default] = b
      end
      b
    when "break" then set_term(cur, ["br", break_target]) && new_block
    when "continue" then set_term(cur, ["br", continue_target]) && new_block
    when "return" then set_term(cur, ["ret", *s[1..]]) && new_block
    when "unreachable" then set_term(cur, ["unreachable"]) && new_block
    when "goto" then set_term(cur, ["br", label_block(s[1].raw)]) && new_block
    when "label"
      l = label_block(s[1].raw)
      set_term(cur, ["br", l])
      l
    when "loc"
      # A source location (NFCXX_IR_LOC=1): the statements after it are at that location. It is written into a block
      # just before the first instruction that needs it (below), so each block says its own location.
      @loc_now = s
      cur
    else
      blk = @blocks[cur]
      if @loc_now && (blk.loc.nil? || blk.loc.object_id != @loc_now.object_id)
        blk.instrs << @loc_now
        blk.loc = @loc_now
      end
      blk.instrs << s
      cur
    end
  end

  # The body's first statements form a block that no jump reaches (C skips them unless a marker follows). The
  # dispatch goes in `cur` once the body is lowered; its default target is the exit when there is no default marker.
  def lower_switch(s, cur)
    done = new_block
    sw = { cases: [], default: nil }
    @switches.push(sw)
    @targets.push([done, nil])
    last = lower_list(clause(s, "body"), new_block)
    set_term(last, ["br", done])
    @targets.pop
    @switches.pop
    set_term(cur, ["switch", s[1], sw[:cases], sw[:default] || done])
    done
  end

  def case_value(c)
    raise Unsupported, "case label #{sx(c)}" unless head(c) == "const" && c[2].is_a?(String) && int_literal?(c[2])

    c[2].to_i
  end

  def break_target
    raise Unsupported, "break outside a loop or switch" if @targets.empty?

    @targets.last[0]
  end

  def continue_target
    t = @targets.reverse.find { |x| x[1] }
    raise Unsupported, "continue outside a loop" unless t

    t[1]
  end
end

# ---- SSA construction -----------------------------------------------------------------------------------------------

# Scalar slots that are used only as the address of a load or store of their own type. Returns "$name" => type.
def promotable_slots(fn)
  types = fn.slots.to_h { |s| ["$#{s[1].raw}", s[2]] }
  bad = {}
  twice = fn.body.map { |s| scan_slot_uses(s, types, bad) }.any?
  return {} if twice

  types.select { |k, t| !bad[k] && scalar_type?(t) }
end

# Marks slots used any other way; returns true when the code calls a function that returns twice.
# A load or store of a slot has the slot's type up to a top-level const (a const pointer slot is read as its pointer).
def same_slot_type?(a, b)
  strip = ->(t) { head(t) == "const" ? strip.call(t[1]) : t }
  strip.call(a) == strip.call(b)
end

def scan_slot_uses(x, types, bad)
  if x.is_a?(Ref)
    return x.sigil == "&" && SETJMP_NAMES.include?(x.raw)
  end
  return false unless x.is_a?(Array)

  h = head(x)
  twice = false
  x.each_with_index do |y, i|
    if y.is_a?(Ref) && y.sigil == "$"
      key = "$#{y.raw}"
      ok = (h == "load" || h == "store") && i == 2 && types[key] && same_slot_type?(x[1], types[key])
      # The scope facts (NFCXX_IR_SCOPES=1) name a slot without taking its address: they do not stop its promotion.
      ok ||= (h == "decl" || h == "scope-end") && i == 1
      bad[key] = true unless ok
    else
      twice ||= scan_slot_uses(y, types, bad)
    end
  end
  twice
end

def pure_rv?(rv) = rv.is_a?(String) || (rv.is_a?(Array) && PURE_OPS.include?(head(rv)))

def zero_of(t) = head(t) == "ptr" ? ["null", t] : ["const", t, "0"]

class Converter
  attr_reader :out, :rpo, :promoted, :mut

  def initialize(fn)
    @fn = fn
    @void = fn.ret[1] == "void"
    @promoted = promotable_slots(fn)
    @cfg = Cfg.new.build(fn.body, @void).blocks
    @types = {}   # variable => IR type (promoted slots and registers assigned with set)
    @mut = {}     # register => true when some set assigns it
    @subst = {}   # register bound to a promoted load => operand
    @stacks = Hash.new { |h, k| h[k] = [] }
    @fresh = 0
    @reg_types = {}   # every parameter and register declared with let: the type a switch operand compares as
    fn.params[1..].each { |p| @reg_types[p[1]] = p[3] if head(p) == "param" }
    @cfg.each { |b| b.instrs.each { |i| @reg_types[i[1]] = i[2] if head(i) == "let" } }
  end

  def run
    reachable_order
    dominators
    collect_vars
    place_phis
    @types.each_key { |v| @stacks[v] = [zero_of(@types[v])] }
    rename(0)
    simplify
    verify
    self
  end

  def render
    lines = ["(ssa-function #{sx(@fn.name)}", "  #{sx(@fn.ret)}", "  #{sx(@fn.params)}"]
    (@fn.attrs || []).each { |a| lines << "  #{sx(a)}" }
    @fn.slots.each { |s| lines << "  #{sx(s)}" unless @promoted.key?("$#{s[1].raw}") }
    lines << "  (ssa-promoted #{@promoted.keys.map { |k| k[1..] }.join(' ')})"
    @rpo.sort.each do |b|
      blk = @out[b]
      lines << "  (bb #{b}"
      blk[:phis].each { |ph| lines << "    (phi #{ph.name} #{sx(ph.type)} #{ph.inc.keys.sort.map { |p| sx([p, ph.inc[p]]) }.join(' ')})" }
      blk[:instrs].each { |i| lines << "    #{sx(i)}" }
      lines << "    #{term_text(blk[:term])})"
    end
    lines << ")"
    lines.join("\n")
  end

  private

  def reachable_order
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
      succs(@cfg[b].term).reverse_each { |s| stack.push([s, false]) unless seen[s] }
    end
    @rpo = post.reverse
    @rpo_idx = @rpo.each_with_index.to_h
  end

  # Cooper, Harvey and Kennedy's iterative dominators, dominance frontiers and the dominator tree.
  def dominators
    @preds = Hash.new { |h, k| h[k] = [] }
    @rpo.each { |b| succs(@cfg[b].term).uniq.each { |s| @preds[s] << b } }
    @idom = { 0 => 0 }
    changed = true
    while changed
      changed = false
      @rpo.drop(1).each do |b|
        new_idom = nil
        @preds[b].each do |p|
          next unless @idom.key?(p)

          new_idom = new_idom.nil? ? p : intersect(p, new_idom)
        end
        next if @idom[b] == new_idom

        @idom[b] = new_idom
        changed = true
      end
    end
    @df = Hash.new { |h, k| h[k] = [] }
    @rpo.each do |b|
      next if @preds[b].size < 2

      @preds[b].each do |p|
        runner = p
        while runner != @idom[b]
          @df[runner] << b unless @df[runner].include?(b)
          runner = @idom[runner]
        end
      end
    end
    @children = Hash.new { |h, k| h[k] = [] }
    @rpo.drop(1).each { |b| @children[@idom[b]] << b }
  end

  def intersect(a, b)
    while a != b
      a = @idom[a] while @rpo_idx[a] > @rpo_idx[b]
      b = @idom[b] while @rpo_idx[b] > @rpo_idx[a]
    end
    a
  end

  def dominates?(a, b)
    # A while, not loop: the returns leave a block that a native loop calls, which a compiled build cannot cross.
    while true
      return true if a == b
      return false if b == 0

      b = @idom[b]
    end
  end

  def collect_vars
    instrs = @rpo.flat_map { |b| @cfg[b].instrs }
    instrs.each { |i| @mut[i[1]] = true if head(i) == "set" }
    instrs.each { |i| @types[i[1]] = i[2] if head(i) == "let" && @mut[i[1]] }
    @mut.each_key { |r| raise Unsupported, "register #{r} is assigned but never declared" unless @types.key?(r) }
    @promoted.each { |k, t| @types[k] = t }
  end

  def def_sites
    sites = Hash.new { |h, k| h[k] = [] }
    @rpo.each do |b|
      @cfg[b].instrs.each do |i|
        case head(i)
        when "let" then sites[i[1]] << b if @mut[i[1]]
        when "set" then sites[i[1]] << b
        when "store"
          k = slot_key(i[2])
          sites[k] << b if k && @promoted.key?(k)
        end
      end
    end
    sites
  end

  def place_phis
    sites = def_sites
    @phis = Hash.new { |h, k| h[k] = {} }
    @types.each_key do |v|
      defs = (sites[v] + [0]).uniq
      work = defs.dup
      placed = {}
      until work.empty?
        x = work.pop
        @df[x].each do |y|
          next if placed[y]

          placed[y] = true
          @phis[y][v] = Phi.new(v, nil, @types[v], {})
          work << y unless defs.include?(y)
        end
      end
    end
  end

  def fresh = "%s#{@fresh += 1}"
  def cur(v) = @stacks[v].last

  def push(v, val, pushed)
    @stacks[v].push(val)
    pushed << v
  end

  # Operands: a register that is a variable is replaced by its current value; a load result by what it loaded.
  def rw(x)
    case x
    when Array then x.map { |y| rw(y) }
    when String
      return x unless x.start_with?("%")
      return cur(x) if @mut[x]

      @subst.fetch(x, x)
    else x
    end
  end

  def promoted_load(rv)
    return nil unless head(rv) == "load"

    k = slot_key(rv[2])
    @promoted.key?(k) ? k : nil
  end

  # The renaming walk over the dominator tree from b: a block's statements are renamed before its children, in order, and
  # the names it pushed are popped after them. An explicit stack of [block, pushed names, next child] rather than a
  # recursion, since the tree of a long straight-line function is hundreds of blocks deep, past the interpreter's call limit.
  def rename(root)
    work = [[root, nil, 0]]
    until work.empty?
      frame = work.last
      b = frame[0]
      if frame[1].nil?
        pushed = []
        @phis[b].each_value do |ph|
          ph.name = fresh
          push(ph.var, ph.name, pushed)
        end
        instrs = []
        @cfg[b].instrs.each { |i| visit(i, instrs, pushed) }
        term = terminator(@cfg[b].term)
        @out ||= {}
        @out[b] = { phis: @phis[b].values, instrs: instrs, term: term }
        succs(term).each { |s| @phis[s].each_value { |ph| ph.inc[b] = cur(ph.var) } }
        frame[1] = pushed
      end
      kids = @children[b]
      if frame[2] < kids.size
        child = kids[frame[2]]
        frame[2] += 1
        work << [child, nil, 0]
      else
        frame[1].each { |v| @stacks[v].pop }
        work.pop
      end
    end
  end

  def visit(i, out, pushed)
    case head(i)
    when "let"
      reg, t, rv = i[1], i[2], i[3]
      src = promoted_load(rv)
      if @mut[reg]
        if src
          push(reg, cur(src), pushed)
        else
          name = fresh
          out << ["let", name, t, rw(rv)]
          push(reg, name, pushed)
        end
      elsif src
        @subst[reg] = cur(src)
      else
        out << ["let", reg, t, rw(rv)]
      end
    when "set" then push(i[1], rw(i[2]), pushed)
    when "decl", "scope-end"
      # (decl $"x" val|ref) at a local's declaration and (scope-end $"x") where its scope ends (NFCXX_IR_SCOPES=1): about a slot in
      # memory, for AddressSanitizer's use after scope (pathb-ssa-qbe.rb); a promoted slot has no memory, so its facts are dropped.
      k = slot_key(i[1])
      out << rw(i) unless k && @promoted.key?(k)
    when "store"
      k = slot_key(i[2])
      if k && @promoted.key?(k)
        push(k, rw(i[3]), pushed)
      else
        out << rw(i)
      end
    else out << rw(i)
    end
  end

  def terminator(t)
    case t[0]
    when "condbr" then ["condbr", rw(t[1]), t[2], t[3]]
    when "ret" then t.size > 1 ? ["ret", rw(t[1])] : ["ret"]
    when "switch" then switch_term(t)
    else t
    end
  end

  # ["switch", OP, [[V, B]...], D] with each V canonical for the operand's integer type.
  def switch_term(t)
    ty = operand_type(t[1])
    cases = t[2].map { |v, b| [canon(v, ty), b] }
    dup = cases.map(&:first).tally.find { |_, n| n > 1 }
    raise Fail, "duplicate case #{dup[0]} in a switch" if dup

    ["switch", rw(t[1]), cases, t[3]]
  end

  def operand_type(op)
    return op[1] if head(op) == "const"
    raise Unsupported, "switch operand #{sx(op)}" unless reg?(op)

    @reg_types.fetch(op) { raise Unsupported, "switch operand #{op} has no declared type" }
  end

  def term_text(t)
    return sx(t) unless t[0] == "switch"

    arms = t[2].map { |v, b| "(case #{v} #{b})" } + ["(default #{t[3]})"]
    "(switch #{sx(t[1])} #{arms.join(' ')})"
  end

  # Replaces phis whose arguments are all one value (or themselves), then drops phis nothing uses.
  def simplify
    repl = {}
    while true
      changed = false
      @out.each_value do |blk|
        blk[:phis].reject! do |ph|
          others = ph.inc.values.map { |v| resolve(v, repl) }.reject { |v| v == ph.name }
          next false if others.empty? || others.map { |v| sx(v) }.uniq.size != 1

          repl[ph.name] = others.first
          changed = true
        end
      end
      break unless changed
    end
    @out.each_value do |blk|
      blk[:instrs] = blk[:instrs].map { |i| map_atoms(i, repl) }
      blk[:term] = map_atoms(blk[:term], repl)
      blk[:phis].each { |ph| ph.inc.transform_values! { |v| map_atoms(v, repl) } }
    end
    while true
      uses = Hash.new(0)
      @out.each_value do |blk|
        blk[:instrs].each { |i| count_atoms(head(i) == "let" ? i[2..] : i[1..], uses) }
        count_atoms(blk[:term], uses)
        blk[:phis].each { |ph| ph.inc.each_value { |v| count_atoms(v, uses) } }
      end
      removed = false
      @out.each_value do |blk|
        blk[:phis].reject! do |ph|
          next false unless uses[ph.name].zero?

          removed = true
        end
        blk[:instrs].reject! do |i|
          next false unless head(i) == "let" && uses[i[1]].zero? && pure_rv?(i[3])

          removed = true
        end
      end
      break unless removed
    end
  end

  def resolve(a, repl)
    return a unless a.is_a?(String) && repl.key?(a)

    resolve(repl[a], repl)
  end

  def map_atoms(x, repl)
    case x
    when Array then x.map { |y| map_atoms(y, repl) }
    when String then reg?(x) ? resolve(x, repl) : x
    else x
    end
  end

  def count_atoms(x, uses)
    case x
    when Array then x.each { |y| count_atoms(y, uses) }
    when String then uses[x] += 1 if reg?(x)
    end
  end

  def atoms(x, out = [])
    case x
    when Array then x.each { |y| atoms(y, out) }
    when String then out << x if reg?(x)
    end
    out
  end

  # Verification: single definitions, dominance of every use, and phi arguments per predecessor.
  def verify
    params = @fn.params[1..].filter_map { |p| p[1] if p.is_a?(Array) && reg?(p[1]) }
    defs = {}
    define = lambda do |name, b, idx|
      raise Fail, "#{name} is defined twice" if defs.key?(name)

      defs[name] = [b, idx]
    end
    @rpo.each do |b|
      @out[b][:phis].each { |ph| define.(ph.name, b, -1) }
      @out[b][:instrs].each_with_index { |i, k| define.(i[1], b, k) if head(i) == "let" }
    end
    check = lambda do |a, b, k|
      next if params.include?(a)
      raise Fail, "#{a} is used in B#{b} but never defined" unless defs.key?(a)

      db, di = defs[a]
      ok = db == b ? di < k : dominates?(db, b)
      raise Fail, "#{a} (defined in B#{db}) does not dominate its use in B#{b}" unless ok
    end
    @rpo.each do |b|
      blk = @out[b]
      blk[:phis].each do |ph|
        unless ph.inc.keys.sort == @preds[b].sort
          raise Fail, "phi #{ph.name} in B#{b}: arguments from #{ph.inc.keys.sort}, predecessors #{@preds[b].sort}"
        end
        ph.inc.each { |p, v| atoms(v).each { |a| check.(a, p, Float::INFINITY) } }
      end
      blk[:instrs].each_with_index do |i, k|
        uses = head(i) == "let" ? i[2..] : i[1..]
        atoms(uses).each { |a| check.(a, b, k) }
      end
      atoms(blk[:term][1..]).each { |a| check.(a, b, blk[:instrs].size) }
    end
  end
end

# ---- interpreter (differential check) -------------------------------------------------------------------------------

INT_TYPES = {
  "bool" => [1, false], "char" => [8, true], "signed_char" => [8, true], "unsigned_char" => [8, false],
  "short" => [16, true], "unsigned_short" => [16, false], "int" => [32, true], "unsigned_int" => [32, false],
  "long" => [64, true], "long_long" => [64, true], "unsigned_long" => [64, false],
  "unsigned_long_long" => [64, false]
}.freeze

# A qualifier does not change a value: `(const T)` is T for the interpreter.
def strip_const(t) = head(t) == "const" ? strip_const(t[1]) : t

def int_info(t)
  t = strip_const(t)
  return [64, false] if head(t) == "ptr"

  INT_TYPES.fetch(t) { raise Unsupported, "type #{sx(t)} in the interpreter" }
end

# A literal operand: an integer as read from the IR (a string) or already an Integer.
def int_lit(x) = x.is_a?(Integer) ? x : Integer(x.to_s, 10)

def canon(v, t)
  w, signed = int_info(t)
  return(v.zero? ? 0 : 1) if t == "bool"

  m = v & ((1 << w) - 1)
  signed && m >= (1 << (w - 1)) ? m - (1 << w) : m
end

# Floats. A `double` is a Ruby Float (IEEE binary64). A `float` is rounded to single precision after every operation,
# which is exact for + - * / and conversions: a double has enough bits that rounding twice is the same as rounding
# once. Overflow gives an infinity, as IEEE does. NaN payloads and the sign of a NaN are not modelled.
FLOAT_TYPES = { "float" => 32, "double" => 64 }.freeze

def float_type?(t) = (t = strip_const(t)).is_a?(String) && FLOAT_TYPES.key?(t)

def round_float(v, t)
  raise Unsupported, "float type #{sx(t)} in the interpreter" unless float_type?(t)

  f = v.to_f
  t == "float" ? to_float32(f) : f
end

# The float nearest to the double f (ties to even). pack("f") gives an infinity for any double above FLT_MAX, but IEEE
# rounds the doubles below FLT_MAX + half an ulp (2**128 - 2**103) down to FLT_MAX: the front end prints FLT_MAX as the
# float literal 3.4028235E38, which is one of them.
FLT_MAX_VALUE = 3.4028234663852886e+38
FLT_OVERFLOW_AT = 3.4028235677973366e+38

def to_float32(f)
  r = [f].pack("f").unpack1("f")
  return r unless r.infinite? && !f.infinite? && f.abs < FLT_OVERFLOW_AT

  f.positive? ? FLT_MAX_VALUE : -FLT_MAX_VALUE
end

# An integer converted to a float is exact up to 2**53. Beyond that, rounding through a double before the float
# is not the IEEE conversion, so it is not modelled.
def int_to_float(a, t)
  raise Unsupported, "integer to float beyond 2**53" if a.abs > 2**53

  round_float(a, t)
end

# A float converted to an integer truncates toward zero. NaN, infinities and values outside the target type trap
# (docs/notes/pathb-stage2.md, cf2i).
def float_to_int(x, t)
  raise Trap, "float to integer of NaN or infinity" if x.nan? || x.infinite?

  v = x.truncate
  w, signed = int_info(t)
  lo = signed ? -(1 << (w - 1)) : 0
  hi = signed ? (1 << (w - 1)) - 1 : (1 << w) - 1
  raise Trap, "float to integer out of range" unless v.between?(lo, hi)

  canon(v, t)
end

# The globals of the module being interpreted (install_module). A global is an object at an address above the slots.
# Its initial cells come from its initialiser. A global with no definition here (extern), a thread-local one, or an
# initialiser the interpreter does not model (bytes, bitfield, a function address) is unsupported: any access raises.
GLOBAL_TABLE = Struct.new(:addr, :init, :unsupported).new({}, [], {})
FUNCTION_FORMS = {}   # name (quoted) => ssa-function form of the module
FUNCTION_BLOCKS = {}  # name => the blocks of that function, parsed on first call
EH_TLS_GLOBALS = %w[__curr_eh_stack_entry __eh_curr_region __caught_object_address __catch_clause_number].map { |n| "\"#{n}\"" }.freeze

# The value of a literal operand of an initialiser: a constant of an integer or float type, or a null pointer.
def literal(v, type)
  return 0 if head(v) == "null"
  raise Unsupported, "initialiser #{sx(v)}" unless head(v) == "const"

  if float_type?(v[1])
    # NaN is written as text that Float() cannot read (normalise_literals). Its value here is the positive quiet NaN, as
    # the QBE emitter spells it (Qbe.float_lit).
    return Float::NAN if v[2].is_a?(String) && v[2].downcase.include?("nan")

    round_float(Float(v[2]), v[1])
  else
    canon(int_lit(v[2]), v[1])
  end
end

def install_module(forms)
  FUNCTION_FORMS.clear
  FUNCTION_BLOCKS.clear
  forms.each { |f| FUNCTION_FORMS[f[1].raw] = f if head(f) == "ssa-function" }
  GLOBAL_TABLE.addr.clear
  GLOBAL_TABLE.init.clear
  GLOBAL_TABLE.unsupported.clear
  gs = forms.select { |g| head(g) == "global" }
  top = 1 << 32
  gs.each do |g|
    size = int_lit(g[3])
    align = [int_lit(g[4]), 1].max
    top = (top + align - 1) / align * align
    GLOBAL_TABLE.addr[g[1].raw] = top
    top += size
  end
  gs.each do |g|
    name = g[1].raw
    base = GLOBAL_TABLE.addr[name]
    begin
    init = g.find { |x| head(x) == "init" }
    flags = g.map { |x| x.is_a?(Array) ? head(x) : x }
    # The exception runtime's thread-local state (EDG's libC) starts at zero in a fresh process, as any thread-local
    # object does. A run of the interpreter is a fresh process, so these four are zero-initialised. Their runtime
    # functions (__throw, _setjmp, ...) are still unsupported.
    if init.nil? && flags.include?("thread") && flags.include?("extern") && EH_TLS_GLOBALS.include?(name)
      GLOBAL_TABLE.init << [base, sx(strip_const(g[2])), 0]
      next
    end
    if init.nil? || flags.include?("extern") || flags.include?("thread") || init.size == 1
      GLOBAL_TABLE.unsupported[name] = true
      next
    end
    init[1..].each do |item|
      case head(item)
      when "zero" then nil
      when "scalar"
        off, type, v = item[1..]
        GLOBAL_TABLE.init << [base + int_lit(off), sx(strip_const(type)), literal(v, type)]
      when "addr"
        off, type, target, add = item[1..]
        if target.is_a?(Ref) && target.sigil == "@" && GLOBAL_TABLE.addr.key?(target.raw)
          GLOBAL_TABLE.init << [base + int_lit(off), sx(strip_const(type)), GLOBAL_TABLE.addr[target.raw] + int_lit(add)]
        else
          GLOBAL_TABLE.unsupported[name] = true
        end
      else
        GLOBAL_TABLE.unsupported[name] = true
      end
    end
    rescue Unsupported, ArgumentError, TypeError, NoMethodError
      GLOBAL_TABLE.unsupported[name] = true
    end
  end
end

# A structured statement's way out of the statement list it ran in: break, continue or return. exec and exec_list hand one
# back to their caller (nil when the statement falls through); a throw across the native each of a compiled build is an
# error there, so the exits are values.
class Flow
  attr_reader :kind, :value

  def initialize(kind, value = nil)
    @kind = kind
    @value = value
  end
end
FLOW_BREAK = Flow.new(:break)
FLOW_CONTINUE = Flow.new(:continue)

class Machine
  class << self
    # Parses an ssa-function form into an object with blocks (pathb-egraph sets it).
    attr_accessor :function_parser
  end

  BIN = { "wadd" => :+, "wsub" => :-, "wmul" => :*, "and" => :&, "or" => :|, "xor" => :^ }.freeze
  CMP = { "lt.s" => :<, "lt.u" => :<, "le.s" => :<=, "le.u" => :<=, "eq" => :==, "ne" => :!=,
          "lt.f" => :<, "le.f" => :<= }.freeze
  FBIN = { "fadd" => :+, "fsub" => :-, "fmul" => :*, "fdiv" => :/ }.freeze

  # budget: nil, or the number of steps a run may take (one per block entered and one per instruction executed, all
  # frames of the run together). Exceeding it raises StepLimit. Steps are counted in the heap, which the frames of a
  # run share, so the count depends only on the program and its input, never on the machine's speed.
  def initialize(fn, args, heap = nil, budget: nil)
    @env = {}
    @jmps = {}      # the _setjmp sites of this frame: jump buffer address => where to resume
    @heap = heap || { cells: {}, next: 4096, depth: 0, steps: 0, budget: budget }
    @cells = @heap[:cells]  # address => [type, value]: a scalar object at an address (no byte-level aliasing)
    GLOBAL_TABLE.init.each { |a, t, v| @cells[a] = [t, v] } unless heap
    @addr = {}      # slot key => address of the slot's object
    @slot_type = {} # slot key => its type
    layout_slots(fn)
    raise Unsupported, "main takes only plain parameters" unless fn.params[1..].all? { |p| head(p) == "param" }

    params = fn.params[1..]
    raise Unsupported, "main takes #{params.size} arguments" unless params.size == args.size

    # An index loop, not zip: the zip of a compiled build walks its arguments with Enumerator#next, a Fiber a compiled
    # build does not run.
    pi = 0
    while pi < params.size
      p = params[pi]
      a = args[pi]
      @env[p[1]] = float_type?(p[3]) ? round_float(a, p[3]) : canon(a, p[3])
      pi += 1
    end
  end

  def run_structured(body)
    r = exec_list(body)
    return nil unless r
    return r.value if r.kind == :ret

    raise ArgumentError, "uncaught throw :#{r.kind == :break ? 'brk' : 'cont'}"
  end

  def run_ssa(out)
    b = 0
    prev = nil
    steps = 0
    start = 0
    # A while, not loop: the return and the next below leave a block that a native loop calls, which a compiled build
    # cannot cross.
    while true
      raise Unsupported, "step limit" if (steps += 1) > 1_000_000

      blk = out.fetch(b)
      tick
      # A resumed block (start > 0) has its phis already evaluated; they are not evaluated again.
      blk[:phis].map { |ph| [ph.name, val(ph.inc.fetch(prev))] }.each { |n, v| @env[n] = v } if start.zero?
      begin
        idx = start
        while idx < blk[:instrs].size
          ins = blk[:instrs][idx]
          tick
          if setjmp_site?(ins)
            @jmps[addr_of(ins[3][3])] = { name: ins[1], block: b, index: idx + 1 }
            @env[ins[1]] = 0
          else
            exec(ins)
          end
          idx += 1
        end
      rescue LongJump => e
        entry = @jmps[e.buf]
        # No frame of this run holds a _setjmp for the buffer: the jump leaves the run, which is not modelled.
        raise Unsupported, "longjmp to a buffer not set in this run" if entry.nil? && @heap[:depth].zero?
        raise unless entry
        @env[entry[:name]] = e.value.zero? ? 1 : e.value
        b = entry[:block]
        start = entry[:index]
        next
      end
      start = 0
      t = blk[:term]
      case t[0]
      when "br" then prev, b = b, t[1]
      when "condbr"
        c = val(t[1]) != 0
        prev = b
        b = c ? t[2] : t[3]
      when "switch"
        c = val(t[1])
        hit = t[2].find { |v, _| v == c }
        prev, b = b, (hit ? hit[1] : t[3])
      when "ret" then return t.size > 1 ? val(t[1]) : nil
      when "unreachable" then raise Trap, "unreachable"
      end
    end
  end
  private

  # Runs the statements in order; stops at the first one that exits (a Flow) and hands that exit back.
  # A while loop, not each: a return from the block of a native each is a throw across a C function in a compiled build.
  def exec_list(stmts)
    i = 0
    n = stmts.size
    while i < n
      r = exec(stmts[i])
      return r if r.is_a?(Flow)

      i += 1
    end
    nil
  end

  # Counts one step of the run's budget (see initialize).
  def tick
    h = @heap
    h[:steps] += 1
    raise StepLimit, "step budget #{h[:budget]} exhausted" if h[:budget] && h[:steps] > h[:budget]
  end

  # The call of a _setjmp: `(let R int (call int &"_setjmp" BUF))`.
  def setjmp_site?(ins)
    head(ins) == "let" && head(ins[3]) == "call" && ins[3][2].is_a?(Ref) && ins[3][2].raw == '"_setjmp"'
  end

  # A call. A longjmp raises LongJump. A function of the module runs in a new frame that shares this run's heap.
  # Any other callee is not modelled.
  def call_fn(f)
    raise Unsupported, "indirect call" unless f[2].is_a?(Ref) && f[2].sigil == "&"

    name = f[2].raw
    args = f[3..]
    if %w["longjmp" "_longjmp" "siglongjmp"].include?(name)
      raise LongJump.new(args[0].is_a?(Ref) ? addr_of(args[0]) : val(args[0]), val(args[1]))
    end
    form = FUNCTION_FORMS.fetch(name) { raise Unsupported, "call of #{name}" }
    raise Unsupported, "call depth" if @heap[:depth] >= 200

    fn = fn_of(form)
    blocks = (FUNCTION_BLOCKS[name] ||= Machine.function_parser.call(form).blocks)
    values = args.map { |a| a.is_a?(Ref) ? addr_of(a) : val(a) }
    @heap[:depth] += 1
    begin
      Machine.new(fn, values, @heap).run_ssa(blocks)
    ensure
      @heap[:depth] -= 1
    end
  end

  # Each slot is an object at an address; the addresses are assigned in declaration order, aligned, from 4096.
  def layout_slots(fn)
    top = @heap[:next]
    fn.slots.select { |s| head(s) == "slot" }.each do |s|
      size, align = s[3] ? [int_lit(s[3]), [int_lit(s[4]), 1].max] : scalar_size(s[2])
      top = (top + align - 1) / align * align
      @addr["$#{s[1].raw}"] = top
      @slot_type["$#{s[1].raw}"] = s[2]
      top += size
    end
    @heap[:next] = top
  end

# Size and alignment of a scalar type of the LP64 layout (the slot headers of an optimized function carry none).
def scalar_size(t)
  t = strip_const(t)
  return [8, 8] if head(t) == "ptr"

  size = { "bool" => 1, "char" => 1, "signed_char" => 1, "unsigned_char" => 1, "short" => 2, "unsigned_short" => 2,
           "int" => 4, "unsigned_int" => 4, "float" => 4, "long" => 8, "long_long" => 8, "unsigned_long" => 8,
           "unsigned_long_long" => 8, "double" => 8 }[t] or raise Unsupported, "slot of type #{sx(t)}"
  [size, size]
end

  # The address an address operand names: a slot, or a pointer value.
  def addr_of(x)
    return val(x) unless x.is_a?(Ref)
    if x.sigil == "@"
      raise Unsupported, "global #{x.raw}" if GLOBAL_TABLE.unsupported.key?(x.raw)

      return GLOBAL_TABLE.addr.fetch(x.raw) { raise Unsupported, "global #{x.raw}" }
    end
    raise Unsupported, "address #{sx(x)}" unless x.sigil == "$"

    @addr.fetch("$#{x.raw}") { raise Unsupported, "slot #{x.raw}" }
  end

  # A load reads the object at the address. An object never stored reads as zero. A load of another type than the
  # object's (a type-punned access) is not modelled.
  def load_cell(t, a)
    return(float_type?(t) ? 0.0 : 0) unless @cells.key?(a)

    type, v = @cells[a]
    raise Unsupported, "a #{sx(t)} access of a #{sx(type)} object" unless sx(strip_const(type)) == sx(strip_const(t))

    v
  end

  def store_cell(t, a, v) = @cells[a] = [sx(strip_const(t)), v]

  # Copies the n bytes at src to dst: the cells of the source range move (each keeps its type) and the destination
  # range's cells are replaced; a destination cell with no source cell becomes zero.
  def copy_cells(dst, src, n)
    moved = @cells.select { |a, _| a >= src && a < src + n }
    (dst...dst + n).each { |a| @cells.delete(a) }
    moved.each { |a, c| @cells[dst + (a - src)] = c }
  end

  # The slot whose object starts at the address, or nil.
  def slot_at(a) = @addr.key(a)

  # The matching marker is found first; the body then runs from it, so statements after it fall through. A switch
  # with no matching marker and no default runs nothing. `break` leaves the switch (its catch is the innermost).
  def exec_switch(s)
    v = val(s[1])
    stmts = clause(s, "body")
    markers = switch_markers(stmts)
    hit = markers.find { |m| head(m) == "case" && val(m[1]) == v } || markers.find { |m| head(m) == "default" }
    return unless hit

    saved = [@hit, @entered]
    @hit = hit
    @entered = false
    r = nil
    begin
      r = exec_switch_body(stmts)
    ensure
      @hit, @entered = saved
    end
    # `break` leaves the switch; a continue or a return goes on to the enclosing loop or function.
    r.equal?(FLOW_BREAK) ? nil : r
  end

  # Statements before the entry marker are skipped; blocks are entered so that a marker inside one is reached.
  def exec_switch_body(stmts)
    i = 0
    n = stmts.size
    while i < n
      st = stmts[i]
      i += 1
      case head(st)
      when "case", "default" then @entered ||= st.equal?(@hit)
      when "block"
        r = exec_switch_body(st[1..])
        return r if r.is_a?(Flow)
      else
        if @entered
          r = exec(st)
          return r if r.is_a?(Flow)
        end
      end
    end
    nil
  end

  # Markers are interpreted only at block level in the switch body (inside nested blocks, not in if or loop).
  def switch_markers(stmts, out = [])
    stmts.each do |st|
      case head(st)
      when "case", "default" then out << st
      when "block" then switch_markers(st[1..], out)
      else raise Unsupported, "case label inside #{head(st) || 'a statement'}" if contains_marker?(st)
      end
    end
    out
  end

  def contains_marker?(x)
    return false unless x.is_a?(Array) && head(x) != "switch"
    return true if %w[case default].include?(head(x))

    x.any? { |y| contains_marker?(y) }
  end

  # A loop: the body, then the step, until a break. A continue in the body goes on to the step; a continue in the step, and
  # a return anywhere, leave the loop for the enclosing one.
  def exec_loop(s)
    while true
      r = exec_list(clause(s, "body"))
      if r
        return nil if r.equal?(FLOW_BREAK)
        return r unless r.equal?(FLOW_CONTINUE)
      end
      r = exec_list(clause(s, "step"))
      if r
        return nil if r.equal?(FLOW_BREAK)

        return r
      end
    end
  end

  def exec(s)
    case head(s)
    when "let" then @env[s[1]] = val(s[3])
    when "set" then @env[s[1]] = val(s[2])
    when "store" then store_cell(s[1], addr_of(s[2]), val(s[3]))
    when "copy" then copy_cells(addr_of(s[2]), addr_of(s[3]), int_lit(s[1]))
    when "nonnull"
      raise Trap, "null pointer" if val(s[1]).zero?
    when "bounds"
      i = val(s[1])
      raise Trap, "index #{i} out of bounds" unless i >= 0 && i < int_lit(s[2])
    when "block" then exec_list(s[1..])
    when "if" then exec_list(val(s[1]) != 0 ? clause(s, "then") : clause(s, "else"))
    when "switch" then exec_switch(s)
    when "loop" then exec_loop(s)
    when "break" then FLOW_BREAK
    when "continue" then FLOW_CONTINUE
    when "return" then Flow.new(:ret, s.size > 1 ? val(s[1]) : nil)
    when "eval" then call_fn(s[1])
    when "unreachable" then raise Trap, "unreachable"
    else raise Unsupported, "statement #{head(s) || sx(s)}"
    end
  end

  def val(x)
    case x
    when String
      @env.fetch(x) { raise Unsupported, "unbound #{x}" }
    when Array
      case head(x)
      when "const"
        if float_type?(x[1])
          raise Unsupported, "float constant #{sx(x)}" unless float_literal?(x[2])

          return round_float(Float(x[2]), x[1])
        end
        raise Unsupported, "constant #{sx(x)}" unless int_literal?(x[2])

        canon(x[2].to_i, x[1])
      when "null" then 0
      else eval_rv(x)
      end
    when Ref then addr_of(x)
    else raise Unsupported, sx(x)
    end
  end

  def eval_rv(f)
    case head(f)
    when "load" then load_cell(f[1], addr_of(f[2]))
    when "call" then call_fn(f)
    when "addr" then addr_of(f[1])
    when "offset" then addr_of(f[1]) + int_lit(f[2])
    when "index" then addr_of(f[1]) + val(f[2]) * int_lit(f[3])
    when "bitcast"
      # Only a pointer-to-pointer cast keeps the value; any other cast reinterprets bits, which is not modelled.
      raise Unsupported, "bitcast to #{sx(f[1])}" unless head(f[1]) == "ptr" && (head(f[2]) == "ptr" || f[2].is_a?(Ref))

      addr_of(f[2])
    when "iconv" then canon(val(f[2]), f[1])
    when *FBIN.keys then round_float(val(f[2]).send(FBIN[head(f)], val(f[3])), f[1])
    when "fneg" then -val(f[2])
    # A wrapping negation, and `not`: a complement of an integer's bits, a logical negation of a bool (the emitter's rule).
    when "wneg" then canon(-val(f[2]), f[1])
    when "not" then f[1] == "bool" ? (val(f[2]).zero? ? 1 : 0) : canon(~val(f[2]), f[1])
    when "i2f", "u2f" then int_to_float(val(f[2]), f[1])
    when "cf2i" then float_to_int(val(f[2]), f[1])
    when "fconv" then round_float(val(f[2]), f[1])
    when *BIN.keys then canon(val(f[2]).send(BIN[head(f)], val(f[3])), f[1])
    when *CMP.keys then val(f[2]).send(CMP[head(f)], val(f[3])) ? 1 : 0
    when "cdiv", "crem"
      a = val(f[2])
      b = val(f[3])
      raise Trap, "division by zero" if b.zero?

      w, signed = int_info(f[1])
      raise Trap, "overflow" if signed && a == -(1 << (w - 1)) && b == -1

      q = a.abs / b.abs
      q = -q if (a.negative? ^ b.negative?)
      head(f) == "cdiv" ? canon(q, f[1]) : canon(a - q * b, f[1])
    when "wshl"
      # A left shift of the two's complement pattern, wrapped to the type (no overflow check). A count that is negative
      # or not below the bit width traps, as cshl's does.
      w, = int_info(f[1])
      n = val(f[3])
      raise Trap, "shift count #{n} of #{w} bits" unless n >= 0 && n < w

      canon(val(f[2]) << n, f[1])
    else raise Unsupported, "operator #{head(f) || sx(f)}"
    end
  end
end

# ---- driver ---------------------------------------------------------------------------------------------------------

# Literal shapes the converter reads, as character scans (the script-world build has no Regexp). A non-string is not a
# literal, as `=~` on it would not match.
HEX_DIGITS = "0123456789abcdefABCDEF"

def hex_literal?(s)
  return false unless s.is_a?(String)

  t = s.start_with?("+", "-") ? s[1..] : s
  t.length >= 3 && t[0] == "0" && (t[1] == "x" || t[1] == "X") && t[2..].each_char.all? { |c| HEX_DIGITS.include?(c) }
end

def int_literal?(s)
  return false unless s.is_a?(String)

  t = s.start_with?("-") ? s[1..] : s
  !t.empty? && t.each_char.all? { |c| c >= "0" && c <= "9" }
end

def float_literal?(s)
  return false unless s.is_a?(String)

  t = s.start_with?("-") ? s[1..] : s
  n = t.length
  digits = ->(j) { k = j; k += 1 while k < n && t[k] >= "0" && t[k] <= "9"; k }
  j = digits.(0)
  return false if j == 0
  if j < n && t[j] == "."
    k = digits.(j + 1)
    return false if k == j + 1
    j = k
  end
  if j < n && (t[j] == "e" || t[j] == "E")
    j += 1
    j += 1 if j < n && (t[j] == "+" || t[j] == "-")
    k = digits.(j)
    return false if k == j
    j = k
  end
  j == n
end

# Converts the functions of a module (the forms of an IR file) to SSA: the printed forms in order (the other forms
# unchanged), then the counts of functions seen, converted and promoted slots, and `main`'s structured and SSA forms; nil
# when a converted function does not verify (the message is on stderr already).
# live: a Hash of the names a caller keeps ({ "name" => true }): a function outside it is skipped, not converted (its
# conversion would be dropped afterwards; scripts/pathb-ssa-build's prune). nil converts every function.
def convert_module(forms, live = nil)
  install_module(forms)
  converted = 0
  functions = 0
  promoted_total = 0
  main_fn = nil
  main_out = nil
  output = []
  fi = 0
  while fi < forms.size
    form = forms[fi]
    fi += 1
    unless head(form) == "function"
      output << sx(form)
      next
    end
    next if live && !live.key?(form[1].raw.delete('"'))

    functions += 1
    fn = fn_of(form)
    begin
      conv = Converter.new(fn).run
    rescue Unsupported => e
      $stderr.write(("pathb-ssa: #{sx(fn.name)}: #{e.message}; left unconverted") + "\n")
      output << sx(form)
      next
    rescue Fail => e
      $stderr.write(("pathb-ssa: VERIFY FAILED in #{sx(fn.name)}: #{e.message}") + "\n")
      return nil
    end
    converted += 1
    promoted_total += conv.promoted.size
    if fn.name.raw == '"main"'
      main_fn = fn
      main_out = conv.out
    end
    output << conv.render
  end
  [output, functions, converted, promoted_total, main_fn, main_out]
end

def main(argv)
  mode = :print
  run_args = []
  if argv.first == "--check"
    mode = :check
    argv.shift
  elsif argv.first == "--run"
    mode = :run
    argv.shift
    run_args = argv[0..-2].map { |a| Integer(a, 10) }
    argv = argv[-1..]
  end
  file = argv.last
  unless file
    $stderr.write(("usage: pathb-ssa.rb [--check | --run N...] FILE.ir") + "\n")
    return 1
  end

  forms = read_forms(File.read(file))
  result = convert_module(forms)
  return 1 if result.nil?

  output, functions, converted, promoted_total, main_fn, main_out = result

  case mode
  when :check
    $stderr.write(("pathb-ssa: #{functions} functions, #{converted} converted, #{promoted_total} slots promoted") + "\n")
  when :run
    raise Fail, "no main function" unless main_fn

    structured = begin
      Machine.new(main_fn, run_args).run_structured(main_fn.body)
    rescue Unsupported
      "unsupported"
    rescue Trap
      "trap"
    end
    ssa = begin
      Machine.new(main_fn, run_args).run_ssa(main_out)
    rescue Trap
      "trap"
    end
    puts "structured=#{structured} ssa=#{ssa}"
    return 1 if structured != "unsupported" && structured != ssa
  else
    puts output
  end
  0
rescue Unsupported => e
  $stderr.write(("pathb-ssa: #{e.message}") + "\n")
  2
rescue Fail => e
  $stderr.write(("pathb-ssa: #{e.message}") + "\n")
  1
end

# pathb-ssa-qbe.rb requires this file for its converter, so the command line runs only as the program.
if $0 == __FILE__
  rc = main(ARGV)
  exit(rc) if rc != 0
end

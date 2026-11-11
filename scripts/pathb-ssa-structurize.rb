#!/usr/bin/env ruby
# frozen_string_literal: false
#
# Path B: SSA to structured IR (docs/notes/pathb-structurize.md). Reads the SSA text of scripts/pathb-ssa.rb and writes a
# structured IR module (docs/notes/pathb-stage2.md, section 6) that the structured back ends accept, SPIR-V among them.
#
#   ruby scripts/pathb-ssa-structurize.rb [--verbose] [FILE.ssa | -] > out.ir
#
# Two methods, per function:
#   - structured: the CFG is rebuilt as loops (natural loops, a single exit each) and ifs (a block's two arms meet at its
#     immediate postdominator). A jump the structure cannot express raises Unstructurable.
#   - state machine (the fallback, any CFG): each SSA block is a case of a switch on a state register, the switch is the body
#     of a loop, and a block ends by setting the state and leaving the switch.
# A value that another block reads, or that a phi defines, is a register declared at the top of the function; a value used
# only in its own block stays a let, so the patterns the emitters read off a let (the closure cast) still work.
# --verbose prints the method chosen for each function on stderr.
#
# Exit status: 0 written; 1 malformed SSA (on stderr); 3 a type that cannot be zeroed.

class BadSSA < StandardError; end
class Refused < StandardError; end
class Unstructurable < StandardError; end

INT_TYPES = %w[bool char signed_char unsigned_char short unsigned_short int unsigned_int long unsigned_long long_long
               unsigned_long_long float double long_double std::float32_t std::float64_t].freeze

# The tokens of the SSA text: "(", ")", a double-quoted string (escapes with a backslash, an optional $ or & before the
# opening quote), or a run of characters that are neither white space nor parentheses. A character scan with the rules
# of the regexp it replaces, /\(|\)|[$&]?"(?:\\.|[^"\\])*"|[^\s()]+/ (the script world has no Regexp): an unterminated
# string falls back to the run, a backslash before a newline does not escape it.
def space_char?(c)
  c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\f" || c == "\v"
end

# The index just after the quoted string whose opening quote is at i, or nil when it is not terminated.
def quoted_end(text, i)
  n = text.length
  j = i + 1
  while j < n
    c = text[j]
    if c == "\""
      return j + 1
    elsif c == "\\"
      return nil if j + 1 >= n || text[j + 1] == "\n"
      j += 2
    else
      j += 1
    end
  end
  nil
end

def tokenize(text)
  toks = []
  n = text.length
  i = 0
  while i < n
    c = text[i]
    if space_char?(c)
      i += 1
    elsif c == "(" || c == ")"
      toks << c
      i += 1
    else
      q = c == "\"" ? i : ((c == "$" || c == "&") && i + 1 < n && text[i + 1] == "\"" ? i + 1 : nil)
      e = q ? quoted_end(text, q) : nil
      if e
        toks << text[i...e]
        i = e
      else
        j = i
        j += 1 while j < n && !space_char?(text[j]) && text[j] != "(" && text[j] != ")"
        toks << text[i...j]
        i = j
      end
    end
  end
  toks
end

# Whether s is one or more ASCII digits.
def all_digits?(s)
  return false if s.empty?
  s.each_char { |c| return false unless c >= "0" && c <= "9" }
  true
end

def parse_tokens(toks)
  stack = [[]]
  toks.each do |t|
    if t == "("
      stack.push([])
    elsif t == ")"
      raise BadSSA, "unbalanced ')'" if stack.length == 1
      f = stack.pop
      stack.last << f
    else
      stack.last << t
    end
  end
  raise BadSSA, "unbalanced '('" if stack.length != 1
  stack[0]
end

def head(x)
  x.is_a?(Array) && x[0].is_a?(String) ? x[0] : nil
end

def show(x)
  x.is_a?(Array) ? "(#{x.map { |y| show(y) }.join(' ')})" : x
end

def atoms(x, out = [])
  if x.is_a?(Array)
    x.each { |y| atoms(y, out) }
  else
    out << x
  end
  out
end

def value_name?(s)
  s.is_a?(String) && s.length > 1 && s[0] == "%"
end

def strip_const(t)
  head(t) == "const" ? strip_const(t[1]) : t
end

def zero_of(t)
  base = strip_const(t)
  if base.is_a?(String) && INT_TYPES.include?(base)
    ["const", base, "0"]
  elsif head(base) == "ptr"
    ["null", base]
  else
    raise Refused, "no zero value for type #{show(t)}"
  end
end

# The SSA function: its header, slots and attributes, and its blocks.
class SsaFn
  attr_reader :name, :header, :params, :slots, :attrs, :blocks, :order, :types

  def initialize(form)
    @name = form[1]
    @header = []
    @params = []
    @slots = []
    @attrs = []
    @blocks = {}
    @order = []
    form.drop(2).each do |f|
      case head(f)
      when "ret" then @header << f
      when "params" then @params = f.drop(1)
      when "slot" then @slots << f
      when "ssa-promoted" then nil
      when "bb"
        id = f[1].to_i
        raise BadSSA, "block #{id} twice in #{@name}" if @blocks.key?(id)
        @blocks[id] = f.drop(2)
        @order << id
      else
        @attrs << f
      end
    end
    raise BadSSA, "no blocks in #{@name}" if @order.empty?
    @types = {}
    @params.each { |p| @types[p[1]] = p[3] if head(p) == "param" }
    @order.each do |id|
      @blocks[id].each { |s| @types[s[1]] = s[2] if head(s) == "let" || head(s) == "phi" }
    end
  end

  def phis_of(id)
    @blocks[id].select { |s| head(s) == "phi" }
  end

  def terminator(id)
    @blocks[id].last
  end

  # The successors of a block, in the order of its terminator; a switch's default counts.
  def succs(id)
    t = terminator(id)
    case head(t)
    when "br" then [t[1].to_i]
    when "condbr" then [t[2].to_i, t[3].to_i].uniq
    when "switch"
      targets = t.drop(2).select { |c| head(c) == "case" }.map { |c| c[2].to_i }
      dflt = t.drop(2).find { |c| head(c) == "default" }
      targets << dflt[1].to_i if dflt
      targets.uniq
    else []
    end
  end
end

# Dominators (Cooper, Harvey and Kennedy) of the nodes reachable from root, given as a successor function. Returns the
# immediate dominator of each reachable node (the root maps to itself).
def dominators(root, succ)
  order = []
  seen = {}
  stack = [[root, false]]
  until stack.empty?
    n, done = stack.pop
    if done
      order << n
      next
    end
    next if seen[n]
    seen[n] = true
    stack.push([n, true])
    succ.call(n).reverse_each { |s| stack.push([s, false]) unless seen[s] }
  end
  rpo = order.reverse
  index = {}
  rpo.each_with_index { |n, i| index[n] = i }
  preds = Hash.new { |h, k| h[k] = [] }
  rpo.each { |n| succ.call(n).each { |s| preds[s] << n if index.key?(s) } }
  idom = { root => root }
  changed = true
  while changed
    changed = false
    rpo.each do |n|
      next if n == root
      new_idom = preds[n].find { |p| idom.key?(p) }
      next if new_idom.nil?
      preds[n].each do |p|
        next if p == new_idom || !idom.key?(p)
        a = p
        b = new_idom
        until a == b
          a = idom[a] while index[a] > index[b]
          b = idom[b] while index[b] > index[a]
        end
        new_idom = a
      end
      if idom[n] != new_idom
        idom[n] = new_idom
        changed = true
      end
    end
  end
  idom
end

def dominates?(idom, a, b)
  x = b
  loop do
    return true if x == a
    nx = idom[x]
    return false if nx.nil? || nx == x
    x = nx
  end
end

class FnEmitter
  attr_reader :fn

  def initialize(fn)
    @fn = fn
    @emitted = {}
    @exit_codes = []
    prepare_names
    prepare_loops
  end

  # ---- names, types and registers
  def prepare_names
    max = 0
    atoms(@fn.header + @fn.params + @fn.slots + @fn.attrs).each do |a|
      max = a[1..-1].to_i if value_name?(a) && all_digits?(a[1..-1]) && a[1..-1].to_i > max
    end
    @names = {}
    fresh = max
    @fn.order.each do |id|
      @fn.blocks[id].each do |s|
        next unless head(s) == "let" || head(s) == "phi"
        fresh += 1
        @names[s[1]] = "%#{fresh}"
      end
    end
    @next = fresh
    @types_by_new = {}
    @names.each { |old, n| @types_by_new[n] = @fn.types[old] }
    @fn.params.each { |p| @types_by_new[p[1]] = p[3] if head(p) == "param" }

    def_block = {}
    @fn.order.each { |id| @fn.blocks[id].each { |s| def_block[s[1]] = id if head(s) == "let" } }
    used_in = Hash.new { |h, k| h[k] = [] }
    @fn.order.each do |id|
      @fn.blocks[id].each do |s|
        next if head(s) == "phi"
        atoms(s).each { |a| used_in[a] << id if value_name?(a) }
      end
      @fn.phis_of(id).each do |p|
        p.drop(3).each { |pair| used_in[pair[1]] << pair[0].to_i if value_name?(pair[1]) }
      end
    end
    @regs = {}
    @fn.order.each { |id| @fn.phis_of(id).each { |p| @regs[p[1]] = true } }
    def_block.each { |name, id| @regs[name] = true if used_in[name].any? { |b| b != id } }
  end

  def decls
    out = []
    @names.each do |old, n|
      next unless @regs[old]
      t = @types_by_new[n]
      out << ["let", n, t, zero_of(t)]
    end
    @exit_codes.each { |c| out << ["let", c, "int", ["const", "int", "0"]] }
    out
  end

  def rename(x)
    if x.is_a?(Array)
      x.map { |y| rename(y) }
    elsif value_name?(x) && @overlay && @overlay.key?(x)
      @overlay[x]
    elsif value_name?(x) && @names.key?(x)
      @names[x]
    else
      x
    end
  end

  def tmp
    @next += 1
    "%#{@next}"
  end

  def type_of(op)
    if value_name?(op)
      @types_by_new.fetch(op) { raise BadSSA, "no type for #{op} in #{@fn.name}" }
    elsif head(op) == "const"
      op[1]
    else
      "int"
    end
  end

  # The statements of a block that are neither phis nor the terminator.
  def body_stmts(id)
    out = []
    @fn.blocks[id][0...-1].each do |s|
      next if head(s) == "phi"
      if head(s) == "let" && !@regs[s[1]]
        if @overlay_fresh
          n = @overlay[s[1]] = tmp
          @types_by_new[n] = s[2]
        else
          n = @names[s[1]]
        end
        out << ["let", n, s[2], rename(s[3])]
      elsif head(s) == "let"
        t = tmp
        out << ["let", t, s[2], rename(s[3])]
        out << ["set", @names[s[1]], t]
      else
        out << rename(s)
      end
    end
    out
  end

  # The phi copies on the edge pred -> succ (two-phase when there is more than one, so a phi may read another).
  def copies(pred, succ)
    phis = @fn.phis_of(succ).select { |p| p.drop(3).any? { |pair| pair[0].to_i == pred } }
    pairs = phis.map do |p|
      op = p.drop(3).find { |pair| pair[0].to_i == pred }[1]
      [@names[p[1]], rename(op), rename(p[2])]
    end
    out = []
    if pairs.length > 1
      temps = pairs.map { |_dst, op, t| [tmp, op, t] }
      temps.each { |tn, op, t| out << ["let", tn, t, op] }
      pairs.each_with_index { |(dst, _op, _t), i| out << ["set", dst, temps[i][0]] }
    else
      pairs.each { |dst, op, _t| out << ["set", dst, op] }
    end
    out
  end

  # ---- loops and postdominators
  def prepare_loops
    entry = @fn.order.first
    @idom = dominators(entry, lambda { |n| @fn.succs(n) })
    @reachable = @idom.keys
    @preds = Hash.new { |h, k| h[k] = [] }
    @reachable.each { |b| @fn.succs(b).each { |s| @preds[s] << b } }
    @loops = {}   # header => { body: [ids] }
    @reachable.each do |b|
      @fn.succs(b).each do |h|
        next unless @idom.key?(h) && dominates?(@idom, h, b)
        loop_ = (@loops[h] ||= { body: [h] })
        body = loop_[:body]
        work = [b]
        until work.empty?
          n = work.pop
          next if body.include?(n)
          body << n
          @preds[n].each { |p| work << p unless body.include?(p) }
        end
      end
    end
    exits = @reachable.select { |b| @fn.succs(b).empty? }
    rsucc = lambda { |n| n == -1 ? exits : @preds[n] }
    @ipdom = dominators(-1, rsucc)
  end

  def ipdom(id)
    d = @ipdom[id]
    d.nil? || d == -1 || d == id ? nil : d
  end

  # ---- the structured emission
  def structured
    @emitted = {}
    @path = {}
    @budget = 8 * @reachable.length
    out = emit_seq(@fn.order.first, { stop: [], header: nil, exits: {}, region: @reachable })
    missing = @reachable - @emitted.keys
    raise Unstructurable, "blocks not reached: #{missing.join(' ')}" unless missing.empty?
    out
  end

  def emit_seq(id, ctx)
    if @loops.key?(id) && id != ctx[:header]
      emit_loop(id, ctx)
    else
      emit_block(id, ctx)
    end
  end

  # A loop: its body, with the exits as breaks. One exit: a break. Several: each exit sets the loop's exit code and breaks,
  # and after the loop a test of the code continues at the exit that was taken (also when the exit is a block of an outer loop).
  def emit_loop(h, ctx)
    body = @loops[h][:body]
    exits = body.flat_map { |n| @fn.succs(n).reject { |s| body.include?(s) } }.uniq
    if exits.length <= 1
      x = exits.first
      exit_map = x.nil? ? {} : { x => [nil, 0] }
      inner = emit_block(h, { stop: [], header: h, exits: exit_map, region: body })
      return [["loop", ["body"] + inner, ["step"]]] + (x.nil? ? [] : after(x, ctx))
    end
    code = tmp
    @exit_codes << code
    exit_map = {}
    exits.each_with_index { |x, i| exit_map[x] = [code, i] }
    inner = emit_block(h, { stop: [], header: h, exits: exit_map, region: body })
    out = [["loop", ["body"] + inner, ["step"]]]
    exits.each_with_index do |x, i|
      cond = tmp
      out << ["let", cond, "bool", ["eq", "int", code, ["const", "int", i.to_s]]]
      out << ["if", cond, ["then"] + after(x, ctx), ["else"]]
    end
    out
  end

  # What follows a construct that continues at block x (a loop's exit, or an if's merge). An exit of the enclosing loop is
  # left the way a jump to it is.
  def after(x, ctx)
    return [] if x.nil? || ctx[:stop].include?(x)
    return [["continue"]] if x == ctx[:header]
    return leave(x, ctx) if ctx[:exits].key?(x)
    raise Unstructurable, "block #{x} is outside the structure here" unless ctx[:region].include?(x)
    emit_seq(x, ctx)
  end

  # Leaves the innermost loop for its exit x.
  def leave(x, ctx)
    code, i = ctx[:exits][x]
    code.nil? ? [["break"]] : [["set", code, ["const", "int", i.to_s]], ["break"]]
  end

  # A jump from pred to succ: the phi copies, then what the context makes of the target.
  def transfer(pred, succ, ctx)
    out = copies(pred, succ)
    return out if ctx[:stop].include?(succ)
    return out + [["continue"]] if succ == ctx[:header]
    return out + leave(succ, ctx) if ctx[:exits].key?(succ)
    raise Unstructurable, "jump from #{pred} to #{succ} leaves the structure" unless ctx[:region].include?(succ)
    out + emit_seq(succ, ctx)
  end

  # A block reached again on another path is emitted again (node splitting): the copy runs on its own paths, its own lets
  # get fresh names, and its registers are assigned again. A block already on the path being emitted would expand forever
  # (an irreducible cycle), and the total is bounded by the budget; either one falls back to the state machine.
  def emit_block(id, ctx)
    raise Unstructurable, "block #{id} repeats on its own path" if @path[id]
    @budget -= 1
    raise Unstructurable, "node splitting exceeds its budget" if @budget < 0
    copy = @emitted[id]
    @emitted[id] = true
    @path[id] = true
    saved_overlay = @overlay
    saved_fresh = @overlay_fresh
    @overlay = copy ? {} : saved_overlay
    @overlay_fresh = copy
    begin
      emit_block_body(id, ctx)
    ensure
      @path.delete(id)
      @overlay = saved_overlay
      @overlay_fresh = saved_fresh
    end
  end

  def emit_block_body(id, ctx)
    stmts = body_stmts(id)
    term = @fn.terminator(id)
    case head(term)
    when "br"
      stmts + transfer(id, term[1].to_i, ctx)
    when "ret"
      stmts + [term.length > 1 ? ["return", rename(term[1])] : ["return"]]
    when "unreachable"
      stmts + [["unreachable"]]
    when "condbr"
      m = merge_of(id, ctx)
      arm_ctx = ctx.merge(stop: m ? ctx[:stop] + [m] : ctx[:stop])
      c = rename(term[1])
      then_s = transfer(id, term[2].to_i, arm_ctx)
      else_s = transfer(id, term[3].to_i, arm_ctx)
      stmts + [["if", c, ["then"] + then_s, ["else"] + else_s]] + (m ? after(m, ctx) : [])
    when "switch"
      m = merge_of(id, ctx)
      arm_ctx = ctx.merge(stop: m ? ctx[:stop] + [m] : ctx[:stop])
      op = rename(term[1])
      ty = type_of(op)
      cs = term.drop(2).select { |c| head(c) == "case" }
      dflt = term.drop(2).find { |c| head(c) == "default" }
      chain = lambda do |i|
        if i == cs.length
          dflt ? transfer(id, dflt[1].to_i, arm_ctx) : [["unreachable"]]
        else
          _c, v, b = cs[i]
          cond = tmp
          [["let", cond, "bool", ["eq", ty, op, ["const", ty, v.to_s]]],
           ["if", cond, ["then"] + transfer(id, b.to_i, arm_ctx), ["else"] + chain.call(i + 1)]]
        end
      end
      stmts + chain.call(0) + (m ? after(m, ctx) : [])
    else
      raise BadSSA, "block #{id} of #{@fn.name} ends with #{head(term) || show(term)}"
    end
  end

  # The merge of a branch at id: its immediate postdominator, when it lies in the structure here; else none, and both arms
  # must leave the structure by a jump of their own.
  def merge_of(id, ctx)
    m = ipdom(id)
    return nil if m.nil?
    return m if ctx[:stop].include?(m)
    return m if ctx[:region].include?(m) && m != ctx[:header] && m != ctx[:exit]
    nil
  end

  # ---- the state machine (any CFG)
  def state_machine
    @emitted = {}
    state = "%#{@next += 1}"
    entry = @fn.order.first
    goto = lambda do |pred, succ|
      copies(pred, succ) + [["set", state, ["const", "int", succ.to_s]]]
    end
    cases = []
    @fn.order.each do |id|
      body = body_stmts(id)
      term = @fn.terminator(id)
      case head(term)
      when "br"
        body.concat(goto.call(id, term[1].to_i))
        body << ["break"]
      when "condbr"
        c = rename(term[1])
        body << ["if", c, ["then"] + goto.call(id, term[2].to_i), ["else"] + goto.call(id, term[3].to_i)]
        body << ["break"]
      when "switch"
        op = rename(term[1])
        ty = type_of(op)
        cs = term.drop(2).select { |c| head(c) == "case" }
        dflt = term.drop(2).find { |c| head(c) == "default" }
        chain = lambda do |i|
          if i == cs.length
            dflt ? goto.call(id, dflt[1].to_i) + [["break"]] : [["unreachable"]]
          else
            _c, v, b = cs[i]
            cond = tmp
            [["let", cond, "bool", ["eq", ty, op, ["const", ty, v.to_s]]],
             ["if", cond, ["then"] + goto.call(id, b.to_i) + [["break"]], ["else"] + chain.call(i + 1)]]
          end
        end
        body.concat(chain.call(0))
      when "ret"
        body << (term.length > 1 ? ["return", rename(term[1])] : ["return"])
      when "unreachable"
        body << ["unreachable"]
      else
        raise BadSSA, "block #{id} of #{@fn.name} ends with #{head(term) || show(term)}"
      end
      cases.concat([["case", ["const", "int", id.to_s]]] + body)
    end
    [["let", state, "int", ["const", "int", entry.to_s]],
     ["loop", ["body", ["switch", state, ["body"] + cases]], ["step"]]]
  end
end

def function_out(fn, body, decls)
  ["function", fn.name] + fn.header + [["params"] + fn.params] + fn.attrs + fn.slots + decls + body
end

# Structured when the CFG allows it, the state machine otherwise.
def structurize_fn(form)
  fn = SsaFn.new(form)
  em = FnEmitter.new(fn)
  begin
    body = em.structured
    method = "structured"
  rescue Unstructurable => e
    $stderr.write("pathb-ssa-structurize: #{fn.name}: state machine (#{e.message})\n") if $structurize_verbose
    em = FnEmitter.new(fn)
    body = em.state_machine
    method = "state-machine"
  end
  $stderr.write("pathb-ssa-structurize: #{fn.name}: #{method}\n") if $structurize_verbose
  function_out(fn, body, em.decls)
end

def structurize_text(text)
  forms = parse_tokens(tokenize(text))
  forms.map { |f| head(f) == "ssa-function" ? structurize_fn(f) : f }
end

$structurize_verbose = false

def main(argv)
  args = argv.dup
  while !args.empty? && args.first == "--verbose"
    args.shift
    $structurize_verbose = true
  end
  file = args.empty? || args[0] == "-" ? nil : args[0]
  begin
    text = file ? File.read(file) : $stdin.read
    forms = structurize_text(text)
  rescue BadSSA => e
    $stderr.write("error: #{e.message}\n")
    return 1
  rescue Refused => e
    $stderr.write("refused: #{e.message}\n")
    return 3
  rescue SystemCallError => e
    $stderr.write("error: #{e.message}\n")
    return 1
  end
  forms.each { |f| $stdout.write(show(f) + "\n") }
  0
end

rc = main(ARGV)
exit(rc) if rc != 0

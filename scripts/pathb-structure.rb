#!/usr/bin/env ruby
# frozen_string_literal: true
#
# The structured form of a function (the relooper's job): a control-flow graph in SSA is laid out as nested labelled
# blocks and loops of flat IR (scripts/pathb-wasm-emit.rb reads it), with no state machine. The layout comes from the
# dominator tree of the graph, the way a stackifier arranges a reducible graph:
#
#   - A block whose only predecessor is its dominator is emitted where that predecessor branches to it (inline).
#   - A block with several predecessors (a merge) is a labelled block: the code that jumps to it is inside the label, and
#     the merge's code comes right after the label ends. The merges of one block are laid out in reverse postorder.
#   - A loop header is a (loop NAME (body ...) (step)): a back edge is (continue NAME), and a jump out of the loop is a
#     (break LABEL) to a label outside it.
#
# Every block is emitted once, and every jump lands on a label in scope, so the form has no copies and no state. A
# function the layout cannot take (a jump with no label in scope) returns nil, and the caller falls back to the dispatch
# loop (PathbEgraph.flat_from_dispatch), which takes any reducible graph.
#
# The input is the function after the dispatch transform's first half (PathbEgraph.dispatch_structurize): the values
# that cross blocks are the function's locals there, so the structured form has no phis and no slots of its own.
#
#   PathbStructure.structure(fn)   # fn: a PathbEgraph::EFn (SSA, after the e-graph) => a flat IR form, or nil
require_relative "pathb-egraph"

module PathbStructure
  module_function

  # The flat IR form of fn, or nil when the layout does not take it.
  def structure(fn)
    dfn = PathbEgraph.dispatch_structurize(fn)
    return nil unless dfn

    blocks = unwrap(dfn)
    return nil unless blocks

    efn = PathbEgraph::EFn.new(dfn.name, dfn.ret, dfn.params, dfn.header, blocks)
    body = Layout.new(efn).emit_function
    return nil unless body

    header = dfn.header.reject do |x|
      %w[ssa-promoted ssa-function ret params].include?(head(x)) || (head(x) == "slot" && dispatch_slot?(x))
    end
    locals, decls = locals_of(dfn.header)
    ["function", dfn.name, dfn.ret, dfn.params, *header,
     ["block", *decls, *localize(body, locals)]]
  rescue Fail, Unsupported
    nil
  end

  def dispatch_slot?(x) = x[1].raw.start_with?('"__dsp')

  # The dispatch's blocks without the dispatch: the original blocks, with each jump to an edge block (which only stores the
  # state and jumps back to the dispatch) turned into the jump to the block it stores. Returns nil if dfn has no dispatch.
  def unwrap(dfn)
    dispatch = dfn.blocks.keys.find do |id|
      t = dfn.blocks[id][:term]
      t[0] == "switch" && t[1] == "%dstate"
    end
    return nil unless dispatch

    unreachable = dfn.blocks[dispatch][:term][3]
    edge = {}
    dfn.blocks.each do |id, b|
      next unless b[:term] == ["br", dispatch] && b[:instrs].size == 1 && head(b[:instrs][0]) == "store"

      edge[id] = Integer(b[:instrs][0][3][2].to_s)
    end
    target = ->(t) { edge.fetch(t, t) }
    blocks = {}
    dfn.blocks.each do |id, b|
      next if id == dispatch || id == unreachable || edge.key?(id)

      term = b[:term]
      term = case term[0]
             when "br" then ["br", target.call(term[1])]
             when "condbr" then ["condbr", term[1], target.call(term[2]), target.call(term[3])]
             when "switch" then ["switch", term[1], term[2].map { |v, t| [v, target.call(t)] }, target.call(term[3])]
             else term
             end
      blocks[id] = { phis: [], instrs: b[:instrs], term: term }
    end
    blocks
  end

  # The locals that stand for the dispatch's slots: a Ruby hash from the slot's reference (a $"name" form) to the local's
  # name, and the lets that declare them (zero-initialized, before the layout).
  def locals_of(header)
    locals = {}
    decls = []
    header.each do |x|
      next unless head(x) == "slot" && dispatch_slot?(x)

      name = x[1].raw[1..-2]
      reg = "%sl#{name[1..]}"
      locals[PathbEgraph::F("$\"#{name}\"")] = reg
      zero = head(x[2]) == "ptr" ? PathbEgraph::F("(null)") : PathbEgraph::F("(const #{sx(x[2])} 0)")
      decls << ["let", reg, x[2], zero]
    end
    [locals, decls]
  end

  # The forms with the dispatch's slots as locals: a load of a slot is the local, a store is a set.
  def localize(x, locals)
    return x unless x.is_a?(Array)

    if head(x) == "load" && x.length == 3 && locals.key?(x[2])
      locals[x[2]]
    elsif head(x) == "store" && x.length == 4 && locals.key?(x[2])
      ["set", locals[x[2]], localize(x[3], locals)]
    else
      x.map { |y| localize(y, locals) }
    end
  end

  # The layout of one function's blocks. Each method returns a list of statements.
  class Layout
    def initialize(efn)
      @efn = efn
      @blocks = efn.blocks
      @rpo = PathbEgraph.reverse_postorder(efn)
      @preds, @idom = PathbEgraph.idoms(efn, @rpo)
      @children = Hash.new { |h, k| h[k] = [] }
      @rpo.drop(1).each { |b| @children[@idom[b]] << b }
      @headers = {}
      @bodies = {}
      @rpo.each do |h|
        latches = (@preds[h] || []).select { |p| dominates?(h, p) }
        next if latches.empty?

        @headers[h] = true
        @bodies[h] = natural_loop(h, latches)
      end
      @types = {}
      efn.params[1..].each { |p| @types[p[1]] = p[3] }
      @blocks.each_value { |b| b[:instrs].each { |i| @types[i[1]] = i[2] if head(i) == "let" } }
      @emitted = {}
    end

    # The whole function: the entry block, with its own code and layout. Nil when a jump has no label in scope, or a
    # block was not reached (the layout does not cover the graph).
    def emit_function
      stmts = emit_block(0, [])
      return nil unless @emitted.size == @rpo.size

      stmts
    end

    private

    def dominates?(a, b)
      x = b
      loop do
        return true if x == a
        return false if x == 0 || !@idom.key?(x)

        x = @idom[x]
      end
    end

    # The blocks of the loop headed by h: h and every block that reaches a latch without passing h.
    def natural_loop(h, latches)
      body = [h]
      stack = latches.dup
      until stack.empty?
        b = stack.pop
        next if body.include?(b)

        body << b
        stack.concat(@preds[b] || [])
      end
      body
    end

    # A block that only its dominator precedes: it is emitted where that dominator branches to it.
    def inline?(c)
      @preds[c] && @preds[c].size == 1 && @idom[c] == @preds[c][0]
    end

    # A merge: a child of a block that is laid out behind a label.
    def merge_child?(c) = !inline?(c) && c != 0

    def label(b) = "b#{b}"
    def loop_label(h) = "h#{h}"

    def emit_block(v, scope)
      raise Fail, "block #{v} emitted twice" if @emitted[v]

      @emitted[v] = true
      if @headers[v]
        body = @bodies[v]
        loop_kids = @children[v].select { |c| merge_child?(c) && body.include?(c) }
        out_kids = @children[v].select { |c| merge_child?(c) && !body.include?(c) }
        loop_scope = scope + [["loop", loop_label(v)]]
        inner = layout(v, loop_kids, loop_scope, loop_scope)
        loop_form = ["loop", loop_label(v), ["body", *inner], ["step"]]
        layout_after(loop_form, out_kids, scope)
      else
        layout(v, @children[v].select { |c| merge_child?(c) }, scope, scope)
      end
    end

    # The statements of v (its code and its jump) in the blocks of kids, each kid laid out behind its label. The code of v
    # sees every kid's label; the code of a kid sees the labels of the kids after it.
    def layout(v, kids, inner_scope, outer_scope)
      labels = kids.map { |k| ["block", label(k)] }
      v_stmts = own(v, inner_scope + labels)
      arrange(v_stmts, kids, outer_scope)
    end

    # Wrap statements acc in the blocks of kids, in order: each block ends where its kid's code starts.
    def arrange(acc, kids, scope)
      kids.each_with_index do |k, j|
        later = kids[(j + 1)..].map { |x| ["block", label(x)] }
        child = emit_block(k, scope + later)
        acc = [["block", label(k), *acc], *child]
      end
      acc
    end

    # For a loop's exits: they follow the loop, and each is laid out behind its label, which wraps the loop.
    def layout_after(loop_form, kids, scope)
      arrange([loop_form], kids, scope)
    end

    # The statements of block v: its own code, and its jump through the labels in scope.
    def own(v, scope)
      b = @blocks.fetch(v)
      instrs = b[:instrs].map { |i| i }
      instrs + terminator(b[:term], scope)
    end

    def branch(t, scope)
      return emit_block(t, scope) if inline?(t)
      return [["continue", loop_label(t)]] if scope.include?(["loop", loop_label(t)])
      return [["break", label(t)]] if scope.include?(["block", label(t)])

      raise Fail, "a jump to block #{t} with no label in scope"
    end

    def terminator(term, scope)
      case term[0]
      when "br" then branch(term[1], scope)
      when "condbr"
        [["if", term[1], ["then", *branch(term[2], scope)], ["else", *branch(term[3], scope)]]]
      when "switch"
        sel_type = @types.fetch(term[1].is_a?(String) ? term[1] : "", "int")
        arms = term[2].flat_map do |v, t|
          [PathbEgraph::F("(case (const #{sx(sel_type)} #{v}))"), *branch(t, scope)]
        end
        [["switch", term[1], ["body", ["block", *arms, PathbEgraph::F("(default)"), *branch(term[3], scope)]]]]
      when "ret" then [term[1] ? ["return", term[1]] : ["return"]]
      when "unreachable" then [["unreachable"]]
      else raise Unsupported, "terminator #{head(term)}"
      end
    end
  end
end

# The function text: the files named (- is standard input, no names read standard input), as ARGF reads them.
def structure_input(argv)
  return $stdin.read if argv.empty?

  argv.map { |f| f == "-" ? $stdin.read : File.read(f) }.join
end

def main(argv)
  text = structure_input(argv)
  if text.nil? || text.empty?
    $stderr.write "usage: pathb-structure.rb FILE.ssa\n"
    return 1
  end
  puts sx(PathbStructure.structure(PathbEgraph.parse_fn(PathbEgraph::F(text))))
  0
rescue SystemCallError => e
  $stderr.write "pathb-structure: #{e.message}\n"
  1
end

# pathb-flat-opt requires this file for the structured form, so the command line runs only as the program.
if $0 == __FILE__
  rc = main(ARGV)
  exit(rc) if rc != 0
end

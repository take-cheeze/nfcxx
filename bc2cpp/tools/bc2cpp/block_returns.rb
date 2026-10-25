# frozen_string_literal: true

require 'digest'
require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_regions'
require_relative 'bytecode_ir_containers'
require_relative 'block_self'
require_relative 'native_block_returns_reviewed'
require_relative 'native_sigs'

# BLOCK_RETURNS: RBS declarations of methods whose result is their block's value, or their receiver,
# checked against the method body and then used at call sites with a literal block.
#
# Two shapes are block-return declarations (a block type and a return type of one of these forms):
#   :block_value  `def m: [T] (A a, ...) { (B, ...) -> T } -> T`  the call returns the value its block returned
#   :self         `def m: (A a, ...) { (B, ...) -> X } -> self`   the call returns its receiver (tap, each)
# The block must be required, take required positionals only and declare no `[self: S]` binding (its self stays
# the caller's); the method itself takes required positionals only; for :block_value, T appears nowhere else.
# A declaration that has a block and one of these return types but breaks a rule is reported (TC1005 info) and
# gives no fact. Everything else about the declaration keeps its RbsSignatures role.
#
# What makes a declaration true, and how each kind of definition is checked (CodeGen#check_block_returns):
#   Ruby     every definition (program, mruby's own Ruby, an outside Ruby source compiled for the check) is a plain
#            yielder (BlockSelf), every yield passes the declared number of arguments, and every return path the
#            method can take when a block is given returns a value a yield produced (:block_value) or self (:self).
#            BlockReturns.ruby_body_why is that check.
#   native   every C function registered under the name is scanned (BlockReturns.native_function_why): its block is
#            read only by mrb_get_args, mrb_nil_p and mrb_yield/mrb_yield_argv (which keep the Proc's self), every
#            yield passes the declared number of arguments, and every `return` returns a yield's value (directly or
#            through a `mrb_value v = mrb_yield...;` never written again), apart from `return mrb_nil_value()` right
#            under `if (mrb_nil_p(blk))`, the no-block path a call with a literal block never takes. A function the
#            scan cannot verify is accepted only when native_block_returns_reviewed.rb lists the declaration with the
#            SHA-256 of the file it was reviewed in; otherwise the declaration is a TC1010 error.
# A failed check is a TC1010 error that aborts the build (DECLARED_RETURN_CHECK's report).
module BlockReturns
  Entry = Struct.new(:owner, :name, :kind, :args, :arity, :loc, :native, :text, :problem, keyword_init: true) do
    def key = "#{owner}##{name}"
  end

  CODE = 'TC1010'

  module_function

  # Entries for every loaded method signature with a block-return shape (nil: no signatures).
  def from_signatures(loaded)
    return [] unless loaded

    loaded.methods.each_value.filter_map { |sig| classify(sig) }
  end

  def classify(sig)
    block = sig.block_type
    ret = sig.return_type
    return nil unless block && ret

    fn = block.type
    kind = if ret.is_a?(RBS::Types::Variable) && fn.respond_to?(:return_type) &&
              fn.return_type.is_a?(RBS::Types::Variable) && fn.return_type.name == ret.name
             :block_value
           elsif ret.is_a?(RBS::Types::Bases::Self)
             :self
           end
    return nil unless kind

    Entry.new(owner: sig.owner, name: sig.name, kind: kind, args: sig.args.size,
              arity: fn.respond_to?(:required_positionals) ? fn.required_positionals.size : nil, loc: sig.loc,
              native: sig.loc.native, text: text_of(block, ret), problem: problem_of(sig, kind))
  end

  def text_of(block, ret)
    fn = block.type
    params = fn.respond_to?(:required_positionals) ? fn.required_positionals.map { |p| p.type.to_s }.join(', ') : '?'
    "#{block.required ? '' : '?'}{ (#{params}) -> #{fn.respond_to?(:return_type) ? fn.return_type : '?'} } -> #{ret}"
  end

  def problem_of(sig, kind)
    block = sig.block_type
    fn = block.type
    return 'the block is optional' unless block.required
    return 'the block declares a self type' if block.respond_to?(:self_type) && block.self_type
    unless fn.is_a?(RBS::Types::Function) && fn.optional_positionals.empty? && !fn.rest_positionals &&
           fn.trailing_positionals.empty? && fn.required_keywords.empty? && fn.optional_keywords.empty? && !fn.rest_keywords
      return 'the block takes parameters other than required positionals'
    end
    return 'the method takes parameters other than required positionals' unless sig.callback_supported
    return nil unless kind == :block_value

    name = sig.return_type.name.to_s
    return "#{name} is not a type parameter of the method" unless sig.type_params.include?(name)
    return "#{name} has a bound" if sig.type_param_bounds&.[](name)

    elsewhere = sig.argument_types.any? { |t| type_mentions?(t, name) } ||
                fn.required_positionals.any? { |p| type_mentions?(p.type, name) }
    elsewhere ? "#{name} also types a parameter" : nil
  end

  def type_mentions?(type, name)
    return type.name.to_s == name if type.is_a?(RBS::Types::Variable)

    type.respond_to?(:each_type) && type.each_type.any? { |t| type_mentions?(t, name) }
  end

  # --------------------------------------------------------------------------------------------- Ruby bodies

  # nil when the Ruby method body +irep+ (nested blocks in +ireps+) proves +entry+, else why not.
  def ruby_body_why(irep, ireps, entry)
    return 'has no body' unless irep

    req, opt, rest, post, key, kdict = irep.enter&.enter_fields&.first(6)&.map(&:to_i) || [0, 0, 0, 0, 0, 0]
    unless opt.zero? && rest.zero? && post.zero? && key.zero? && kdict.zero? && req == entry.args
      return "takes #{req} required parameter(s) and others, the declaration #{entry.args} required only"
    end

    why = BlockSelf.plain_yielder_why(irep, ireps)
    return why if why

    nested = nested_exit_why(irep, ireps, entry.arity)
    return nested if nested

    program = BytecodeIR.for(irep)
    return 'has branch targets that are not instructions' unless program.resolved?
    return 'has exception handlers it cannot place' unless program.handlers_resolved?

    blk = (1 + req).to_s
    proc_def = lambda do |df|
      next df.reg.to_s == blk if df.entry?

      BytecodeIR.for(irep).source_at(df.index).op == :BLKPUSH
    end
    holds_proc = lambda do |idx, reg|
      defs = definitions(irep, program, idx, reg)
      defs && !defs.empty? && defs.all? { |df| proc_def.call(df) }
    end
    reachable(irep, program, holds_proc).sort.each do |idx|
      insn = BytecodeIR.for(irep).source_at(idx)
      line = "line #{insn.lineno}"
      case insn.op
      when :BLKCALL
        n = insn.typed.find { |operand| operand.kind == :int }&.value
        return "yields #{n} argument(s) at #{line}, the block declares #{entry.arity}" unless n == entry.arity
      when :SEND, :SENDB
        next unless insn.sym == 'call' && holds_proc.call(idx, insn.reg)
        return "calls its block with #{insn.argc_text} at #{line}, the block declares #{entry.arity}" unless insn.plain_fixed_argc? && insn.argc.to_i == entry.arity && insn.op == :SEND
      when :RETURN
        why = return_value_why(irep, program, idx, insn.reg, entry, holds_proc)
        return "#{why} (#{line})" if why
      when :RETSELF
        return "returns self at #{line}" unless entry.kind == :self
      when :RETNIL, :RETTRUE, :RETFALSE, :STOP
        return "ends with #{insn.op} at #{line}"
      when :RETURN_BLK, :BREAK
        return "#{insn.op} at #{line}"
      end
    end
    nil
  end

  # A `return` or `break` inside a nested block leaves this method (or a call) with some other value; a nested `yield`
  # must pass the declared arguments too.
  def nested_exit_why(irep, ireps, arity, seen = Set.new)
    irep.reps.each do |label|
      next unless seen.add?(label)

      child = ireps[label] or return 'has a nested block with no body'
      exit = BytecodeIR.for(child).instructions_with_op(:RETURN_BLK, :BREAK).first
      return "a nested block leaves with #{exit.op} at line #{exit.lineno}" if exit

      # A `yield` in a nested block runs the method's block too (OP_BLKPUSH reads the method frame's block).
      BytecodeIR.for(child).instructions_with_op(:BLKCALL).each do |insn|
        n = insn.typed.find { |operand| operand.kind == :int }&.value
        return "yields #{n} argument(s) at line #{insn.lineno}, the block declares #{arity}" unless n == arity
      end

      why = nested_exit_why(child, ireps, arity, seen)
      return why if why
    end
    nil
  end

  # Instruction indices reachable from entry when the method has a block: a truth test of a register that holds
  # the block (a Proc, never nil or false) takes only its truthy edge. Exception handlers are reachable when the
  # protected range is.
  def reachable(irep, program, holds_proc)
    seen = Set.new
    stack = [0]
    handlers = program.handler_edges
    until stack.empty?
      idx = stack.pop
      next if idx.nil? || idx >= BytecodeIR.for(irep).size || !seen.add?(idx)

      insn = BytecodeIR.for(irep).source_at(idx)
      succ = program.successor_lists[idx]
      target = insn.branch_target && program.address_to_index[insn.branch_target]
      if BytecodeIR::CONDITIONAL_BRANCHES.include?(insn.op) && target && holds_proc.call(idx, insn.reg)
        succ = insn.op == :JMPIF ? [target] : succ - [target]
      end
      stack.concat(succ)
      handlers.each { |edge| stack << edge.target if edge.src == idx }
    end
    seen
  end

  # Reaching definitions that count a nested block's SETUPVAR into the method's registers.
  def definitions(irep, _program, idx, reg)
    BytecodeIR.reaching_definitions(irep, idx, reg.to_s, through_handlers: true, shared: true)
  end

  def return_value_why(irep, program, idx, reg, entry, holds_proc)
    defs = definitions(irep, program, idx, reg)
    return 'returns a value whose definitions cannot be listed' unless defs && !defs.empty?

    defs.each do |df|
      if df.entry?
        next if entry.kind == :self && df.reg.to_s == '0'

        return "returns R#{df.reg} as passed in"
      end
      writer = BytecodeIR.for(irep).source_at(df.index)
      case entry.kind
      when :self
        next if writer.op == :LOADSELF
      when :block_value
        if writer.op == :BLKCALL && holds_proc.call(df.index, writer.reg)
          next
        end
        next if writer.op == :SEND && writer.sym == 'call' && writer.reg.to_s == df.reg.to_s &&
                holds_proc.call(df.index, writer.reg)
      end
      what = entry.kind == :self ? 'self' : 'a value its block returned'
      return "returns the value of #{writer.op}#{writer.sym ? " :#{writer.sym}" : ''} (line #{writer.lineno}), not #{what}"
    end
    nil
  end

  # --------------------------------------------------------------------------------------------- native sources

  REGISTRATION = /\bmrb_define_(module_function|singleton_method|class_method|method)(?:_id)?\s*\(\s*\w+\s*,\s*[\w>-]+\s*,\s*(?:"([^"]+)"|MRB_SYM\((\w+)\))\s*,\s*(\w+)\s*,/
  YIELD_ARGV = /\Amrb_yield_argv\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\d+)\s*,\s*[^()]*\)\z/
  YIELD_ONE = /\Amrb_yield\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*[^()]*(?:\([^()]*\))?[^()]*\)\z/
  # mrb_get_args format specifiers and the number of pointer arguments each consumes (src/class.c).
  FORMAT_ARGS = { 'o' => 1, 'C' => 1, 'S' => 1, 'A' => 1, 'H' => 1, 'z' => 1, 'f' => 1, 'i' => 1, 'b' => 1, 'n' => 1,
                  '&' => 1, 's' => 2, 'a' => 2, 'd' => 2, '*' => 2, '|' => 0, '!' => 0, '?' => 1 }.freeze

  # Comments out, string literals kept (the registrations name methods with them).
  def strip_comments(source)
    source.gsub(%r{("(?:\\.|[^"\\\n])*")|//[^\n]*|/\*.*?\*/}m) { Regexp.last_match(1) || ' ' }
  end

  # [[kind, function], ...] of every registration of +name+ in +source+.
  def registrations(source, name)
    out = []
    strip_comments(source).scan(REGISTRATION) do |kind, quoted, sym, function|
      out << [kind, function] if (quoted || sym) == name
    end
    out
  end

  # The body text of C function +function+ (between its braces), the mrb_state parameter name, or nil.
  def function_body(source, function)
    text = strip_comments(source)
    m = /(?:^|[\s;}])(?:static\s+)?(?:inline\s+)?mrb_value\s+#{Regexp.escape(function)}\s*\(\s*mrb_state\s*\*\s*(\w+)\s*,\s*mrb_value\s*\w*\s*\)\s*\{/.match(text)
    return nil unless m

    start = m.end(0)
    depth = 1
    i = start
    while i < text.size && depth.positive?
      c = text[i]
      if c == '"' || c == "'"
        j = i + 1
        j += (text[j] == '\\' ? 2 : 1) while j < text.size && text[j] != c
        i = j
      elsif c == '{' then depth += 1
      elsif c == '}' then depth -= 1
      end
      i += 1
    end
    depth.zero? ? [text[start...(i - 1)], m[1]] : nil
  end

  # nil when C function +function+ of +source+ returns its block's value on every path a block is given, yields
  # +arity+ arguments and lets its block go nowhere else; else why not.
  def native_function_why(source, function, arity)
    body, state = function_body(source, function)
    return "#{function}: no definition `mrb_value #{function}(mrb_state*, mrb_value) { ... }` found" unless body

    gets = body.scan(/\bmrb_get_args\s*\(\s*#{state}\s*,\s*"([^"]*)"((?:\s*,\s*&\s*\w+)*)\s*\)/)
    return "#{function}: not exactly one mrb_get_args call" unless gets.size == 1 && body.scan(/\bmrb_get_args\b/).size == 1

    format, pointers = gets.first
    pointers = pointers.scan(/&\s*(\w+)/).flatten
    blk = nil
    pos = 0
    format.each_char do |c|
      count = FORMAT_ARGS[c] or return "#{function}: mrb_get_args format #{format.inspect} is not modelled"
      blk = pointers[pos] if c == '&'
      pos += count
    end
    return "#{function}: mrb_get_args reads no block" unless blk && pos == pointers.size

    b = Regexp.escape(blk)
    s = Regexp.escape(state)
    yields = []
    yield_re = /\bmrb_yield_argv\s*\(\s*#{s}\s*,\s*#{b}\s*,\s*(\d+)\s*,|\bmrb_yield\s*\(\s*#{s}\s*,\s*#{b}\s*,/
    body.scan(yield_re) { |n| yields << (n.first ? n.first.to_i : 1) }
    return "#{function}: never yields" if yields.empty?
    return "#{function}: yields #{yields.uniq.join('/')} argument(s), the block declares #{arity}" unless yields.all?(arity)

    known = 1 + body.scan(/\bmrb_value\s+[\w\s,]*\b#{b}\b[\w\s,]*;/).size + body.scan(/\bmrb_nil_p\s*\(\s*#{b}\s*\)/).size + yields.size
    uses = body.scan(/\b#{b}\b/).size
    return "#{function}: its block #{blk} is used other than by mrb_get_args, mrb_nil_p and a yield" unless uses == known

    body.to_enum(:scan, /\breturn\b\s*([^;]*);/).each do
      m = Regexp.last_match
      expr = m[1].strip
      next if yield_expr?(expr, s, b)
      next if expr.match?(/\Amrb_nil_value\s*\(\s*\)\z/) &&
              body[0...m.begin(0)].match?(/if\s*\(\s*mrb_nil_p\s*\(\s*#{b}\s*\)\s*\)\s*\{?\s*\z/)

      if expr.match?(/\A\w+\z/)
        v = Regexp.escape(expr)
        assigns = body.scan(/\b#{v}\s*=(?!=)/).size
        decl = body.match(/\b(?:const\s+)?mrb_value\s+#{v}\s*=\s*([^;]*);/)
        if assigns == 1 && decl && yield_expr?(decl[1].strip, s, b) && !body.match?(/&\s*#{v}\b|\b#{v}\s*(?:\+\+|--)/)
          next
        end
      end
      return "#{function}: `return #{expr}` is not the value of a yield"
    end
    nil
  end

  def yield_expr?(expr, state, blk)
    m = YIELD_ARGV.match(expr) || YIELD_ONE.match(expr)
    m && m[1] == state.delete('\\') && m[2] == blk.delete('\\')
  end

  # nil when every registration of the declared native in +paths+ (absolute) is verified or reviewed; else why not.
  # Answers [why, registrations found].
  def native_entry_why(entry, paths, reviewed: REVIEWED)
    found = 0
    paths.each do |path|
      source = File.binread(path).force_encoding(Encoding::BINARY)
      regs = registrations(source, entry.name)
      found += regs.size
      regs.each do |kind, function|
        singleton = entry.owner.end_with?('.singleton')
        if singleton ? kind == 'method' : %w[singleton_method class_method].include?(kind)
          return ["#{path}: #{function} is registered with mrb_define_#{kind}, the declaration is on #{entry.owner}", found]
        end

        why = native_function_why(source, function, entry.arity)
        next unless why
        next if reviewed?(entry, path, source, reviewed)

        return ["#{File.basename(path)}: #{why} (verify it, or review it into native_block_returns_reviewed.rb)", found]
      end
    end
    [nil, found]
  end

  def reviewed?(entry, path, source, reviewed)
    files = reviewed[entry.key] or return false
    files.any? { |relative, digest| path.end_with?("/#{relative}") && Array(digest).include?(Digest::SHA256.hexdigest(source)) }
  end
end

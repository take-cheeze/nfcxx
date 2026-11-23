# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'core_defs'

# LITERAL_MINMAX: `[a, b].min` / `.max` (no block) builds an Array only to hand it to Enumerable#min, which yields each
# element through a `|*val|` rest Array as well. When the literal goes straight into the call, the call is the direct
# `Enumerable_min_impl(M, rA, nil)` the compiler already proved for that receiver, and nothing else reads the Array,
# the pair becomes one call of a shared helper over the element registers. The helper answers an all-fixnum list
# itself, as Enumerable#min does (`result = val if (val <=> result) < 0`: the first of equal elements wins); any other
# list is built into an Array and handed to the same Enumerable_min_impl, so it runs the original code.
#
# A site is placed only when all of these hold:
#   adjacent   the SEND follows the ARRAY directly, is entered only from it, and reads the Array as its receiver
#   dead       no other instruction may read the ARRAY's register while it holds the Array (a handler included)
#   direct     the SEND's text is exactly that direct call (any other binding keeps the pair)
#   stock      Enumerable#min/max is mruby's mrblib/enum.rb definition and the only one an exact Array reaches; every
#              definition of Array#each and #__svalue an exact Array, and of Integer#<=>, #< and #> an Integer, reaches
#              is mruby's own (literal_minmax_stock?)
# BC2CPP_LITERAL_MINMAX=0 turns it off.
class CodeGen
  LITERAL_MINMAX_MAX = 8
  LITERAL_MINMAX_NAMES = %w[min max].freeze

  def literal_minmax_enabled?
    ENV['BC2CPP_LITERAL_MINMAX'] != '0'
  end

  # {ARRAY index => {send:, name:, elems:, lead:}} for +irep+.
  def literal_minmax_sites(irep)
    @literal_minmax_sites ||= {}
    return @literal_minmax_sites[irep.label] if @literal_minmax_sites.key?(irep.label)

    @literal_minmax_sites[irep.label] = literal_minmax_sites_uncached(irep)
  end

  def literal_minmax_visit(irep, idx, bypassed)
    state = @literal_minmax_state
    return unless bypassed && state && state[:label] == irep.label && state[:mapped].include?(idx)

    state[:bypassed] << idx
  end

  # The placed text for +idx+, or the usual text (+compile+).
  def literal_minmax_insn(irep, idx, reg_offset)
    state = @literal_minmax_state
    return yield unless state && idx && irep && state[:label] == irep.label && state[:mapped].include?(idx)
    if reg_offset != 0 || @resumable
      state[:bypassed] << idx
      return yield
    end

    if (site = state[:sites][idx])
      state[:hooked] << idx
      return ''
    end
    i = state[:send_of][idx]
    site = state[:sites][i]
    m = LITERAL_MINMAX_CALL.match(yield)
    state[:hooked] << idx
    # A text that is not the proven direct call cannot stand without its Array: the plan is refused (see below).
    unless m && m[2].to_i == site[:lead] && m[3] == site[:name]
      state[:failed] << i
      return ''
    end

    state[:used] << site[:name]
    "#{m[1]}  { mrb_value bc2cpp_mm[] = { #{site[:elems].map { |r| "r#{r}" }.join(', ')} }; " \
      "r#{site[:lead]} = bc2cpp_ary_#{site[:name]}(M, bc2cpp_mm, #{site[:elems].size}); }\n"
  end

  # Runs the block under the plan of +label+; a site not placed whole is dropped and the method compiles again.
  def literal_minmax_compile_method(label)
    return yield unless literal_minmax_enabled?

    irep = @ireps.fetch(label)
    @literal_minmax_kept ||= {}
    sites = @literal_minmax_kept[label] || literal_minmax_sites(irep)
    loop do
      return yield if sites.empty?

      state = { label: label, sites: sites, send_of: sites.to_h { |i, s| [s[:send], i] },
                mapped: Set.new(sites.flat_map { |i, s| [i, s[:send]] }), hooked: Set.new, bypassed: Set.new,
                failed: Set.new, used: Set.new }
      saved = @literal_minmax_state
      @literal_minmax_state = state
      result = begin
        yield
      ensure
        @literal_minmax_state = saved
      end
      bad = sites.each_with_object(Set.new) do |(i, s), out|
        both = [i, s[:send]]
        out << i if state[:failed].include?(i) || both.any? { |k| state[:bypassed].include?(k) || !state[:hooked].include?(k) }
      end
      if bad.empty?
        @literal_minmax_kept[label] = sites
        return result
      end

      sites = sites.reject { |i, _| bad.include?(i) }
      @literal_minmax_kept[label] = sites
    end
  end

  # The helpers the compiled texts name, defined after the forward declarations (Enumerable_min_impl is declared).
  def emit_literal_minmax_helpers(compiled)
    LITERAL_MINMAX_NAMES.filter_map do |name|
      next unless compiled.any? { |m| m.is_a?(Hash) && m[:code].to_s.include?("bc2cpp_ary_#{name}(M, ") }

      op = name == 'min' ? '<' : '>'
      <<~CPP
        // LITERAL_MINMAX: Enumerable##{name} of a literal list (codegen_literal_minmax.rb).
        [[gnu::noinline]] inline mrb_value bc2cpp_ary_#{name}(mrb_state* M, const mrb_value* v, mrb_int n) {
          mrb_int k = 0;
          while (k < n && mrb_fixnum_p(v[k])) k++;
          if (k == n) {
            mrb_value r = v[0];
            for (k = 1; k < n; k++) if (mrb_fixnum(v[k]) #{op} mrb_fixnum(r)) r = v[k];
            return r;
          }
          return Enumerable_#{name}_impl(M, mrb_ary_new_from_values(M, n, v), mrb_nil_value());
        }
      CPP
    end.join
  end

  private

  LITERAL_MINMAX_CALL = %r{\A((?:[ \t]*(?://[^\n]*)?\n)*)  r(\d+) = Enumerable_(min|max)_impl\(M, r\d+, mrb_nil_value\(\)\);\n\z}.freeze

  def literal_minmax_sites_uncached(irep)
    return {} unless literal_minmax_stock?

    prog = BytecodeIR.for(irep)
    return {} unless prog.resolved? && prog.handlers_resolved?

    preds = prog.instruction_predecessors(include_handlers: true)
    return {} unless preds

    params = stack_tuple_params(irep)
    sites = {}
    prog.instructions.each do |ins|
      next unless ins.op == :ARRAY

      i = ins.index
      lit = prog.container_literal(i)
      next unless lit && lit.kind == :array && lit.count.between?(1, LITERAL_MINMAX_MAX)

      send = prog.source_at(i + 1)
      next unless send && %i[SEND SEND0].include?(send.op) && LITERAL_MINMAX_NAMES.include?(send.sym.to_s)
      next unless preds[i + 1].to_a == [i] && send.reg.to_i == ins.source.reg.to_i
      next unless (send.argc_operand.nil? || send.argc.to_i.zero?) && !send.keyword_arguments? &&
                  !BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(send.op)

      lead = ins.source.reg.to_i
      next if lead.between?(1, params + 1)
      next unless literal_minmax_dead?(irep, prog, i, lead, params)

      sites[i] = { send: i + 1, name: send.sym.to_s, elems: lit.value_regs.map(&:to_i), lead: lead }
    end
    sites
  end

  # Only the SEND after the ARRAY at +i+ reads the Array.
  def literal_minmax_dead?(irep, prog, i, lead, params)
    prog.instructions.all? do |ins|
      k = ins.index
      next true if k == i || k == i + 1

      reads = ins.op == :MOVE ? [ins.source.regs[1].to_i] : stack_tuple_reads(ins.source, params)
      next true unless reads == :all || reads.include?(lead)

      prods = BytecodeIR.producers(irep, k, lead, through_handlers: true)
      !prods.nil? && prods.none? { |p| !p.entry? && p.index == i }
    end
  end

  def literal_minmax_stock?
    return @literal_minmax_stock unless @literal_minmax_stock.nil?

    @literal_minmax_stock = literal_minmax_stock_uncached?
  end

  def literal_minmax_stock_uncached?
    world = escape_analyzer&.world
    return false unless world

    core = ->(d) { d.core && !d.installer && d.kind != :ivar_accessor }
    stock = LITERAL_MINMAX_NAMES.all? do |name|
      list = world.defs_for(name, ['Array'], true)
      !list.nil? && list.size == 1 && list.first.owner == 'Enumerable' && core.call(list.first) &&
        list.first.irep && @ireps[list.first.irep]&.file.to_s.end_with?('mrblib/enum.rb')
    end
    # nil is a call the tables cannot bound; an empty list reaches natives only, which the world lists when it has any.
    stock && %w[each __svalue].all? { |name| (l = world.defs_for(name, ['Array'], true)) && l.all?(&core) } &&
      %w[<=> < >].all? { |name| (l = world.defs_for(name, ['Integer'], true)) && l.all?(&core) }
  end
end

# Prepended to CodeGen: compile_method under the plan.
module LiteralMinmaxCompileMethod
  def compile_method(label)
    literal_minmax_compile_method(label) { super(label) }
  end
end

# Prepended to CodeGen: the placed instructions' text.
module LiteralMinmaxCompileInsn
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    literal_minmax_insn(irep, idx, reg_offset) { super(insn, irep, owner_def, idx, reg_offset) }
  end
end

CodeGen.prepend(LiteralMinmaxCompileMethod)
CodeGen.prepend(LiteralMinmaxCompileInsn)

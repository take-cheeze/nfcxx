# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'escape_analysis'

# STACK_TUPLES: an Array literal of 1..8 immediates that never leaves its frame keeps its elements in a
# C++ array of mrb_value, not in an mruby Array. An immediate (fixnum, nil, true, false, symbol) needs no GC root, so
# the buffer is an ordinary local.
#
# A site is placed only when all of these hold (refusal is always the answer when unsure):
#   escape        the ESCAPE_ANALYSIS verdict for the creation is non-escaping
#   closures      the irep builds no BLOCK or LAMBDA, which could read the frame's register by pointer
#   cycle         the creation is not on a cycle, so one frame holds one instance of it
#   elements      every element register's reaching definitions are immediate loads
#   redefinition  no Ruby definition of [], []=, size or length reaches an exact Array
#   uses          every instruction that reads a register holding the array is a MOVE (a copy; the reaching
#                 definitions follow it), GETIDX or SETIDX with a literal index, or SEND size/length with no arguments
#
# Each planned instruction is compiled by StackTupleCompileInsn, prepended last so it runs outside every other
# compile_insn wrapper and returns the placed text without calling super. A planned instruction that a path bypasses
# (suppressed, glued, behind a guarded prefix, in a resumable or shifted body) makes the method compile again without
# its plan, so no read of the frame register survives without its buffer.
class CodeGen
  STACK_TUPLE_MAX = 8
  STACK_TUPLE_IMMEDIATE_OPS = Set[:LOADNIL, :LOADTRUE, :LOADFALSE, :LOADSYM].freeze
  # Instructions that read no register: they write their leading register at most.
  STACK_TUPLE_PURE_OPS = Set[
    :NOP, :JMP, :JMPUW, :ENTER, :STOP, :RETNIL, :RETTRUE, :RETFALSE, :LOADSELF, :LOADNIL, :LOADTRUE,
    :LOADFALSE, :LOADSYM, :LOADL, :STRING, :SYMBOL, :GETIV, :GETCONST, :GETGV, :GETCV, :GETUPVAR, :OCLASS,
    :TCLASS, :EXCEPT, :ALIAS, :UNDEF, :DEBUG, :KEYEND
  ].freeze
  STACK_TUPLE_STORE_OPS = Set[:SETIV, :SETGV, :SETSV, :SETCV, :SETCONST, :SETMCNST, :SETUPVAR].freeze
  STACK_TUPLE_LEAD_READS = Set[:JMPIF, :JMPNOT, :JMPNIL, :RAISEIF, :RETURN, :RETURN_BLK, :BREAK, :ADDI,
                               :SUBI].freeze
  STACK_TUPLE_BINARY_OPS = Set[:ADD, :SUB, :MUL, :DIV, :EQ, :LT, :LE, :GT, :GE].freeze
  STACK_TUPLE_WINDOW_OPS = Set[:CLASS, :MODULE, :SCLASS, :EXEC, :DEF, :TDEF, :SDEF].freeze
  STACK_TUPLE_LIST_OPS = Set[:ARYCAT, :ARYSPLAT, :HASHCAT, :STRCAT, :RANGE_INC, :RANGE_EXC, :HASH,
                             :HASHADD].freeze
  STACK_TUPLE_SIZE_NAMES = Set['size', 'length'].freeze
  # The Array methods a placed instruction stands in for: a Ruby definition of any of them could answer instead.
  STACK_TUPLE_REDEFINABLE = %w[[] []= size length].freeze

  # One ARRAY the plan places. +elems+ are its element registers in order; +uses+ maps each instruction that reads the
  # array to its StackTupleUse.
  StackTupleSite = Struct.new(:idx, :lead, :elems, :uses, keyword_init: true)
  # One instruction reading the array. +kind+ is :get (index), :set (index and the value register) or :size; +dest+ is
  # the register the instruction writes.
  StackTupleUse = Struct.new(:site, :kind, :index, :value, :dest, keyword_init: true)

  def stack_tuples_enabled?
    ENV['BC2CPP_STACK_TUPLES'] != '0'
  end

  # The plan for +irep+: {ARRAY index => StackTupleSite}, empty when nothing is placed or the analysis is off.
  def stack_tuple_plan(irep)
    return {} unless stack_tuples_enabled?

    analyzer = escape_analyzer or return {}
    @stack_tuple_where = irep.label
    # A closure could read the frame's registers by pointer.
    unless EscapeAnalysis.op_sites(irep, EscapeAnalysis::CLOSURE_OPS).empty?
      refuse(:closure_in_irep)
      return {}
    end

    # Reaching definitions and the exception edges need a resolved CFG and handler table.
    prog = BytecodeIR.for(irep)
    creations = prog.instructions.select { |ins| ins.op == :ARRAY }
    return {} if creations.empty?

    unless prog.resolved? && prog.handlers_resolved?
      refuse(:cfg_or_handlers_unresolved)
      return {}
    end
    unless stack_tuple_defs_clean?(analyzer.world)
      refuse(:redefined_array_method)
      return {}
    end

    plan = {}
    creations.each do |ins|
      @stack_tuple_where = "#{irep.label}##{ins.index}"
      site = stack_tuple_site(irep, prog, ins.index, analyzer)
      plan[ins.index] = site if site
    end
    plan
  end

  # Runs the block (the method's compile) under the plan. A plan that was not placed whole is refused and the block
  # runs again with none, so the output is the baseline for that method.
  def stack_tuple_compile_method(label)
    irep = @ireps.fetch(label)
    plan = @stack_tuple_off&.include?(label) ? {} : stack_tuple_plan(irep)
    warn "bc2cpp stack tuple plan #{label}: #{plan.keys}" if ENV['BC2CPP_STACK_TUPLES_REPORT'] == '1'
    return yield(plan) if plan.empty?

    state = { label: label, plan: plan, map: stack_tuple_map(plan), hooked: Set.new, bypassed: Set.new }
    saved = @stack_tuple_state
    @stack_tuple_state = state
    text = begin
      yield(plan)
    ensure
      @stack_tuple_state = saved
    end
    return text if stack_tuple_complete?(state)

    unplaced = state[:map].keys.reject { |idx| state[:hooked].include?(idx) }
    @stack_tuple_where = label
    refuse("placement incomplete (bypassed #{state[:bypassed].to_a.sort}, not placed #{unplaced.sort})")
    (@stack_tuple_off ||= Set.new) << label
    yield({})
  end

  # The declarations of the placed buffers of the method body +irep+ (empty without a plan).
  def stack_tuple_declarations(irep)
    state = @stack_tuple_state
    return '' unless state && state[:label] == irep.label

    state[:plan].values.map { |site| "  mrb_value #{stack_tuple_name(site.idx)}[#{site.elems.size}];\n" }.join
  end

  # Called from the method's instruction loop. +bypassed+ says the instruction's text comes from a path that does not
  # call compile_insn (suppressed, glued, or behind a guarded prefix).
  def stack_tuple_visit(irep, idx, bypassed)
    state = @stack_tuple_state
    return unless bypassed && state && state[:label] == irep.label && state[:map].key?(idx)

    state[:bypassed] << idx
  end

  # The placed text for the planned instruction +idx+ of +irep+, or nil when +idx+ is not planned for this method.
  def stack_tuple_insn(irep, idx, reg_offset)
    state = @stack_tuple_state
    return nil unless state && idx && irep && state[:label] == irep.label

    entry = state[:map][idx] or return nil
    # A shifted body names other registers, and a resumable body keeps its registers outside this C++ frame.
    if reg_offset != 0 || @resumable
      state[:bypassed] << idx
      return nil
    end

    state[:hooked] << idx
    kind, what = entry
    kind == :site ? stack_tuple_site_text(what) : stack_tuple_use_text(what)
  end

  private

  def stack_tuple_name(idx)
    "bc2cpp_tup#{idx}"
  end

  def stack_tuple_map(plan)
    plan.each_with_object({}) do |(idx, site), map|
      map[idx] = [:site, site]
      site.uses.each { |j, use| map[j] = [:use, use] }
    end
  end

  def stack_tuple_complete?(state)
    state[:bypassed].empty? && state[:map].keys.all? { |idx| state[:hooked].include?(idx) }
  end

  def stack_tuple_site_text(site)
    name = stack_tuple_name(site.idx)
    # The elements are copied before the destination is cleared: the destination may be one of them.
    copies = site.elems.each_with_index.map { |reg, k| "  #{name}[#{k}] = r#{reg};\n" }
    (copies + ["  r#{site.lead} = mrb_nil_value();\n"]).join
  end

  def stack_tuple_use_text(use)
    name = stack_tuple_name(use.site.idx)
    n = use.site.elems.size
    case use.kind
    when :get
      # Array#[] with a literal index: a negative index counts from the end; an index outside the array is nil.
      k = use.index.negative? ? use.index + n : use.index
      value = k.between?(0, n - 1) ? "#{name}[#{k}]" : 'mrb_nil_value()'
      "  r#{use.dest} = #{value};\n"
    when :set
      # `a[i] = v` answers v; the buffer is written before the register is.
      "  #{name}[#{use.index}] = r#{use.value}; r#{use.dest} = r#{use.value};\n"
    when :size
      "  r#{use.dest} = mrb_fixnum_value(#{n});\n"
    end
  end

  # True when every definition of the Array methods in STACK_TUPLE_REDEFINABLE that can reach an exact Array is one of
  # mruby's own natives.
  def stack_tuple_defs_clean?(world)
    STACK_TUPLE_REDEFINABLE.all? do |name|
      list = world.defs_for(name, ['Array'], true)
      !list.nil? && list.all? { |d| d.core && d.irep.nil? && d.copy_irep.nil? && !d.installer && d.kind != :ivar_accessor }
    end
  end

  def stack_tuple_site(irep, prog, idx, analyzer)
    lit = prog.container_literal(idx)
    return refuse(:not_literal_array) unless lit && lit.kind == :array && lit.count.between?(1, STACK_TUPLE_MAX)

    lead = reg_int(prog.source_at(idx).reg)
    return refuse(:no_lead) unless lead

    elems = lit.value_regs.map { |reg| reg.to_i }
    return refuse(:element_not_immediate) unless elems.all? { |reg| stack_tuple_immediate_at?(irep, idx, reg) }
    return refuse(:in_cycle) if stack_tuple_cycle?(prog, idx)

    verdict = analyzer.creation(irep, idx)
    return refuse(verdict.reason || :escapes) if verdict.escapes?

    tracked = verdict.tracked.map { |reg| reg.to_i }.to_set
    tracked.add(lead)
    params = stack_tuple_params(irep)
    return refuse(:parameter_register) if tracked.any? { |reg| reg.between?(1, params + 1) }

    site = StackTupleSite.new(idx: idx, lead: lead, elems: elems, uses: {})
    uses = stack_tuple_uses(irep, prog, site, tracked, params)
    return refuse(:use_refused) unless uses

    site.uses = uses
    site
  end

  # Every instruction that reads a register which may hold the array, against the reaching definitions of that
  # register. nil refuses the site.
  def stack_tuple_uses(irep, prog, site, tracked, params)
    uses = {}
    prog.instructions.each do |ins|
      j = ins.index
      insn = ins.source
      next if j == site.idx || insn.op == :MOVE

      reads = stack_tuple_reads(insn, params)
      candidates = reads == :all ? tracked : reads.select { |reg| tracked.include?(reg) }
      candidates.each do |reg|
        prods = BytecodeIR.producers(irep, j, reg, through_handlers: true)
        return refuse("no_producers for r#{reg} read by #{insn.op} at #{j}") if prods.nil? || prods.empty?

        holding = prods.count { |p| !p.entry? && p.index == site.idx }
        next if holding.zero?
        return refuse(:mixed_definitions) unless holding == prods.size

        use = stack_tuple_use(irep, prog, j, insn, reg, site)
        return nil unless use
        return refuse(:conflicting_use) if uses.key?(j) && uses[j] != use

        uses[j] = use
      end
    end
    uses
  end

  # The placed form of the instruction at +j+ reading the array in +reg+ (its leading register), or nil.
  def stack_tuple_use(irep, _prog, j, insn, reg, site)
    own = reg_int(insn.reg)
    # GETIDX0 reads its receiver from R(b) and writes R(a) = R(b)[0] (vm.c OP_GETIDX0).
    if insn.op == :GETIDX0 && reg == reg_int(insn.regs[1])
      return StackTupleUse.new(site: site, kind: :get, index: 0, dest: own)
    end
    return refuse(:"read_by_#{insn.op}") unless own && reg == own

    case insn.op
    when :GETIDX
      k = stack_tuple_literal_index(irep, j, own + 1)
      k && StackTupleUse.new(site: site, kind: :get, index: k, dest: own)
    when :SETIDX
      k = stack_tuple_literal_index(irep, j, own + 1)
      in_bounds = k&.between?(0, site.elems.size - 1)
      return refuse(:store_index_or_value) unless in_bounds && stack_tuple_immediate_at?(irep, j, own + 2)

      StackTupleUse.new(site: site, kind: :set, index: k, value: own + 2, dest: own)
    when :SEND, :SEND0
      return refuse(:send_not_size) unless STACK_TUPLE_SIZE_NAMES.include?(insn.sym) && stack_tuple_no_arguments?(insn)

      StackTupleUse.new(site: site, kind: :size, dest: own)
    end
  end

  def stack_tuple_no_arguments?(insn)
    (insn.n_spec.nil? || insn.n_spec == '0') && insn.nk_spec.nil? && BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(!insn.op)
  end

  # True when every reaching definition of +reg+ at +at+ is an immediate: a LOADNIL/LOADTRUE/LOADFALSE/LOADSYM, or a
  # LOADI whose value is a fixnum.
  def stack_tuple_immediate_at?(irep, at, reg)
    prods = BytecodeIR.producers(irep, at, reg, through_handlers: true)
    return false if prods.nil? || prods.empty?

    prods.all? do |p|
      next false if p.entry?
      next true if STACK_TUPLE_IMMEDIATE_OPS.include?(p.op)
      next false unless BytecodeIR::Ops::LOADI_OPS.include?(p.op)

      p.op != :LOADI32 || loadi_proven_fixnum?(p.insn)
    end
  end

  # The integer +reg+ holds at +at+ when exactly one literal load reaches it, else nil.
  def stack_tuple_literal_index(irep, at, reg)
    prods = BytecodeIR.producers(irep, at, reg, through_handlers: true)
    return refuse(:index_not_literal) unless prods&.size == 1 && !prods.first.entry?

    insn = prods.first.insn
    case insn.op
    when :LOADI__1 then -1
    when /\ALOADI_([0-7])\z/ then Regexp.last_match(1).to_i
    when :LOADI8, :LOADI16, :LOADI32 then insn.imm_operand&.to_i
    end
  end

  # Does the instruction at +idx+ lie on a cycle (normal or handler edges)?
  def stack_tuple_cycle?(prog, idx)
    seen = Set.new
    work = prog.successors_of(idx, include_handlers: true).dup
    until work.empty?
      i = work.pop
      return true if i == idx
      next unless seen.add?(i)

      work.concat(prog.successors_of(i, include_handlers: true))
    end
    false
  end

  def stack_tuple_params(irep)
    fields = irep.enter ? irep.enter.enter_fields : []
    fields.first(6).sum(&:to_i)
  end

  # A superset of the registers +insn+ reads (its leading register is its own). :all when the op is not modelled.
  def stack_tuple_reads(insn, params)
    op = insn.op
    lead = reg_int(insn.reg)
    return [] if STACK_TUPLE_PURE_OPS.include?(op) || BytecodeIR::Ops::LOADI_OPS.include?(op)
    return [] if %i[RETNIL RETTRUE RETFALSE].include?(op)
    return [0] if op == :RETSELF
    return (1..(params + 1)).to_a if op == :ARGARY
    return [params + 1] if op == :BLKPUSH
    return [reg_int(insn.regs[1])] if %i[GETIDX0 AREF].include?(op)
    return :all if lead.nil?
    # R[b] and R[b+1] of ADDILV/SUBILV are the method-call fallback's scratch window: written, never read.
    return [lead] if %i[ADDILV SUBILV].include?(op) || STACK_TUPLE_LEAD_READS.include?(op)
    return [lead, lead + 1] if STACK_TUPLE_BINARY_OPS.include?(op)
    return [lead, lead + 1, lead + 2] if op == :SETIDX
    return [lead, lead + 1] if op == :GETIDX
    return [lead, reg_int(insn.paren_reg)].compact if op == :GETMCNST
    return [reg_int(insn.reg_operand), lead].compact if STACK_TUPLE_STORE_OPS.include?(op)
    return [0, lead, lead + 1, lead + 2, lead + 3] if STACK_TUPLE_WINDOW_OPS.include?(op)
    return [reg_int(insn.regs[0]), reg_int(insn.regs[1])] if op == :RESCUE
    return send_reads(insn, lead) if BytecodeIR::Ops::SEND.include?(op)
    return (lead..(lead + insn.uint_operand.to_i + 1)).to_a if op == :BLKCALL
    return array_reads(insn, lead) if op == :ARRAY
    return (lead..(lead + insn.uint_operand.to_i)).to_a if op == :ARYPUSH
    return (lead..(lead + (2 * insn.uint_operand.to_i) + 3)).to_a if STACK_TUPLE_LIST_OPS.include?(op)

    :all
  end

  # The receiver (unless the op is a self send), the positional and keyword argument registers, and the block register.
  def send_reads(insn, lead)
    return :all if insn.nk_spec == '*'

    positional = insn.n_spec.nil? ? 0 : (insn.n_spec == '*' ? 1 : insn.n_spec.to_i)
    kw = insn.nk_spec.nil? ? 0 : 2 * insn.nk_spec.to_i
    top = lead + positional + kw + (BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(insn.op) ? 1 : 0)
    BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op) ? [] : [lead] + (lead + 1..top).to_a
  end

  def array_reads(insn, lead)
    three = insn.src_and_literal
    src = three ? three[0].to_i : lead
    n = three ? three[1].to_i : insn.uint_operand.to_i
    n.zero? ? [] : (src...(src + n)).to_a
  end

  def reg_int(reg)
    reg.nil? ? nil : reg.to_i
  end

  # Always nil. BC2CPP_STACK_TUPLES_REPORT=1 prints why the ARRAY under analysis (@stack_tuple_where) is not placed.
  def refuse(reason)
    warn "bc2cpp stack tuple refused at #{@stack_tuple_where}: #{reason}" if ENV['BC2CPP_STACK_TUPLES_REPORT'] == '1'
    nil
  end
end

# Prepended to CodeGen: compile_method runs under a plan and retries without one when the plan was not placed whole.
module StackTupleCompileMethod
  def compile_method(label)
    stack_tuple_compile_method(label) { |_plan| super(label) }
  end
end

# Prepended to CodeGen, last: outermost compile_insn for the planned instructions.
module StackTupleCompileInsn
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    stack_tuple_insn(irep, idx, reg_offset) || super
  end
end

CodeGen.prepend(StackTupleCompileMethod)
CodeGen.prepend(StackTupleCompileInsn)

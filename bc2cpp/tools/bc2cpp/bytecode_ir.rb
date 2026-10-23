# frozen_string_literal: true

# A conservative normal-flow view of an mruby IREP. The original disassembly
# remains the source of opcode semantics; this layer gives analyses stable
# instruction identities and explicit basic-block edges. Instruction#successors,
# the blocks and the default queries are NORMAL flow only. Catch-handler edges
# live apart from them (bytecode_ir_handlers.rb) and are opt-in through
# `include_handlers:`, so a consumer proving something about exception flow
# must ask for them explicitly.
module BytecodeIR
  Instruction = Struct.new(:index, :source, :successors, keyword_init: true) do
    def addr
      source.addr
    end

    def op
      source.op
    end
  end

  # A branch by instruction address: +src+ is the branching instruction, +target+
  # the address it names (not necessarily an instruction; see Program#resolved?).
  BranchEdge = Struct.new(:src, :target, keyword_init: true)

  BasicBlock = Struct.new(:id, :instructions, :successors, :predecessors, keyword_init: true)

  # Ops after which control never reaches the next instruction. RAISE and
  # RAISEIF are deliberately absent: a missing predecessor makes a proof wrong
  # while an extra one only costs a proof, so they conservatively fall through.
  NO_FALLTHROUGH = %w[JMP JMPUW RETURN RETURN_BLK RETSELF RETNIL RETTRUE RETFALSE BREAK STOP].freeze
  CONDITIONAL_BRANCHES = %w[JMPIF JMPNOT JMPNIL].freeze
  TERMINATORS = (NO_FALLTHROUGH + CONDITIONAL_BRANCHES).freeze
  # Predecessor id of the method-entry edge into instruction 0.
  ENTRY = -1
  BRANCH_OPS = %w[JMP JMPUW JMPIF JMPNOT JMPNIL].freeze
  # Conditional-branch kinds (Decoded#cond): which test of R(a) sends control to the branch target.
  COND_IF = 1 # JMPIF: R(a) truthy
  COND_NOT = 2 # JMPNOT: R(a) falsy
  COND_NIL = 3 # JMPNIL: R(a) nil
  COND_KINDS = { 'JMPIF' => COND_IF, 'JMPNOT' => COND_NOT, 'JMPNIL' => COND_NIL }.freeze

  # One instruction's analysis-independent operands (Program#decoded): +op+, +cond+ (a COND_* kind, nil unless a
  # conditional branch), +reg+ (the leading register as an Integer, nil when the leading operand is not a register)
  # and +goto+ (the instruction index an explicit branch targets; nil for any other op, or an unresolved target).
  Decoded = Struct.new(:op, :cond, :reg, :goto)

  # Decode +insn+ as Program#decoded does. Reads only op, reg and, for a branch op, branch_target, so an
  # instruction-like object from a check needs to answer nothing else. Without +address_to_index+ +goto+ stays nil.
  def self.decode(insn, address_to_index = nil)
    op = insn.op
    goto = address_to_index[insn.branch_target] if address_to_index && BRANCH_OPS.include?(op)
    Decoded.new(op, COND_KINDS[op], insn.reg&.to_i, goto)
  end

  class Program
    attr_reader :instructions, :blocks, :address_to_index
    # The irep's local-register count (R0 and the locals; vm.c irep->nlocals), nil when the irep does not carry it.
    attr_reader :nlocals

    def initialize(irep)
      @source_list = irep.instructions
      @source_size = Array(@source_list).length
      @nlocals = irep.nlocals&.to_i
      @catch_handlers = Array(irep.catch_handlers).freeze
      @instructions = Array(irep.instructions).each_with_index.map do |source, index|
        Instruction.new(index: index, source: source, successors: [])
      end
      @address_to_index = @instructions.to_h { |instruction| [instruction.addr, instruction.index] }
      build_edges
      build_blocks
    end

    def instruction_at(index)
      @instructions[index]
    end

    # True while +irep+ still has the instruction list (the same Array, the same length) this Program was built from.
    # The bytecode never changes after loading, so a cached Program that fails this is a broken cache.
    def built_from?(irep)
      @source_list.equal?(irep.instructions) && @source_size == Array(@source_list).length
    end

    # BYTECODE_IR_FACTS: the per-instruction successor lists, frozen, index-aligned with #instructions:
    # normal flow, which already carries OP_ENTER's edges into its optional-argument JMP table (#build_edges).
    # Analyses that walk the graph share this one Array instead of rebuilding it.
    def successor_lists
      @successor_lists ||= @instructions.map(&:successors).freeze
    end

    # BYTECODE_IR_FACTS: every instruction decoded once (see BytecodeIR.decode), frozen and index-aligned.
    def decoded
      @decoded ||= @instructions.map do |instruction|
        BytecodeIR.decode(instruction.source, @address_to_index).freeze
      end.freeze
    end

    # The one slot an analysis may use to keep a table it derives from this Program's facts: NumericFlow's
    # per-instruction Step table. Nothing else is cached here, and nothing an oracle
    # answers ever is.
    attr_accessor :numeric_flow_table

    # The decoded Insn at +addr+, or nil when no instruction starts there.
    def insn_at_addr(addr)
      index = @address_to_index[addr]
      index && @instructions[index].source
    end

    # False when some branch targets an address that is not an instruction, so
    # the edge set is incomplete and no analysis may rely on it.
    def resolved?
      @resolved
    end

    # index -> Set of predecessor indices, with ENTRY for instruction 0's
    # method-entry edge. Nil when #resolved? is false. +include_handlers+ adds
    # the catch-handler edges (see #handler_edges) and is nil unless
    # #handlers_resolved? too.
    def instruction_predecessors(include_handlers: false)
      return nil unless @resolved
      return nil if include_handlers && !handlers_resolved?

      @instruction_predecessors ||= {}
      @instruction_predecessors[include_handlers] ||= begin
        preds = Array.new(@instructions.length) { Set.new }
        preds[0] << ENTRY unless preds.empty?
        @instructions.each do |instruction|
          instruction.successors.each { |successor| preds[successor] << instruction.index }
        end
        handler_edges.each { |edge| preds[edge.target] << edge.src } if include_handlers
        preds.each(&:freeze).freeze
      end
    end

    # [source, target] instruction-index pairs of the given jump ops located
    # before +limit+, or nil when a jump's target address is not an instruction.
    # A JMPUW named in +ops+ is an edge too (branch_target): jump_target would
    # be nil for it and read as an unresolved jump.
    def jump_edges_before(limit, ops)
      edges = []
      @instructions.each do |instruction|
        break if instruction.index >= limit
        next unless ops.include?(instruction.op)

        target = @address_to_index[instruction.source.branch_target]
        return nil unless target

        edges << [instruction.index, target]
      end
      edges
    end

    # Every explicit branch (JMP/JMPIF/JMPNOT/JMPNIL, plus JMPUW unless
    # +jmpuw+ is false) in instruction order. Address-based, so unlike the
    # index edges it stays meaningful when #resolved? is false.
    def branch_edges(jmpuw: true)
      @branch_edges ||= {}
      @branch_edges[jmpuw] ||= @instructions.filter_map do |instruction|
        target = jmpuw ? instruction.source.branch_target : instruction.source.jump_target
        BranchEdge.new(src: instruction.addr, target: target).freeze if target
      end.freeze
    end

    # Addresses named by any explicit branch, i.e. where a `goto` label is needed.
    def branch_targets
      @branch_targets ||= @instructions.filter_map { |instruction| instruction.source.branch_target }.to_set.freeze
    end

    # Branches that would break a single-entry, single-exit region whose
    # protected instructions are the addresses of +body+ and whose one
    # sanctioned exit is +exit_addr+ (so the region's addresses are
    # body.begin..exit_addr). A branch from inside +body+ must land inside the
    # region; a branch from outside must not land inside it, except one from
    # strictly before the region that lands on its first address.
    def region_boundary_breaches(body, exit_addr)
      region = (body.begin..exit_addr)
      branch_edges.select do |edge|
        if body.cover?(edge.src)
          !region.cover?(edge.target)
        elsif edge.src < region.begin && edge.target == region.begin
          false
        else
          region.cover?(edge.target)
        end
      end
    end

    # Explicit branches (JMPUW included) from an address in +from+ whose target is
    # not in +into+.
    def branches_escaping(from, into)
      branch_edges.select { |edge| from.cover?(edge.src) && !into.cover?(edge.target) }
    end

    # Explicit branches (JMPUW included) landing exactly on +addr+, minus those
    # whose source is in +except_from+.
    def branches_onto(addr, except_from: nil)
      branch_edges.select { |edge| edge.target == addr && !except_from&.cover?(edge.src) }
    end

    # Explicit branches (JMPUW included) with exactly one end in +range+, minus
    # those whose source is in +except_from+.
    def region_crossings(range, except_from: nil)
      branch_edges.select do |edge|
        !except_from&.cover?(edge.src) && range.cover?(edge.src) != range.cover?(edge.target)
      end
    end

    private

    def build_edges
      @resolved = true
      @instructions.each do |instruction|
        targets = []
        target_addr = instruction.source.branch_target
        if target_addr
          target = @address_to_index[target_addr]
          target ? targets << target : @resolved = false
        end
        next_index = instruction.index + 1
        targets << next_index if next_index < @instructions.length && !NO_FALLTHROUGH.include?(instruction.op)
        # OP_ENTER lands on one of the `o + 1` JMP table entries that follow it (vm.c
        # `ci->pc += o*3` and its argc form), so each entry has ENTER as a predecessor.
        if instruction.op == 'ENTER'
          optional = instruction.source.enter_fields[1].to_i
          (1..optional).each do |k|
            table = instruction.index + 1 + k
            targets << table if table < @instructions.length
          end
        end
        instruction.successors = targets.uniq.freeze
      end
    end

    def build_blocks
      if @instructions.empty?
        @blocks = [].freeze
        return
      end

      leaders = [0]
      @instructions.each do |instruction|
        next unless TERMINATORS.include?(instruction.op)

        instruction.successors.each do |successor|
          leaders << successor
        end
        if CONDITIONAL_BRANCHES.include?(instruction.op) && instruction.index + 1 < @instructions.length
          leaders << instruction.index + 1
        end
      end
      leaders = leaders.uniq.sort
      ranges = leaders.each_with_index.map do |start, i|
        [start, (leaders[i + 1] || @instructions.length) - 1]
      end
      owner = {}
      @blocks = ranges.each_with_index.map do |(first, last), id|
        members = (first..last).to_a
        members.each { |index| owner[index] = id }
        BasicBlock.new(id: id, instructions: members.freeze, successors: [], predecessors: [])
      end
      @blocks.each do |block|
        terminal = @instructions[block.instructions.last]
        block.successors = terminal.successors.filter_map { |index| owner[index] }.uniq.freeze
      end
      @blocks.each do |block|
        block.successors.each { |successor| @blocks[successor].predecessors << block.id }
      end
      @blocks.each { |block| block.predecessors.freeze }
      @blocks.freeze
    end
  end

  def self.for(irep)
    cached = irep.instance_variable_get(:@bytecode_ir)
    return cached if cached

    irep.instance_variable_set(:@bytecode_ir, Program.new(irep))
  end
end

require_relative 'bytecode_ir_handlers'
require_relative 'bytecode_ir_dataflow'
require_relative 'bytecode_ir_types'
require_relative 'bytecode_ir_classes'
require_relative 'bytecode_ir_windows'
require_relative 'bytecode_ir_tree'
require_relative 'bytecode_ir_operands'
require_relative 'bytecode_ir_constant_path'

# frozen_string_literal: true

# Shadow decision procedure for the exception-flow barriers of the Fixnum proof
# and return analysis (ctx[:catch_targets], ctx[:protected]), derived from
# BytecodeIR handler edges. See ADR 0250 addendum "Barrier shadow".
#
# Preload with `ruby -r fixnum_barrier_shadow bc2cpp.rb ...`: it prepends
# hooks onto CodeGen that re-run every barrier consumer with the shadow sets
# swapped into the memoized ctx and records old-vs-new answers.
#
# Env: BC2CPP_BARRIER_SHADOW_REPORT=<path> writes the report at exit.

require 'set'

module FixnumBarrierShadow
  # Addresses of instructions some handler resumes at: the targets of its
  # edges. A handler whose range holds no instruction has no edge.
  def self.catch_target_addrs(program)
    program.handler_edges.to_set { |edge| program.instructions[edge.target].addr }
  end

  # Instructions that may raise into a handler (edge sources) plus the one
  # instruction at each range's end address, which the old barrier also
  # refuses (its inclusive end). The second half is not an edge fact: it is
  # the explicit "after a protected range" rule.
  def self.protected_addrs(program)
    addrs = program.handler_edges.to_set { |edge| program.instructions[edge.src].addr }
    ends = program.catch_handlers.to_set(&:end_addr)
    program.instructions.each { |insn| addrs << insn.addr if ends.include?(insn.addr) }
    addrs
  end

  # State shared by the hooks and the report.
  class Recorder
    attr_reader :queries, :diffs, :set_diffs

    def initialize
      @queries = Hash.new(0)
      @diffs = []
      @set_diffs = []
      @ctx_seen = Set.new
    end

    def check_sets(label, program, real_ctx, shadow)
      return unless @ctx_seen.add?(label)

      { catch_targets: shadow[:catch_targets], protected: shadow[:protected] }.each do |kind, new_set|
        old_set = real_ctx[kind]
        # Only instruction addresses matter: every consumer asks include?(insn.addr).
        insn_addrs = program.instructions.to_set(&:addr)
        (old_set & insn_addrs).each { |a| @set_diffs << [label, kind, a, :old_only] unless new_set.include?(a) }
        (new_set & insn_addrs).each { |a| @set_diffs << [label, kind, a, :new_only] unless old_set.include?(a) }
      end
    end

    def record(method, label, idx, reg, old, new)
      @queries[method] += 1
      return if old == new

      @diffs << [method, label, idx, reg, old, new]
    end

    def report
      out = +"barrier shadow report\n"
      out << "irep contexts compared: #{@ctx_seen.size}\n"
      out << "context set differences: #{@set_diffs.size}\n"
      @set_diffs.first(20).each { |d| out << "  #{d.inspect}\n" }
      out << "queries: #{@queries.values.sum}\n"
      @queries.sort.each { |m, n| out << "  #{m}: #{n}\n" }
      out << "query differences: #{@diffs.size}\n"
      @diffs.first(40).each { |d| out << "  #{d.inspect}\n" }
      out
    end
  end

  RECORDER = Recorder.new

  # Prepended onto CodeGen (defined here, before the codegen files load).
  module Hooks
    def fixnum_proof_ctx(irep)
      real = super
      return real if real.nil? || @fixnum_barrier_shadow_active

      @fixnum_barrier_shadow_ctxs ||= {}
      shadow = (@fixnum_barrier_shadow_ctxs[irep.label] ||= real.merge(
        catch_targets: FixnumBarrierShadow.catch_target_addrs(BytecodeIR.for(irep)),
        protected: FixnumBarrierShadow.protected_addrs(BytecodeIR.for(irep))
      ))
      RECORDER.check_sets(irep.label, BytecodeIR.for(irep), real, shadow)
      real
    end

    def fixnum_proof_region_ok?(irep, ctx, w_idx, u_idx)
      shadow_query(:region_ok, irep, u_idx, w_idx, super) do
        super(irep, @fixnum_barrier_shadow_ctxs[irep.label], w_idx, u_idx)
      end
    end

    def fixnum_proof_reaching_defs?(irep, ctx, need_idx, reg, owner_def, depth)
      shadow_query(:reaching_defs, irep, need_idx, reg, super) do
        super(irep, @fixnum_barrier_shadow_ctxs[irep.label], need_idx, reg, owner_def, depth)
      end
    end

    def proven_fixnum_operand?(irep, idx, reg, owner_def, depth = 0)
      shadow_query(:proven_fixnum_operand, irep, idx, reg, super) do
        super(irep, idx, reg, owner_def, depth)
      end
    end

    def guarded_game_integer_range(irep, idx, reg, owner_def, depth = 0)
      shadow_query(:game_integer_range, irep, idx, reg, super) do
        super(irep, idx, reg, owner_def, depth)
      end
    end

    def return_value_sources(irep, idx, reg)
      shadow_query(:return_value_sources, irep, idx, reg, super) do
        super(irep, idx, reg)
      end
    end

    def return_write_dominates?(irep, w_idx, use_idx, reg)
      shadow_query(:return_write_dominates, irep, use_idx, reg, super) do
        super(irep, w_idx, use_idx, reg)
      end
    end

    private

    # Runs the block (the same query) with the shadow ctx installed as the
    # memoized one, so nested consumers see the shadow barriers too.
    def shadow_query(method, irep, idx, reg, old)
      return old if @fixnum_barrier_shadow_active || irep.nil?

      fixnum_proof_ctx(irep)
      key = irep.label
      real_ctx = @fixnum_proof_ctx[key]
      @fixnum_barrier_shadow_active = true
      @fixnum_proof_ctx[key] = @fixnum_barrier_shadow_ctxs[key]
      begin
        new = yield
      ensure
        @fixnum_proof_ctx[key] = real_ctx
        @fixnum_barrier_shadow_active = false
      end
      RECORDER.record(method, key, idx, reg, old, new)
      old
    end
  end

  def self.report_path
    ENV['BC2CPP_BARRIER_SHADOW_REPORT']
  end
end

class CodeGen
  prepend FixnumBarrierShadow::Hooks
end

at_exit do
  path = FixnumBarrierShadow.report_path
  File.write("#{path}.#{Process.pid}", FixnumBarrierShadow::RECORDER.report) if path
end

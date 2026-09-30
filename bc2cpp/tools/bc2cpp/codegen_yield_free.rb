# frozen_string_literal: true

require_relative 'yield_reach'

# CodeGen: the yield-free proof (ADR 0283). YieldReach answers, per irep, whether anything above
# its compiled frame can suspend the current Fiber; the queries below turn that into the facts the
# emitters need.
class CodeGen
  attr_reader :yield_reach

  # The analysis is a pure function of the ireps and the closed world, and the driver builds
  # several CodeGens over the same ones.
  YIELD_REACH_MEMO = {}.compare_by_identity

  def build_yield_reach
    key = @closed_world || @ireps
    memo = (YIELD_REACH_MEMO[@ireps] ||= {}.compare_by_identity)
    memo[key] ||= begin
      cw = @closed_world
      sound = !cw.nil? && cw.global_refusal.nil?
      native = @registry.values.flatten.select { |d| d.owner == '<native>' }.to_set(&:name)
      native.merge(cw.outside_names) if cw
      if (dump = ENV['BC2CPP_YIELD_DUMP'])
        opaque = cw&.outside_call_names(@ireps.values.to_set(&:file))
        File.binwrite(dump, Marshal.dump([@ireps, sound, opaque, native]))
      end
      YieldReach.new(ireps: @ireps, sound: sound, opaque_names: cw&.outside_call_names(@ireps.values.to_set(&:file)), native_names: native)
    end
  end

  # YIELD_REACH facts the emitters ask for. A world that is not closed proves nothing.
  def yield_free_block?(block_irep)
    !!@yield_reach&.yield_free?(block_irep.label)
  end

  # Records a direct-entry block and whether it was proved yield-free; returns the proof.
  def note_block_yield_free(block_irep)
    free = yield_free_block?(block_irep)
    (@yf_blocks ||= {})[block_irep.label] = free
    free
  end

  # The body of this core method, given a yield-free block, cannot suspend a Fiber (its frame is safe
  # under any Fiber as long as the block it runs is).
  def core_body_relaxable?(label)
    !!@yield_reach&.body_yield_free?(label)
  end

  # Build-time table for the diagnostic (bc2cpp.rb): methods and blocks proved yield-free among
  # what the build compiled, and the block-core-direct arm sites whose block is yield-free.
  def yield_free_report(compiled_labels)
    reach = @yield_reach
    labels = compiled_labels.to_set
    methods = labels.select { |l| reach.nodes[l]&.kind == :method }
    blocks = (@yf_blocks || {}).select { |l, _| labels.include?(reach.nodes[l]&.owner) }
    arms = (@yf_arm_sites || {}).select { |(parent, _, _), _| labels.include?(reach.nodes[parent]&.owner) }
    { sound: reach.sound?, seal: reach.stats[:sealed],
      methods: methods.size, methods_free: methods.count { |l| reach.yield_free?(l) },
      methods_body_free: methods.count { |l| reach.body_yield_free?(l) },
      blocks: blocks.size, blocks_free: blocks.values.count(true),
      arm_sites: arms.size, arm_sites_free: arms.values.count { |v| v[:block_free] },
      arms: arms.values.sum { |v| v[:arms].size }, arms_unguarded: arms.values.sum { |v| v[:unguarded].size },
      guarded_core: (self.class.core_guarded || []).size,
      guarded_core_relaxable: (self.class.core_guarded || []).count { |l| core_body_relaxable?(l) },
      unsafe_methods: @fiber_unsafe_methods.size }
  end
end

#!/usr/bin/env ruby
# frozen_string_literal: true

# UPVAR_WALKS (BytecodeIR.each_nested_insn): the nested-block upvar walks (own_upvar_written_regs, RegisterFlow's
# captured_registers, CodeGen#block_upvar_needs, CodeGen#upvar_refs_into) share one walker. This fixture pins what
# each answers for a nested snippet, and for a chain deeper than MAX_UPVAR_NEST_DEPTH. It only calls APIs that exist
# before and after the change, so it also runs against the baseline tree:
#   BC2CPP_TOOLS_DIR=/path/to/baseline/tools/bc2cpp MRBC=... ruby scripts/bc2cpp/upvar_walks_check.rb
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/upvar_walks_check.rb

require_relative 'check_support'
require 'set'

suite = FixtureCheck.new('upvar_walks_check')
suite.require_mrbc!

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''
TOOLS = ENV['BC2CPP_TOOLS_DIR'] || File.expand_path('../../tools/bc2cpp', __dir__)
require File.join(TOOLS, 'bc2cpp')

check = suite.method(:check)

# Locals of the snippet's top frame, as mrbc numbers them: x=R1, y=R2, z=R3 (the blocks name no register of their own).
SNIPPET = <<~RUBY
  x = 1
  y = 2
  z = 5
  [1].each do
    x = 3
    q = z
    [2].each do
      y = x
    end
  end
RUBY

# A chain of +n+ blocks; the innermost sits +n - 1+ blocks below the outermost.
def chain_source(n)
  "x = 1\n#{"[1].each do\n" * n}x = 2\n#{"end\n" * n}"
end

# Compile +source+; yields [ireps, gen] (the irep table and a CodeGen over it).
with_ireps = lambda do |source, &block|
  suite.compile(source) do |ireps, top|
    registry = build_registry(ireps, top)[0]
    block.call(ireps, top, CodeGen.new(ireps, registry, {}))
  end
end

# upvar_refs_into takes (irep) on the new tree and (irep, level) on the baseline.
refs_into = lambda do |gen, child|
  gen.method(:upvar_refs_into).arity == 1 ? gen.send(:upvar_refs_into, child) : gen.send(:upvar_refs_into, child, 0)
end

with_ireps.call(SNIPPET) do |ireps, top_label, gen|
  top = ireps[top_label]
  block1 = ireps[top.reps[0]]
  block2 = ireps[block1.reps[0]]

  puts '-- nested snippet'
  check.call('the top frame: only the nested blocks write x and y (R1, R2), not the read-only z',
             BytecodeIR.own_upvar_written_regs(top).to_a.sort == %w[1 2])
  check.call('the top frame: every register a nested block touches, reads included (x, y, z)',
             RegisterFlow.captured_registers(top).map(&:to_s).sort == %w[1 2 3])
  check.call('block1 needs x and y at level 0 and z at level 0 (block2 needs x, y one level up)',
             gen.send(:block_upvar_needs, block1) == [[0, 1], [0, 2], [0, 3]])
  check.call('block2 needs x and y at level 1 (its own references, relative to itself)',
             gen.send(:block_upvar_needs, block2) == [[1, 1], [1, 2]])
  check.call('the top frame needs nothing from above it: every reference of its blocks lands in its own frame',
             gen.send(:block_upvar_needs, top) == [])
  if ENV['BC2CPP_BLOCK_CAPTURE_INDEX'] != '0'
    index = gen.instance_variable_get(:@block_capture_index)
    first = gen.block_upvar_needs(block1)
    check.call('capture snapshots are shared and deeply immutable',
               first.equal?(gen.block_upvar_needs(block1)) && first.frozen? && first.all?(&:frozen?))
    gen.without_probe_side_effects { gen.block_upvar_needs(block2) }
    check.call('only structural capture snapshots survive probe rollback',
               gen.instance_variable_get(:@block_capture_index).equal?(index) && first.equal?(gen.block_upvar_needs(block1)))
    [block1, block2, top].each do |body|
      indexed = gen.block_upvar_needs(body)
      gen.instance_variable_set(:@block_capture_index, nil)
      check.call('indexed captures match a fresh bounded walk', indexed == gen.block_upvar_needs(body))
      gen.instance_variable_set(:@block_capture_index, index)
    end
  end
  all, written = refs_into.call(gen, block1)
  check.call('upvar_refs_into(block1): block1 and block2 reference the top frame (x, y, z); written x, y',
             all.to_a.sort == %w[1 2 3] && written.to_a.sort == %w[1 2])
  all, written = refs_into.call(gen, block2)
  check.call("upvar_refs_into(block2): it touches no register of block1, its parent (block2's refs go past it)",
             all.empty? && written.empty?)
end

with_ireps.call("def capture_block; [1].each { block_given? }; end") do |ireps, _top, gen|
  body = ireps.values.find { |irep| gen.calls_block_given?(irep) }
  index = BlockCaptureIndex.new(ireps, CodeGen::MAX_UPVAR_NEST_DEPTH, CodeGen::BLOCK_GIVEN_NAMES)
  # Query deeper positions first to catch sparse depth-index mistakes.
  [2, 0, 1, 16, 17].each do |depth|
    [true, false].each do |given|
      indexed = index.block_levels(body, depth, given: given)
      saved = gen.instance_variable_get(:@block_capture_index)
      gen.instance_variable_set(:@block_capture_index, nil)
      original = gen.block_blk_needs(body, depth, given: given)
      gen.instance_variable_set(:@block_capture_index, saved)
      check.call("block needs preserve depth #{depth} and given #{given}", indexed == original)
      check.call('block-level snapshots are immutable', indexed.nil? || indexed.frozen?)
    end
  end
  check.call('block_given modeling modes remain separate', index.block_levels(body, given: true) != index.block_levels(body, given: false))
  registry = gen.instance_variable_get(:@registry)
  registry['block_given?'] << Struct.new(:irep).new('ruby-override')
  check.call('a Ruby block_given? override withdraws modeled reads',
             gen.block_blk_needs(body) == index.block_levels(body, given: false))
end

with_ireps.call(<<~RUBY) do |ireps, _top, gen|
  class CaptureCompile
    def initialize; @count = 1; end
    def walk(value)
      [1].each { [2].each { value += @count; yield if block_given? } }
      value
    end
  end
RUBY
  state_keys = CodeGen::METHOD_COMPILE_STATE.keys
  original = state_keys.map { |ivar| gen.instance_variable_get(ivar) }
  sentinels = state_keys.map { Object.new }
  state_keys.zip(sentinels).each { |ivar, value| gen.instance_variable_set(ivar, value) }
  begin
    begin
      gen.with_fresh_method_state do
        check.call('probe starts with every method-state default',
                   CodeGen::METHOD_COMPILE_STATE.all? { |ivar, value| gen.instance_variable_get(ivar) == value })
        gen.instance_variable_set(:@ir_inline_remaining, 17)
        gen.with_fresh_method_state { gen.instance_variable_set(:@ir_inline_remaining, 3) }
        check.call('nested probe restores its immediate caller', gen.instance_variable_get(:@ir_inline_remaining) == 17)
        raise RuntimeError, 'probe restoration test'
      end
    rescue RuntimeError => error
      raise unless error.message == 'probe restoration test'
    end
    check.call('exception restores all caller state objects',
               state_keys.each_with_index.all? { |ivar, index| gen.instance_variable_get(ivar).equal?(sentinels[index]) })
  ensure
    state_keys.zip(original).each { |ivar, value| gen.instance_variable_set(ivar, value) }
  end
  registry = gen.instance_variable_get(:@registry)
  baseline = CodeGen.new(ireps, registry, {})
  baseline.instance_variable_set(:@block_capture_index, nil)
  registry.values.flatten.each do |definition|
    next unless definition.irep

    check.call('capture indexing preserves real clean-probe decisions',
               gen.compiles_clean?(definition.irep) == baseline.compiles_clean?(definition.irep))
  end
  check.call('capture indexing preserves generated code after probes', gen.compile_all == baseline.compile_all)
end

# Probe-only text optimization must leave both eligibility and the eventual real emission unchanged.
with_ireps.call(<<~RUBY) do |ireps, _top, gen|
  class ProbeRegisterFlow
    def initialize; @count = 1; end
    def copy(value); unused = 2; copied = value; copied; end
    def nested(value); copy(value); end
    def dynamic; eval('1'); end
  end
RUBY
  registry = gen.instance_variable_get(:@registry)
  original_mode = ENV['BC2CPP_PROBE_REGISTER_FLOW']
  begin
    %i[ordinary error audit specialized].each do |scenario|
      results = %w[0 1].map do |mode|
        ENV['BC2CPP_PROBE_REGISTER_FLOW'] = mode
        candidate = CodeGen.new(ireps, registry, {})
        case scenario
        when :error
          candidate.singleton_class.prepend(Module.new do
            def compile_insn(insn, *rest)
              text = super
              insn.op == 'RETURN' ? "  r1 = /* #error probe sentinel */ 0;\n" + text : text
            end
          end)
        when :audit
          candidate.singleton_class.prepend(Module.new do
            def compile_insn(insn, *rest)
              text = super
              @runtime_installed_names = Set.new
              text
            end
          end)
        when :specialized
          candidate.define_singleton_method(:entry_specialize_enabled?) { true }
          candidate.define_singleton_method(:entry_specialize_plan) { {} }
        end
        calls = 0
        trace = TracePoint.new(:call) do |event|
          calls += 1 if event.defined_class == RegisterFlow.singleton_class && event.method_id == :optimize
        end
        answers = trace.enable do
          registry.values.flatten.filter_map { |definition| [definition.irep, candidate.compiles_clean?(definition.irep)] if definition.irep }
        end
        [answers, calls, candidate.compile_all]
      end
      check.call("probe text shortcut preserves clean decisions (#{scenario})", results[0][0] == results[1][0])
      check.call("probe text shortcut preserves final emitted code (#{scenario})", results[0][2] == results[1][2])
      check.call("probe text shortcut #{scenario == :ordinary ? 'avoids discarded passes' : "retains #{scenario} passes"}",
                 scenario == :ordinary ? results[1][1] < results[0][1] : results[0][1] == results[1][1])
    end
  ensure
    ENV['BC2CPP_PROBE_REGISTER_FLOW'] = original_mode
  end
end

puts '-- depth bound (MAX_UPVAR_NEST_DEPTH)'
[17, 18].each do |n|
  with_ireps.call(chain_source(n)) do |ireps, top_label, gen|
    outer = ireps[ireps[top_label].reps[0]]
    needs = gen.send(:block_upvar_needs, outer)
    if n == 17
      check.call("a chain of #{n} blocks (deepest at depth #{n - 1}) still has its needs", needs.is_a?(Array))
      check.call("a chain of #{n} blocks: the outer block needs the top x at level 0", needs&.include?([0, 1]))
    else
      check.call("a chain of #{n} blocks (deepest at depth #{n - 1}) exceeds the bound: no needs", needs.nil?)
    end
  end
end

suite.finish!

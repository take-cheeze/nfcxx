#!/usr/bin/env ruby
# frozen_string_literal: true

# UPVAR_WALKS (BytecodeIR.each_nested_insn): the nested-block upvar walks (own_upvar_written_regs, RegisterFlow's
# captured_registers, CodeGen#block_upvar_needs, CodeGen#upvar_refs_into) share one walker. This fixture pins what
# each answers for a nested snippet, and for a chain deeper than MAX_UPVAR_NEST_DEPTH. It only calls APIs that exist
# before and after the change, so it also runs against the baseline tree:
#   BC2CPP_TOOLS_DIR=/path/to/baseline/tools/bc2cpp MRBC=... ruby scripts/bc2cpp/upvar_walks_check.rb
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/upvar_walks_check.rb

require 'tmpdir'
require 'set'

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''
TOOLS = ENV['BC2CPP_TOOLS_DIR'] || File.expand_path('../../tools/bc2cpp', __dir__)
require File.join(TOOLS, 'bc2cpp')

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

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
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'upvar_walks.rb')
    File.write(path, source)
    ireps, top = compile_ireps(path, 'upvar_walks_fixture', dir)
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
  all, written = refs_into.call(gen, block1)
  check.call('upvar_refs_into(block1): block1 and block2 reference the top frame (x, y, z); written x, y',
             all.to_a.sort == %w[1 2 3] && written.to_a.sort == %w[1 2])
  all, written = refs_into.call(gen, block2)
  check.call("upvar_refs_into(block2): it touches no register of block1, its parent (block2's refs go past it)",
             all.empty? && written.empty?)
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

puts "upvar_walks_check: #{failures.size} failures"
exit(failures.empty? ? 0 : 1)

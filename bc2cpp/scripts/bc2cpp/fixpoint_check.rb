#!/usr/bin/env ruby
# frozen_string_literal: true

# Check FIXPOINT_BOUNDS: a bounded fixed point stops at the first round that
# changes nothing, and a round limit reached while rounds still change is an error naming the analysis and the loop,
# never a silently kept partial result. Also checks that the whole-program fixed points run under it. Seconds; needs
# no mruby build.

require_relative '../../tools/bc2cpp/fixpoint'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

rounds = 0
Fixpoint.iterate('converging', 5) { (rounds += 1) < 3 }
check.call('a converging loop runs until a round changes nothing', rounds == 3)
rounds = 0
Fixpoint.iterate('exactly at the limit', 3) { (rounds += 1) < 3 }
check.call('a loop that settles on its last allowed round is accepted', rounds == 3)
rounds = 0
error = begin
  Fixpoint.iterate('SomeAnalysis', 4) do
    rounds += 1
    true
  end
  nil
rescue Fixpoint::NotConverged => e
  e
end
check.call('a loop still changing at the limit raises', error && rounds == 4)
check.call('the error names the analysis, the limit and the loop',
           error && error.message.include?('SomeAnalysis') && error.message.include?('4 rounds') &&
             error.message.include?("#{File.basename(__FILE__)}:"))
check.call('the limits are constants, not environment switches',
           Fixpoint::SWEEP_LIMIT.is_a?(Integer) && Fixpoint::GROWTH_LIMIT.is_a?(Integer) &&
             !File.read(File.expand_path('../../tools/bc2cpp/fixpoint.rb', __dir__)).include?('ENV'))

tools = File.expand_path('../../tools/bc2cpp', __dir__)
{
  'class_layout.rb' => ['ClassLayout.analyze'],
  'ivar_layout.rb' => ['IvarLayout.analyze'],
  'element_layouts.rb' => ['ArrayElementLayout.analyze', 'HashElementLayout.analyze'],
  'codegen_numeric_proof.rb' => ['CodeGen numeric facts'],
  'codegen_return_classes.rb' => ['CodeGen return classes and class pools']
}.each do |file, analyses|
  text = File.read(File.join(tools, file), encoding: 'UTF-8')
  check.call("#{file}: #{analyses.join(', ')} run under Fixpoint.iterate",
             analyses.all? { |name| text.include?("Fixpoint.iterate('#{name}") } && !text.match?(/^\s+10\.times do$/))
end

if failures.empty?
  puts 'bc2cpp fixpoint check: PASS'
else
  warn "bc2cpp fixpoint check: #{failures.size} failure(s)"
  exit 1
end

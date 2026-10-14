#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'

check = lambda do |message, condition|
  raise message unless condition

  puts "ok #{message}"
end

instruction = ->(index, op, args) { Insn.new(lineno: 1, addr: index * 4, op: op, args: args, raw: "#{op} #{args}") }
body = Irep.new(label: 'typed_block', nlocals: 2, nregs: 4, instructions: [
  instruction.call(0, 'ENTER', '1:0:0:0:0:0:0:0 (0x0)'), instruction.call(1, 'MOVE', 'R2 R1'), instruction.call(2, 'RETURN', 'R2')])
bound = BytecodeIR::Types::Fact.new(classes: Set[:String], declared: true, contracts: ['rbs-block:Owner#callback'])
analysis = BytecodeIR::Types.new(body, argument_facts: { '1' => bound })
check.call('seeded callback arguments retain declaration provenance', analysis.fact_at(2, '2')&.contracts == bound.contracts)
check.call('declared callback arguments cannot become independent classes', analysis.at(2, '2').nil?)
body.instructions[1] = instruction.call(1, 'GETUPVAR', 'R2 1 0')
capture_analysis = BytecodeIR::Types.new(body, source_resolver: ->(_index, _reg) { bound })
check.call('source Fact callbacks preserve capture declarations', capture_analysis.fact_at(2, '2')&.declared?)
check.call('declared source Facts cannot become independent classes', capture_analysis.at(2, '2').nil?)

unless ENV['MRBC']
  puts 'SKIP mrbc block protocol integration fixtures (set MRBC)'
  exit
end

root = File.expand_path('../..', __dir__)
Dir.mktmpdir('ir-block-protocols') do |dir|
  File.write(File.join(dir, 'fixture.rb'), <<~RUBY)
    class BlockProtocols
      def twice(value); yield value; yield 1; end
      def custom; twice(:tag) { |item| item }; end
      def once(value); yield value; end
      def stable_custom; local = 'captured'; once(1) { |item| local }; end
      def generic_walk(values); yield values[0]; end
      def generic_caller(values); generic_walk(values) { |item| item }; end
      def generic_literal(values); generic_walk(values) { |item| 1 }; end
      def stable(values); local = 3; once(1) { |item| local }; end
      def declared_capture(values, label); once(1) { |item| label }; end
      def iterator_capture(values); local = 3; values.map { |item| local }; end
      def written(values); local = 3; values.map { |item| local = :changed; local }; end
      def opaque_capture(values); local = 3; generic_walk(values) { |item| local }; end
      def numeric_callback; yield; end
      def numeric_caller; numeric_callback { 1 }; end
      def wrong_callback; yield; end
      def wrong_caller; wrong_callback { 1 }; end
    end
  RUBY
  File.write(File.join(dir, 'fixture.rbs'), <<~RBS)
    class BlockProtocols
      def generic_walk: [T, U] (Array[T] values) { (T) -> U } -> Array[U]
      def generic_caller: (Array[String | nil] values) -> untyped
      def generic_literal: (Array[String] values) -> untyped
      def stable: (Array[String] values) -> untyped
      def iterator_capture: (Array[String] values) -> untyped
      def declared_capture: (Array[String] values, Symbol label) -> untyped
      def written: (Array[String] values) -> untyped
      def opaque_capture: (Array[String] values) -> untyped
      def numeric_callback: () { () -> Numeric } -> Numeric
      def wrong_callback: () { () -> String } -> String
    end
  RBS
  run = lambda do |extra = {}|
    env = { 'MRBC' => File.expand_path(ENV.fetch('MRBC')), 'BC2CPP_STRICT_HINTS' => '0', 'BC2CPP_SIG_DIRS' => '' }.merge(extra)
    output, error, status = Open3.capture3(env, RbConfig.ruby, File.join(root, 'scripts/bc2cpp/type_check.rb'),
                                         '--files', 'fixture.rb', '--sig', 'fixture.rbs', '--format', 'json', '--no-sends', chdir: dir)
    raise "block protocol check failed: #{error}\n#{output}" unless [0, 1].include?(status.exitstatus)

    JSON.parse(output)
  end
  report = run.call
  row = ->(method, kind) { report['ir_feedback'].find { |item| item['method'] == method && item['kind'] == kind } }
  check.call('custom yield sites join independently proven argument classes',
             row.call('custom', 'block_argument')['type'].split(' | ').sort == %w[Integer Symbol] && row.call('custom', 'block_argument')['status'] == 'inferred')
  check.call('custom yield argument facts propagate through the literal block body', row.call('custom', 'block_return')['status'] == 'inferred')
  check.call('stable immediate captures preserve independent String facts', row.call('stable_custom', 'block_return')['type'] == 'String' && row.call('stable_custom', 'block_return')['status'] == 'inferred')
  check.call('generic RBS callback parameters substitute the nullable element union', row.call('generic_caller', 'block_argument')['type'] == 'String | nil')
  check.call('generic callback output substitutes into its container contract', row.call('generic_literal', 'callback_result')['type'] == 'Array[Integer]')
  check.call('pure custom yield captures retain independently proven Integer facts', row.call('stable', 'block_return')['type'] == 'Integer' && row.call('stable', 'block_return')['status'] == 'inferred')
  check.call('nominal iterator contracts alone cannot prove capture lifetime', row.call('iterator_capture', 'block_return')['status'] == 'unknown')
  check.call('declared captures retain their argument contract provenance',
             row.call('declared_capture', 'block_return')['type'] == 'Symbol' && row.call('declared_capture', 'block_return')['status'] == 'declared' && row.call('declared_capture', 'block_return')['contracts'].include?('argument:R2'))
  check.call('capture writes prevent a stale independent Integer fact', row.call('written', 'block_return')['type'] != 'Integer')
  check.call('an RBS callback contract alone cannot prove capture lifetime', row.call('opaque_capture', 'block_return')['status'] == 'unknown')
  check.call('Integer callback returns satisfy Numeric through the known hierarchy', row.call('numeric_caller', 'block_contract')['status'] == 'inferred')
  check.call('independent callback result contradictions produce TC1007', report['diagnostics'].any? { |diagnostic| diagnostic['code'] == 'TC1007' })

  without = run.call('BC2CPP_IR_BLOCK_TYPES' => '0')
  check.call('the block opt-out withdraws all block and callback rows', without['ir_feedback'].none? { |item| item['kind'].start_with?('block_') || %w[callback_result iterator_result].include?(item['kind']) })
  without_captures = run.call('BC2CPP_IR_BLOCK_CAPTURES' => '0')['ir_feedback'].find { |item| item['method'] == 'stable' && item['kind'] == 'block_return' }
  check.call('the capture opt-out restores the unknown captured result', without_captures['status'] == 'unknown')
end
puts 'block protocol integration checks passed'

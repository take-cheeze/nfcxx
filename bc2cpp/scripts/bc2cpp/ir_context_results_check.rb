#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'type_check_fixture'
require_relative '../../tools/bc2cpp/ir_native_expression_types'

check = lambda do |message, condition|
  raise message unless condition

  puts "ok #{message}"
end
check.call('whole native bool constructor is typed', IrNativeExpressionTypes.classes('mrb_bool_value(mrb_test(recv))', 'Array') == [:TrueClass, :FalseClass])
check.call('ternary after a bool constructor is not a bool proof', IrNativeExpressionTypes.classes('mrb_bool_value(x) ? mrb_nil_value() : recv', 'Array').nil?)
check.call('opaque native expression remains unknown', IrNativeExpressionTypes.classes('custom(M, recv)', 'Array').nil?)
check.call('native receiver return retains its actual class', IrNativeExpressionTypes.classes('recv', 'Array') == [:Array])
check.call('native constructor parser handles parentheses in quotes', IrNativeExpressionTypes.classes('mrb_bool_value(strcmp("(", ")"))', 'Array') == [:TrueClass, :FalseClass])

unless ENV['MRBC']
  puts 'SKIP mrbc context fixtures (set MRBC)'
  exit
end

Dir.mktmpdir('ir-context-results') do |dir|
  source = <<~RUBY
    class ContextCases
      def identity(value); value; end
      def peer(value); identity(value); end
      def optional(value = 1); value; end
      def required_kw(x:); x; end
      def optional_kw(x: :default); x; end
      def recursive(n, value); n == 0 ? value : recursive(n - 1, value); end
      def mutual_a(n, value); n == 0 ? value : mutual_b(n - 1, value); end
      def mutual_b(n, value); mutual_a(n, value); end
      def never(value); never(value); end
      def array(value); [value].freeze; end
      def build_hash(value); { answer: value }.freeze; end
      def pure_a(value); pure_b(value); end
      def pure_b(value); value; end
      def opaque_writer(value); @state = value; end
      def effect_read; @state = :held; pure_a(1); @state; end
      def effect_write; @state = :held; opaque_writer('changed'); @state; end
      def call_int; identity(1); end
      def call_symbol; identity(:tag); end
      def call_peer; peer('text'); end
      def call_default; optional; end
      def call_given; optional(:tag); end
      def call_kw; required_kw(x: 'value'); end
      def call_kw_default; optional_kw; end
      def call_kw_given; optional_kw(x: 3); end
      def call_recursive; recursive(3, 'value'); end
      def call_mutual; mutual_a(3, :tag); end
      def call_never; never(1); end
      def call_array; array('element')[0]; end
      def call_hash; build_hash(1)[:answer]; end
      def call_absent; array('element')[8]; end
      def call_native; [].empty?; end
      def call_dynamic(other); other.identity(1); end
      def literal_array; []; end
      def later_element(other); other[0]; end
    end
    class OtherContext
      def identity(value); value.unknown_result; end
    end
  RUBY
  File.write(File.join(dir, 'fixture.rb'), source)
  run = lambda do |extra_env = {}|
    env = { 'BC2CPP_SIG_DIRS' => '', 'BC2CPP_STRICT_HINTS' => '0' }.merge(extra_env)
    TypeCheckFixture.report(dir, env: env, label: 'context fixture')
  end
  report = run.call
  check.call('leaf evaluation reuse preserves the complete report', report == run.call('BC2CPP_IR_LEAF_EVALUATIONS' => '0'))
  check.call('call index preserves the complete report', report == run.call('BC2CPP_IR_CALL_INDEX' => '0'))
  returns = report['ir_feedback'].select { |row| row['kind'] == 'return' }.to_h { |row| [[row['owner'], row['method']], row] }
  expected = { 'call_int' => ['Integer'], 'call_symbol' => ['Symbol'], 'call_peer' => ['String'],
               'call_default' => ['Integer'], 'call_given' => ['Symbol'], 'call_kw' => ['String'],
               'call_kw_default' => ['Symbol'], 'call_kw_given' => ['Integer'],
               'call_recursive' => ['String'], 'call_mutual' => ['Symbol'], 'call_array' => ['String'],
               'call_hash' => %w[Integer nil], 'call_absent' => ['nil'], 'effect_read' => ['Symbol'], 'call_native' => ['bool'] }
  expected.each do |name, types|
    row = returns[['ContextCases', name]]
    check.call("independent #{name}: #{row.inspect}", row['status'] == 'inferred' && row['type'].split(' | ').sort == types.sort)
  end
  check.call('a recursive component with no return stays unknown', returns[['ContextCases', 'call_never']]['status'] == 'unknown')
  check.call('an unknown explicit receiver does not inherit lexical self target', returns[['ContextCases', 'call_dynamic']]['status'] == 'unknown')
  check.call('a mutable array parameter gains no frozen element shape', returns[['ContextCases', 'later_element']]['status'] == 'unknown')
  check.call('an actual writer does not preserve the previous Symbol-only field', returns[['ContextCases', 'effect_write']]['type'] != 'Symbol')
  check.call('native inventory distinguishes audited bool forms', report['native_direct_forms'].any? { |row| row['type'] == 'bool' })

  without = run.call('BC2CPP_IR_CONTEXT_RESULTS' => '0')
  baseline = without['ir_feedback'].find { |row| row['owner'] == 'ContextCases' && row['method'] == 'call_kw' && row['kind'] == 'return' }
  check.call('context opt-out withdraws keyword result proof', baseline['status'] == 'unknown')
  limited_report = run.call('BC2CPP_IR_CONTEXT_MAX_CONTEXTS' => '1')
  check.call('leaf reuse preserves context-budget refusals', limited_report == run.call('BC2CPP_IR_CONTEXT_MAX_CONTEXTS' => '1', 'BC2CPP_IR_LEAF_EVALUATIONS' => '0'))
  check.call('call index preserves context-budget refusals', limited_report == run.call('BC2CPP_IR_CONTEXT_MAX_CONTEXTS' => '1', 'BC2CPP_IR_CALL_INDEX' => '0'))
  limited = limited_report['ir_feedback'].find { |row| row['method'] == 'call_kw' && row['kind'] == 'return' }
  check.call('a context budget never publishes a provisional keyword summary', limited['status'] == 'unknown')
  rounds_report = run.call('BC2CPP_IR_CONTEXT_MAX_ROUNDS' => '1')
  check.call('leaf reuse preserves round-budget refusals', rounds_report == run.call('BC2CPP_IR_CONTEXT_MAX_ROUNDS' => '1', 'BC2CPP_IR_LEAF_EVALUATIONS' => '0'))
  check.call('call index preserves round-budget refusals', rounds_report == run.call('BC2CPP_IR_CONTEXT_MAX_ROUNDS' => '1', 'BC2CPP_IR_CALL_INDEX' => '0'))
  rounds = rounds_report['ir_feedback'].find { |row| row['method'] == 'call_kw' && row['kind'] == 'return' }
  check.call('a round budget never publishes bottom as a return type', rounds['status'] == 'unknown')
  no_effect = run.call('BC2CPP_IR_EFFECT_SUMMARIES' => '0')['ir_feedback'].find { |row| row['method'] == 'effect_read' && row['kind'] == 'return' }
  check.call('effect opt-out withdraws preserved slot refinement', no_effect['type'] != 'Symbol')
  no_shape = run.call('BC2CPP_IR_CONTEXT_SHAPES' => '0')['ir_feedback'].find { |row| row['method'] == 'call_array' && row['kind'] == 'return' }
  check.call('shape opt-out withdraws parameter-built frozen elements', no_shape['status'] == 'unknown')
end
puts 'context result checks passed'

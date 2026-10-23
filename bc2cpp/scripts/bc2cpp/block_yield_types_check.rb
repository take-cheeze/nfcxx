#!/usr/bin/env ruby
# frozen_string_literal: true

# BLOCK_YIELD_TYPES: the candidate emitter writes `{ (T1, ..., Tn) -> untyped }` only for a block whose yielded classes
# the yield sites prove (tools/bc2cpp/block_yield_types.rb), and `{ (*untyped) -> untyped }` otherwise. The first part
# checks the emitted text against synthetic facts (no MRBC). The second part (MRBC set) runs the real analysis over a
# fixture of yielders and checks which methods are typed and that every candidate line parses as RBS.
#
#   ruby scripts/bc2cpp/block_yield_types_check.rb
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/block_yield_types_check.rb

require 'json'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'rbs'
require_relative '../../tools/bc2cpp/type_check_rbs'
require_relative '../../tools/bc2cpp/type_check_run'

$failures = []
$checks = 0

def check(label, condition)
  $checks += 1
  puts "#{condition ? 'ok  ' : 'FAIL'} #{label}"
  $failures << label unless condition
end

DECLARED = Set['Integer', 'String', 'Symbol', 'Array', 'bool', 'untyped'].freeze

def method_fact(name, block_yield: nil, block_param: nil)
  { 'owner' => 'Probe', 'name' => name, 'visibility' => 'public', 'params' => [], 'optional_params' => [],
    'keyword_params' => [], 'opt' => 0, 'rest' => false, 'key' => 0, 'kdict' => false, 'scope' => 'engine',
    'block_yield' => block_yield, 'block_param' => block_param,
    'return' => { 'type' => nil, 'source' => nil, 'reason' => nil } }
end

def line_for(m) = TypeCheckRbs.method_line(m, DECLARED)

# Synthetic facts: the block type follows the proof row, and an unproven or missing row stays untyped.
typed = line_for(method_fact('each', block_yield: { 'arity' => 2, 'params' => [['Integer'], ['String']], 'source' => 'inferred:yield-sites' }))
check('two proven positions write their classes', typed.include?('?{ (Integer, String) -> untyped } -> untyped'))
union = line_for(method_fact('mixed', block_yield: { 'arity' => 1, 'params' => [%w[Integer String]], 'source' => 'inferred:yield-sites' }))
check('a position with two classes writes their union', union.include?('?{ (Integer | String) -> untyped }'))
partial = line_for(method_fact('partial', block_yield: { 'arity' => 2, 'params' => [['Integer'], []], 'source' => 'inferred:yield-sites' }))
check('an unknown position stays untyped, the others keep their class', partial.include?('?{ (Integer, untyped) -> untyped }'))
undeclared = line_for(method_fact('foreign', block_yield: { 'arity' => 1, 'params' => [['Game::Nope']], 'source' => 'inferred:yield-sites' }))
check('a class the program and core RBS do not declare is untyped', undeclared.include?('?{ (untyped) -> untyped }'))
nothing = line_for(method_fact('nothing', block_yield: { 'arity' => 0, 'params' => [], 'source' => 'inferred:yield-sites' }))
check('a proven zero-argument yield writes an empty parameter list', nothing.include?('?{ () -> untyped }'))
untried = line_for(method_fact('untried', block_yield: { 'reason' => 'yields through Proc#call' }))
check('a refused method keeps the untyped block', untried.include?('?{ (*untyped) -> untyped } -> untyped'))
missing = line_for(method_fact('missing'))
check('a method without a row keeps the untyped block', missing.include?('?{ (*untyped) -> untyped } -> untyped'))
required = line_for(method_fact('req', block_yield: { 'arity' => 1, 'params' => [['Integer']], 'source' => 'inferred:yield-sites' },
                                        block_param: { 'type' => 'Proc' }))
check('a block every call passes stays required', required.include?('{ (Integer) -> untyped } -> untyped') && !required.include?('?{'))
%w[typed union partial undeclared nothing untried missing required].each do |label|
  line = { 'typed' => typed, 'union' => union, 'partial' => partial, 'undeclared' => undeclared, 'nothing' => nothing,
           'untried' => untried, 'missing' => missing, 'required' => required }[label]
  check("#{label} parses as RBS", (RBS::Parser.parse_signature("class X\n  #{line}\nend\n") && true rescue false))
end

# The real analysis (MRBC): which fixture yielders are typed, and that the emitted candidate parses.
unless ENV['MRBC']
  puts 'SKIP block yield pipeline fixtures (set MRBC)'
  puts "#{$checks - $failures.size} of #{$checks} checks passed"
  exit($failures.empty? ? 0 : 1)
end

root = File.expand_path('../..', __dir__)
Dir.mktmpdir('block-yield-types') do |dir|
  source = File.join(dir, 'mruby-rpg2k/mrblib/yielders.rb')
  FileUtils.mkdir_p(File.dirname(source))
  File.write(source, <<~SOURCE)
    class BlockYieldProbe
      def one(n)
        yield n
      end

      def two
        yield 1, "a"
      end

      def mixed(flag)
        if flag
          yield 1
        else
          yield "x"
        end
      end

      def none
        yield
      end

      def splat(a)
        yield(*a)
      end

      def nested
        [1].each { |x| yield x }
      end

      def kept(&blk)
        yield 1
      end

      def calls(p)
        p.call(1)
      end
    end

    probe = BlockYieldProbe.new
    probe.one(3) { |v| v }
    probe.two { |a, b| a }
    probe.mixed(true) { |v| v }
    probe.none { 1 }
    probe.splat([1]) { |v| v }
    probe.nested { |v| v }
    probe.kept { |v| v }
    probe.calls(proc { 1 })
  SOURCE
  work = File.join(dir, 'work')
  Dir.mkdir(work)
  result = TypeCheckRun.run(root: root, mrbc: File.expand_path(ENV.fetch('MRBC')), workdir: work,
                            sources: [source], sig_dirs: [], display_root: dir,
                            extra_env: { 'BC2CPP_TYPE_CHECK_ONLY' => '1' })
  facts = JSON.parse(File.read(result.facts_path))
  rows = facts['methods'].select { |m| m['owner'] == 'BlockYieldProbe' }.to_h { |m| [m['name'], m['block_yield']] }
  check('a yield of a call-site-proven parameter is typed', rows['one'] == { 'arity' => 1, 'params' => [['Integer']], 'source' => 'inferred:yield-sites' })
  check('two literal yields type both positions', rows['two'] && rows['two']['params'] == [['Integer'], ['String']])
  check('two literal classes at one position are their union', rows['mixed'] && rows['mixed']['params'] == [%w[Integer String]])
  check('a method that yields nothing is a zero-argument yielder', rows['none'] == { 'arity' => 0, 'params' => [], 'source' => 'inferred:yield-sites' })
  check('a splatted yield is refused', rows['splat'].is_a?(Hash) && rows['splat'].key?('reason'))
  check('a yield in a nested block is refused', rows['nested'].is_a?(Hash) && rows['nested'].key?('reason'))
  check('a &blk parameter is refused', rows['kept'] == { 'reason' => 'takes a block parameter' })
  check('a Proc#call on the block is refused', rows['calls'].nil? || rows['calls'].key?('reason'))

  emitted = TypeCheckRbs.emit(facts, File.join(dir, 'candidates'))
  text = File.read(File.join(dir, 'candidates', 'BlockYieldProbe.rbs'))
  check('the candidate declares the proven block', text.include?('def one: (Integer) ?{ (Integer) -> untyped } -> untyped'))
  check('the candidate declares the proven pair', text.include?('?{ (Integer, String) -> untyped }'))
  check('the candidate keeps the untyped block for a splat', text.include?('def splat: (Array[untyped]) ?{ (*untyped) -> untyped } -> untyped'))
  check('the emitter skipped no method', emitted[:skipped].empty?)
  parsed = RBS::Parser.parse_signature(text)
  check('the candidate parses as RBS', parsed.is_a?(Array) && !parsed.empty?)
end

puts "#{$checks - $failures.size} of #{$checks} checks passed"
exit($failures.empty? ? 0 : 1)

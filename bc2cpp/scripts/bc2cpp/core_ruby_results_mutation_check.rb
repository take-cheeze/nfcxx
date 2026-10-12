#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']
AUDIT = 'codegen_core_ruby_results.rb'
MUTANTS = [
  ['control', nil, nil, nil, nil],
  ['Hash filter result treated as Array', "called == 'map' || trace_new_target(irep, pin_idx, pin.reg, registry: registry) == 'Array'", 'true', 'kill switch', /map preserves both receiver paths/, 'class_layout.rb'],
  ['receiver union switch ignored', "classes.size > 1 && ENV['BC2CPP_CORE_RUBY_RECEIVER_UNIONS'] == '0'", 'false', 'receiver union kill switch', /every union member returns Array/],
  ['receiver union member omitted', 'classes.reduce(0) do |joined, (bit, klass)|', 'classes.first(1).reduce(0) do |joined, (bit, klass)|', 'Hash map override', /every union member returns Array/],
  ['union receiver treated as Array', 'return RETURN_CORE_CLASS[mask] == klass', 'return true', 'core bodies', /union map preserves both receiver paths/, 'codegen_loop_regions.rb'],
  ['positional switch ignored', "argc.positive? && ENV['BC2CPP_CORE_RUBY_POSITIONAL_RESULTS'] == '0'", 'false', 'positional kill switch', /positional Array memo/],
  ['positional argument masks ignored', '@arguments.fetch(reg - 1, NumericFlow::OTHER)', 'NumericFlow::ARR', 'core bodies', /positional Hash memo|memo_unknown stays unproved|memo_nil stays unproved/],
  ['positional argument cache omitted', 'key = [insn.sym, block_given, arguments]', 'key = [insn.sym, block_given]', 'core bodies', /unresolved receiver memo|unresolved receiver Hash memo|unresolved unknown memo stays unproved/],
  ['positional arity ignored', 'fields[0] == arguments.size', 'true', 'positional core arity', /positional Array memo/],
  ['positional optional shape ignored', 'fields.values_at(1, 2, 3, 4, 5, 7).all?(&:zero?)', 'fields.values_at(2, 3, 4, 5, 7).all?(&:zero?)', 'positional optional argument', /positional Array memo/],
  ['positional rest shape ignored', 'fields.values_at(1, 2, 3, 4, 5, 7).all?(&:zero?)', 'fields.values_at(1, 3, 4, 5, 7).all?(&:zero?)', 'positional rest argument', /positional Array memo/],
  ['positional keyword shape ignored', 'fields.values_at(1, 2, 3, 4, 5, 7).all?(&:zero?)', 'fields.values_at(1, 2, 3, 5, 7).all?(&:zero?)', 'positional keyword argument', /positional Array memo/],
  ['positional captured write ignored', 'fixnum_proof_ctx(body)[:upvars]', 'Set.new', 'positional core captured write', /positional Array memo/],
  ['union switch ignored', "return nil if ENV['BC2CPP_NATIVE_EXPRESSION_UNIONS'] == '0'", 'return nil if false', 'union kill switch', /mixed exact classes/, 'codegen_native_send.rb'],
  ['union coverage ignored', 'classes.keys.reduce(0, :|) == mask', 'true', 'core bodies', /unrepresented class keeps dispatch|nil keeps error path/, 'codegen_native_send.rb'],
  ['name switch ignored', "return nil if ENV['BC2CPP_CORE_RUBY_NAME_RESULTS'] == '0'", 'return nil if false', 'name kill switch', /unknown filter result/],
  ['nested switch ignored', "return nil if !seen.empty? && ENV['BC2CPP_CORE_RUBY_NESTED_RESULTS'] == '0'", 'return nil if false', 'nested kill switch', /nested sort result/],
  ['nested project lookup ignored', 'return nil if registry.any? { |definition| chain.include?(definition.owner) && !definition.core }', 'return nil if false', 'nested project override', /nested sort result/],
  ['nested actual return ignored', 'mask if mask.positive? && (mask & ~NumericFlow::CONTAINERS).zero?', 'NumericFlow::ARR', 'nested core override', /nested sort result/],
  ['super actual return ignored', 'mask if mask.positive? && (mask & ~NumericFlow::CONTAINERS).zero?', 'NumericFlow::ARR', 'super core override', /range helper and super result/],
  ['aliased super context ignored', 'return NumericFlow::OTHER unless @call_name == @target.name', 'return NumericFlow::OTHER if false', 'core bodies', /aliased super stays unproved/],
  ['foreign name ignored', 'return nil unless @closed_world.native_return_sources_visible?(name, paths)', 'return nil if false', 'foreign filter definition', /unknown filter result/],
  ['opaque name ignored', 'return nil unless opaque && opaque.none? { |_owner, method| method == name }', 'return nil if false', 'outside filter definition', /unknown filter result/],
  ['kill switch ignored', "return nil if ENV['BC2CPP_CORE_RUBY_RESULTS'] == '0'", 'return nil if false', 'kill switch', /mapped result/],
  ['symbol block switch ignored', "writer.op == 'LOADSYM' && ENV['BC2CPP_CORE_RUBY_SYMBOL_BLOCKS'] != '0'", "writer.op == 'LOADSYM'", 'symbol block kill switch', /Symbol block reject result/],
  ['any block writer taken for a Symbol', "writer.op == 'LOADSYM' && ENV['BC2CPP_CORE_RUBY_SYMBOL_BLOCKS'] != '0'", 'true', 'core bodies', /block held in a local stays unproved/],
  ['caller break ignored', 'caller ? %w[BREAK] : %w[BREAK RETURN_BLK]', 'caller ? [] : %w[BREAK RETURN_BLK]', 'core bodies', /breaking stays unproved/],
  ['callee nonlocal return ignored', 'caller ? %w[BREAK] : %w[BREAK RETURN_BLK]', 'caller ? %w[BREAK] : %w[BREAK]', 'core nonlocal return', /mapped result/],
  ['captured writes ignored', 'fixnum_proof_ctx(body)[:upvars]', 'Set.new', 'core captured write', /mapped result/],
  ['project lookup ignored', 'return nil if registry.any? { |definition| chain.include?(definition.owner) && !definition.core }', 'return nil if false', 'Array map override', /mapped result/],
  ['actual return ignored', 'mask if mask.positive? && (mask & ~NumericFlow::CONTAINERS).zero?', 'NumericFlow::ARR', 'changed core return', /mapped result/],
  ['core alias index omitted', 'Array(block_core_index[[owner, name]])', '[]', 'core bodies', /mapped result/],
  ['interpreted core override ignored', 'return nil if self.class.core_result_opaque_defs&.include?([owner, name])', 'return nil if false', 'interpreted core override', /mapped result/],
  ['unmodelled core alias ignored', 'out << [site[:owner], site[:new]] unless mapped && !conditional', 'out << [site[:owner], site[:new]] if false', 'unmodelled core alias', /mapped result/],
  ['core installer ignored', 'return nil unless core_installed && !core_installed.include?(name)', 'return nil if false', 'core alias_method override', /mapped result/]
].freeze

mutate = lambda do |(_name, pattern, replacement, test_case, expected, audit)|
  Dir.mktmpdir do |dir|
    Dir.children(ROOT).reject { |entry| %w[.git tools .commandcode].include?(entry) }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, entry), File.join(dir, entry))
    end
    FileUtils.mkdir_p(File.join(dir, 'tools'))
    Dir.children(File.join(ROOT, 'tools')).reject { |entry| entry == 'bc2cpp' }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, 'tools', entry), File.join(dir, 'tools', entry))
    end
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), File.join(dir, 'tools'))
    if pattern
      path = File.join(dir, 'tools/bc2cpp', audit || AUDIT)
      text = File.read(path)
      next nil unless text.include?(pattern)

      File.write(path, text.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'KRR_GENERATED_ONLY' => '1', 'KRR_CASE' => test_case }
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/core_ruby_results_check.rb')])
  end
end
failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, pattern, _replacement, _test_case, expected), run|
  ok = if run.nil? then false
       elsif pattern.nil? then run.success
       else !run.success && run.out.lines.any? { |line| line.match?(/^\s+FAIL /) && line.match?(expected) }
       end
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  unless ok
    failures << name
    warn(run ? run.out.lines.last(12).join : 'mutation site missing')
  end
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp core Ruby results mutation check: PASS'

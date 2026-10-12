#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']
AUDIT = 'codegen_profiler_results.rb'
MUTANTS = [
  ['control', nil, nil, nil, nil],
  ['native source audit ignored', 'NativeClassResults.source_matches?(paths.first, ProfilerResults::PATH, ProfilerResults::SHA)', 'true', 'native', /changed native source withdraws/],
  ['constant bindings ignored', "@closed_world.native_class_constant_stable?('RGSS::Profiler', bindings: 2)", 'true', 'constant rebind', /direct result/],
  ['kill switch ignored', "return nil if ENV['BC2CPP_PROFILER_RESULTS'] == '0'", 'return nil if false', 'kill switch', /direct result/],
  ['Ruby lookup ignored', "(@registry[name] || []).all? { |definition| definition.owner == '<native>' && definition.irep.nil? }", 'true', 'Ruby override', /direct result/],
  ['lexical resolution ignored', "return nil unless resolve_class_constant_name('RGSS', numeric_owner_of(irep)&.owner) == 'RGSS'", 'return nil if false', 'lexical shadow', /direct result/],
  ['native source closure ignored', "(@closed_world.native_paths_spelling(name) + Array(@native_name_sources&.fetch(name, nil))).uniq", '@closed_world.native_paths_spelling(name)', 'native replacement', /direct result/],
  ['block exits ignored', 'return nil unless core_ruby_result_exits_safe?(body)', 'return nil if false', 'native', /breaking stays unproved/],
  ['unknown return discarded', 'mask if (mask & NumericFlow::OTHER).zero?', 'mask & ~NumericFlow::OTHER', 'native', /unknown_arm stays unproved/],
  ['empty fixpoint becomes unknown', 'mask if (mask & NumericFlow::OTHER).zero?', 'mask if mask.positive? && (mask & NumericFlow::OTHER).zero?', 'native', /loaded result|read result/],
  ['parent invalidation omitted', 'stack.concat(Array(@profiler_result_parents&.fetch(cur, nil)))', '', 'native', /loaded result|read result|late_read stays unproved/, 'codegen_return_classes.rb'],
  ['capture stores copied', 'mrb_value& r#{index} = *bc2cpp_prof_up_#{i}', 'mrb_value r#{index} = *bc2cpp_prof_up_#{i}', 'native', /runtime parity/, 'codegen_loop_inline.rb', true],
  ['capture namespace overlaps', 'offset = (upvars.map(&:last).max || -1) + 1', 'offset = 0', 'native', /runtime fixture builds/, 'codegen_loop_inline.rb', true],
  ['nested capture offset ignored', 'index + (reg_offset || 0)', 'index', 'native', /runtime parity/, 'codegen_loop_inline.rb', true],
  ['nonlocal return in helper', 'next unless core_ruby_result_exits_safe?(block_irep)', 'next if false', 'native', /runtime parity/, 'codegen_loop_regions.rb', true]
].freeze

mutate = lambda do |(_name, pattern, replacement, test_case, expected, audit, runtime)|
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
    # Local receiver proofs can independently recover the mutated global fixpoint.
    env = { 'BC2CPP_CALL_CONTEXT_RESULTS' => '0', 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'PFR_GENERATED_ONLY' => runtime ? '0' : '1', 'PFR_CASE' => test_case }
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/profiler_results_check.rb')])
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
puts 'bc2cpp profiler results mutation check: PASS'

#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for NATIVE_SINGLETON_CALL (docs/adr/0416). Each mutant is a copy of tools/bc2cpp with one
# soundness condition broken; scripts/bc2cpp/native_singleton_check.rb, run against the mutant through
# BC2CPP_TOOL on the one world (or runtime scenario) that exercises that condition, must FAIL on the check
# that guards it. A mutant that passes means the condition has no negative case. An unmutated copy runs first
# and must pass: it proves the harness runs the same check the mutants run.
#
# The mutant tree lives inside the repository (.mutants/, removed on exit): bc2cpp.rb finds the engine's gems
# relative to itself (../..), so a copy elsewhere would read a different layout.
#
# The runtime mutants (the C++ helper in symbol_cache.rb) run the compiled-versus-interpreted scenario and need
# BC2CPP_MRUBY_FULL (or a rake-built full-core mruby); without one they print SKIP and the generated-code
# mutants still run.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/native_singleton_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'
require_relative 'fixture_runtime'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

SINGLETON = 'codegen_native_singleton.rb'
PRIVATE_RUN = 'base after a runtime private'

# [name, file, pattern, replacement, worlds to run (NS_WORLDS), runs (NS_RUNS, nil = generated code only), FAIL label]
MUTANTS = [
  ['a Ruby definition of the name does not refuse', SINGLETON,
   "@registry.fetch(name, []).any? { |definition| definition.owner == singleton_owner }", 'false',
   'redefined,reopened', nil, /does not bind exist\?/],
  ['the build\'s outside Ruby definers are not read', SINGLETON,
   'return [nil, :outside_ruby] if native_singleton_foreign_names(inputs[:ruby]).include?(name)', '', 'an outside Ruby definer', nil,
   /does not bind exist\?/],
  ['the closed world\'s outside Ruby definers do not refuse', SINGLETON,
   'return :outside_ruby if @outside_ruby_names.include?(name)', 'nil', 'a build gem Ruby definer', nil, /does not bind exist\?/],
  ['a global refusal does not refuse', SINGLETON,
   'return :global_refusal if @global_refusal', 'nil', 'a global refusal and a scoped native constant', nil,
   /does not bind snap_to_bitmap/],
  ['an alias or define_method install does not refuse', SINGLETON,
   'return [nil, :installed] if devirt_blocked_name?(name) || symbol_installed_names.include?(name)',
   'return [nil, :installed] if devirt_blocked_name?(name)', 'base', nil, /does not bind file\?/],
  ['a visibility change does not refuse', SINGLETON,
   'return :visibility_name if @visibility_names.include?(name)', 'nil', 'base', nil, /does not bind tan/],
  ['an unplaceable DEF does not refuse', SINGLETON,
   'return :unknown_def if @unknown_defs.include?(name)', 'nil', 'a def nested in a method', nil, /does not bind exist\?/],
  ['an include or prepend on the singleton class is ignored', SINGLETON,
   '!@unknown_mixins.include?(singleton) && Array(@included_modules[singleton]).empty? &&
      Array(@prepended_modules[singleton]).empty?', 'true', 'singleton include,singleton prepend', nil, /does not bind exist\?/],
  ['a constant that is not stable is trusted', SINGLETON,
   'CodeGen.stable_class_constants&.include?(written)', 'true', 'reassigned constant', nil, /does not bind exist\?/],
  ['an outside Ruby constant nested in the lexical scope does not shadow', SINGLETON,
   'return nil if scopes.any? { |scope| visible.include?(scope) || visible.include?(scope.split(\'::\').last) }', '', 'a foreign nested constant', nil,
   /NsF::Probe2#exist does not bind/],
  ['the ancestors of the lexical owner are not searched', SINGLETON,
   'scopes.merge(chain.select { |name| name.is_a?(String) }.map { |name| name.split(\'::\').last })', 'nil', 'a foreign nested constant', nil,
   /NsKid#exist2 does not bind/],
  ['a name with no native registration on the constant is bound', 'native_singletons.rb',
   'owners.count("#{class_path}.singleton") >= 1', 'true', 'base', nil,
   /does not bind nonexistent_zork/],
  ['a spelling of the name that is not a registration is not a refusal', 'native_singletons.rb',
   'return nil if entry[:spellings] != entry[:registrations].size', 'nil', 'a native alias of the name', nil, /does not bind exist\?/],
  ['the kill switch is ignored', SINGLETON,
   "return [nil, :disabled] if ENV[ENV_SWITCH] == '0'", 'nil', 'kill switch', nil, /kill switch/],
  ['the runtime fill caches a private method', 'symbol_cache.rb',
   '      if (m.flags & (MRB_METHOD_PRIVATE_FL | MRB_METHOD_PROTECTED_FL)) return false;
', '', '-', PRIVATE_RUN, /#{Regexp.escape(PRIVATE_RUN)}: the compiled calls answer/],
  ['the runtime fill skips the registered argument-count check of a raw C function', 'symbol_cache.rb',
   '        if (argc < min || (max >= 0 && argc > max)) mrb_argnum_error(M, argc, min, max);
', '', '-', 'base', /base: the compiled calls answer/],
  ['the fallback skips the checked send', 'symbol_cache.rb',
   '      if (bc2cpp_sym_check[i]) bc2cpp_check_send(M, recv, mid, argc, argv, bc2cpp_sym_check[i] == 2);
      return bc2cpp_funcall_argv(M, recv, mid, argc, argv);
    }
  CPP
  private_constant :NATIVE_SINGLETON', "      return bc2cpp_funcall_argv(M, recv, mid, argc, argv);
    }
  CPP
  private_constant :NATIVE_SINGLETON", '-', PRIVATE_RUN, /#{Regexp.escape(PRIVATE_RUN)}: the compiled calls answer/]
].freeze

runtime = Bc2cppFixtureRuntime
mutate = lambda do |(_name, file, pattern, replacement, worlds, runs, _expected)|
  FileUtils.mkdir_p(File.join(ROOT, '.mutants'))
  dir = Dir.mktmpdir('m', File.join(ROOT, '.mutants'))
  begin
    Dir.children(ROOT).reject { |entry| %w[.git tools .mutants].include?(entry) }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, entry), File.join(dir, entry))
    end
    FileUtils.mkdir_p(File.join(dir, 'tools'))
    Dir.children(File.join(ROOT, 'tools')).reject { |entry| entry == 'bc2cpp' }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, 'tools', entry), File.join(dir, 'tools', entry))
    end
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), File.join(dir, 'tools'))
    if pattern
      path = File.join(dir, 'tools', 'bc2cpp', file)
      text = File.read(path)
      next nil unless text.include?(pattern)

      File.write(path, text.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'BC2CPP_JOBS' => '1' }
    if worlds
      env['NS_WORLDS'] = worlds
      env['NS_GENERATED_ONLY'] = '1' unless runs
    end
    env['NS_RUNS'] = runs if runs
    expected = _expected
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/native_singleton_check.rb')],
                         stop_on: expected && Regexp.new("^\\s+FAIL .*(?:#{expected.source})"))
  ensure
    FileUtils.rm_rf(dir)
    Dir.rmdir(File.join(ROOT, '.mutants')) if Dir.empty?(File.join(ROOT, '.mutants'))
  end
end

failures = []
control = [['unmutated control', nil, nil, nil, nil, nil, nil]]
Bc2cppMutantPool.each_ordered(control, work: mutate) do |(name, *), run|
  passed = run.success
  puts "  #{passed ? 'ok  ' : 'FAIL'} #{name} passes the check"
  unless passed
    puts run.out.lines.grep(/^\s+FAIL /).first(5).join
    failures << name
  end
end

full = runtime.full_or_build
mutants = MUTANTS.reject do |name, _file, _pattern, _replacement, _worlds, runs, _expected|
  skip = runs && (full.nil? || !runtime.compiler?)
  puts "  SKIP #{name}: needs BC2CPP_MRUBY_FULL and g++" if skip
  skip
end
Bc2cppMutantPool.each_ordered(mutants, work: mutate) do |(name, file, _pattern, _replacement, _worlds, _runs, expected), run|
  if run.nil?
    puts "  FAIL #{name}: the mutation site is gone from #{file}"
    failures << name
    next
  end
  failed_lines = run.out.lines.grep(/^\s+FAIL /)
  killed = !run.success && failed_lines.any? { |l| l.match?(expected) }
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp native singleton mutation check: PASS'
else
  warn "bc2cpp native singleton mutation check: #{failures.size} failure(s)"
  exit 1
end

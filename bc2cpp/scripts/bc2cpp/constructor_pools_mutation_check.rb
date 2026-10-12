#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for CONSTRUCTOR_POOLS (docs/adr/0313). Each mutant is a copy of tools/bc2cpp with one soundness condition
# broken; scripts/bc2cpp/constructor_pools_check.rb, run against the mutant through BC2CPP_TOOL, must FAIL on the check
# that guards that condition. A mutant that passes means the condition has no negative case. The unmutated copy runs
# first as a control and must pass, so a mutant is never "killed" by a world the copy itself cannot generate.
#
# The generated-code half decides every mutant (CP_GENERATED_ONLY), so no mruby build is needed.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/constructor_pools_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

POOLS = 'codegen_constructor_pools.rb'
WORLD = 'closed_world.rb'

# [name, file, pattern, replacement, check label that must FAIL]; a nil pattern is the control.
MUTANTS = [
  ['control (unmutated)', POOLS, nil, nil, nil],
  ['the kill switch is ignored', POOLS,
   "return 'BC2CPP_CONSTRUCTOR_POOLS=0' if ENV.fetch('BC2CPP_CONSTRUCTOR_POOLS', '1') == '0'", '',
   /kill switch/],
  ['a splat site is dropped instead of withdrawing the target', POOLS,
   "found[:broken][d.irep] ||= \"new with a splat or keyword at \#{irep.label}:\#{idx}\" if argc.nil?", 'found[:sites][d.irep].pop if argc.nil?',
   /NEG CpSplat#splat_count/],
  ['a `new` on a computed receiver withdraws nothing', POOLS, 'found[:open_argc] << ', '',
   /NEG a `new` on a computed receiver with one argument/],
  ['rooted sites (implicit-self new, self.class.new) are ignored', POOLS,
   'rooted = found[:rooted].select { |root, _argc, _site| reach.any? { |klass| constructor_chain(klass).include?(root) } }', 'rooted = []',
   /NEG CpRoot#root_count|NEG CpCopy2#cp2_count/],
  ['a constant bound by SETCONST still names a class', WORLD,
   '!@global_refusal && !@dynamic_constant_mutation && class_constant?(name)', 'true',
   /NEG a constant bound to a class/],
  ['a source that spells the class does not withdraw it', POOLS,
   'reach.any? { |klass| @closed_world.outside_spells_class?(klass) }', 'false',
   /NEG a build gem whose (?:native|Ruby) source spells the class/],
  ['a class below a native ancestor (an Exception) is pooled', POOLS,
   'return false unless @closed_world.class_declared?(klass)', 'return true unless @closed_world.class_declared?(klass)',
   /NEG CpErr#err_count/],
  ['an aliased initialize is not withdrawn', POOLS, '@constructor_aliased << klass', 'nil',
   /NEG CpAliased#aliased_count/],
  ['a post-mandatory parameter is allowed', POOLS, 'fields[3].to_i.zero? && ', '', /NEG CpPost#post_count/],
  ['the widest optional call is not a site', POOLS, 'mand + opt)', 'mand + opt - 1)', /NEG CpOpt2#opt2_count/],
  ['a Symbol :new or :initialize does not turn the analysis off', POOLS,
   "return \"\#{insn.op} :\#{names.join('/')} names new/initialize\" unless klass", 'next unless klass',
   /NEG a Symbol :new|NEG instance_method\(:initialize\)/],
  ['a Ruby-defined new is ignored', POOLS,
   "return 'Ruby-defined new' unless (@registry['new'] || []).all? { |d| d.owner == '<native>' }", '',
   /NEG a Ruby-defined self.new/],
  ['an unresolved superclass (a wild class) is ignored', POOLS,
   'return nil unless hierarchy && hierarchy[:wild].empty?', 'return nil unless hierarchy', /NEG a wild superclass/]
].freeze

# nil when the mutation site is gone, else the run of the check against the mutant.
mutate = lambda do |(_name, file, pattern, replacement, expected)|
  Dir.mktmpdir do |dir|
    # bc2cpp.rb finds the engine's gems relative to itself (../..), so the copy keeps the repository layout.
    Dir.children(ROOT).reject { |entry| %w[.git tools].include?(entry) }.each do |entry|
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'CP_GENERATED_ONLY' => '1' }
    # A mutant stops at the first FAIL line it is expected to cause (Bc2cppMutantPool.run); the control runs to the end.
    stop = pattern ? /^\s+FAIL .*(?:#{expected.source})/ : nil
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/constructor_pools_check.rb')], stop_on: stop)
  end
end

failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, file, pattern, _replacement, expected), run|
  if run.nil?
    puts "  FAIL #{name}: the mutation site is gone from #{file}"
    failures << name
    next
  end
  if pattern.nil?
    puts "  #{run.success ? 'ok  ' : 'FAIL'} #{name} passes"
    unless run.success
      puts run.out.lines.last(15).join
      failures << name
    end
    next
  end
  failed_lines = run.out.lines.grep(/^\s+FAIL /)
  killed = !run.success && failed_lines.any? { |l| l.match?(expected) }
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    puts run.out.lines.last(8).join if failed_lines.empty?
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp constructor pools mutation check: PASS'
else
  warn "bc2cpp constructor pools mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end

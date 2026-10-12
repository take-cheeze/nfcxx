#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for docs/adr/0382 (CONSTRUCTOR_KEYWORDS, POOL_SELF_CLASS). Each mutant is a copy of tools/bc2cpp with one
# soundness condition broken; scripts/bc2cpp/ivar_typing_check.rb, run against the mutant through BC2CPP_TOOL, must FAIL on
# the check that guards that condition. A mutant that passes means the condition has no negative case.
#
# Two conditions have no mutant on purpose: the `n != '*'` test of a keyword call (a splat reads as 0 positionals and the
# fewer-than-mandatory refusal catches it first) and the module / declared-class test of return_class_self_receiver (the
# class hierarchy lookup refuses a module as well). Both are defence in depth behind a condition that is mutated.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/ivar_typing_mutation_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL]
MUTANTS = [
  ['a keyword call with fewer positionals than mandatory parameters is a site', 'codegen_constructor_pools.rb',
   'positionals >= mandatory_arity(@ireps[d.irep])', 'true', /KwShort: a keyword call with fewer|KwSShortBase/],
  ['a packed kdict (nk=*) counts as literal keywords', 'codegen_constructor_pools.rb',
   "nk && nk != '*' && nk.to_i.positive?", 'nk && nk.to_i >= 0', /KwSplat/],
  ['a post-mandatory parameter is accepted', 'codegen_constructor_pools.rb',
   'mand.positive? && fields[3].to_i.zero? &&', 'mand.positive? &&', /KwPost/],
  ['a bare super no longer withdraws the base initialize', 'codegen_constructor_pools.rb',
   'found[:broken][target.irep] = "super with unmodelled arguments at #{irep.label}:#{idx}"', 'nil', /KwZBase/],
  ['a keyword super with too few positionals is a site', 'codegen_constructor_pools.rb',
   'elsif kw_argc && constructor_keyword_site_ok?(target, kw_argc)', 'elsif kw_argc', /KwSShortBase/],
  ['the keyword kill switch is ignored', 'codegen_constructor_pools.rb',
   "ENV.fetch('BC2CPP_CTOR_KEYWORDS', '1') != '0'", 'true', /BC2CPP_CTOR_KEYWORDS=0/],
  ['the descendants of the owner are left out of the self class set', 'codegen_return_classes.rb',
   'classes = [owner] + hierarchy[:descendants].to_a', 'classes = [owner]', /SfHolderPair/],
  ['a rebinding send no longer withdraws the self class', 'codegen_return_classes.rb',
   'return "#{insn.sym} at #{irep.label}"', 'next', /UnboundMethod bound|define_method from a Method object/],
  ['the self class kill switch is ignored', 'codegen_return_classes.rb',
   "return 'BC2CPP_POOL_SELF_CLASS=0' if ENV.fetch('BC2CPP_POOL_SELF_CLASS', '1') == '0'", 'nil', /BC2CPP_POOL_SELF_CLASS=0/]
].freeze

failures = []
mutate = lambda do |(_name, file, pattern, replacement, expected)|
  Dir.mktmpdir do |dir|
    Bc2cppMutantPool.copy_generator(ROOT, dir)
    path = File.join(dir, 'bc2cpp', file)
    text = File.read(path)
    next :site_gone unless text.include?(pattern)

    File.write(path, text.sub(pattern) { replacement })
    env = { 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb') }
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/ivar_typing_check.rb')],
                         stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, file, _pattern, _replacement, expected), run|
  if run == :site_gone
    puts "  FAIL #{name}: the mutation site is gone from #{file}"
    failures << name
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
  puts 'bc2cpp ivar typing mutation check: PASS'
else
  warn "bc2cpp ivar typing mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end

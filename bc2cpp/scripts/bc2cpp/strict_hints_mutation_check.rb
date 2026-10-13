#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for STRICT_HINTS (docs/adr/0419). Each mutant is a copy of tools/bc2cpp with one
# condition of the tier broken; scripts/bc2cpp/strict_hints_check.rb, run against the mutant through
# BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that passes means the
# condition has no negative case.
#
# The mutants run through Bc2cppMutantPool (BC2CPP_JOBS at a time; a mutant stops at the FAIL line it is
# expected to cause). A mutant whose expected failure needs the compiled run says so; the rest run the
# generated-code half only (SH_GENERATED_ONLY=1).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/strict_hints_mutation_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['BC2CPP_STRICT_HINTS=0 turns the tier on', 'strict_hints.rb',
   "return [] if env == '0'",
   "return DEFAULT_FAMILIES if env == '0'",
   /0 selects no family|0 output has no hint/, false],
  ['an unknown family name is silently ignored', 'strict_hints.rb',
   "list = env.split(',').map(&:strip).reject(&:empty?)",
   "list = env.split(',').map(&:strip).select { |f| FAMILIES.include?(f) }",
   /unknown family is an error/, false],
  ['a forced site carries no marker (so it is neither listed nor gated)', 'strict_hints.rb',
   'def marker(family, name)
    "/* STRICT_HINT #{family}: #{name} */"',
   "def marker(family, name)\n    ''",
   /marked site becomes|families are counted|reviewed gate fails/, false],
  ['an unreviewed forced site passes the gate', 'strict_hints.rb',
   'unreviewed = (found - reviewed).sort.map', 'unreviewed = [].sort.map',
   /unlisted site fails|reviewed gate fails/, false],
  ['a stale reviewed entry passes the gate', 'strict_hints.rb',
   'return unreviewed unless stale', 'return unreviewed',
   /gone from a compiled method fails as stale/, false],
  ['the strict else is emitted with the switch off', 'codegen_send.rb',
   'return nil unless strict_hint_enabled?(family) && @closed_world && argv.size <= FUNCALL_ARGC_MAX',
   'return nil unless @closed_world && argv.size <= FUNCALL_ARGC_MAX',
   /byte-identical|default output has no hint violation|forces TYPED sites only/, false],
  ['a family list forces every family', 'strict_hints.rb',
   'families.include?(family)', 'families.any?',
   /forces TYPED sites only/, false],
  ['the open world is forced too', 'codegen_send.rb',
   'strict_hint_enabled?(family) && @closed_world && argv.size', 'strict_hint_enabled?(family) && argv.size',
   /open world forces nothing/, false],
  ['PROVEN keeps a hint class with a subclass', 'codegen_send.rb',
   'StrictHints.proven_only? && !(@closed_world.exact_class?(owner) && nil_unanswerable?(name))',
   'false && !(@closed_world.exact_class?(owner) && nil_unanswerable?(name))',
   /hint class with a subclass keeps its dispatch/, false],
  ['PROVEN forgets that nil answers some names', 'codegen_send.rb',
   '(@closed_world.exact_class?(owner) && nil_unanswerable?(name))', '(@closed_world.exact_class?(owner))',
   /name nil answers \(sh_tag\) keeps its dispatch/, false],
  ['an IVAR_ACCESSOR site keeps its dispatch', 'codegen_send.rb',
   "strict_hint_wrap('ivar_accessor', d, recv, name, argv, owner) do",
   "strict_hint_wrap('ivar_accessor', d, recv, name, argv, owner, hinted: false) do",
   /ShHolder#read_size: the guard's else arm|families are counted/, false],
  ['the helper does not log', 'symbol_cache.rb',
   'mrb_str_new_lit(M, "[RPG2k] hint violation: ")', 'mrb_str_new_lit(M, "")',
   /logs `\[RPG2k\] hint violation/, true],
  ['the helper dispatches instead of raising', 'symbol_cache.rb',
   '#if defined(BC2CPP_HINT_VIOLATION_DISPATCH) || defined(BC2CPP_HINT_VIOLATION_LOG)', '#if 1',
   /raises BC2cppHintViolation/, true],
  ['the raised error is not a NoMethodError', 'symbol_cache.rb',
   'mrb_define_class(M, "BC2cppHintViolation", mrb_exc_get_id(M, mrb_intern_lit(M, "NoMethodError")))',
   'mrb_define_class(M, "BC2cppHintViolation", M->eStandardError_class)',
   /raises BC2cppHintViolation \(a NoMethodError\)/, true],
  ['verify mode does not name the hint violation', 'symbol_cache.rb',
   'NOMETHOD_VERIFY: hint violation reached: %s', 'NOMETHOD_VERIFY: reached: %s',
   /verify mode: a reached forced site aborts/, true],
  ['the reviewed gate only warns', 'bc2cpp.rb',
   'abort msg unless ENV[StrictHints::ALLOW_ENV] ==', 'warn msg unless ENV[StrictHints::ALLOW_ENV] ==',
   /reviewed gate fails a run/, false]
].freeze

# SH_MUTANTS=regexp runs only the mutants whose name matches (debugging a surviving one).
SELECTED = MUTANTS.select { |m| ENV['SH_MUTANTS'].nil? || m.first.match?(Regexp.new(ENV['SH_MUTANTS'])) }

failures = []
mutate = lambda do |(_name, file, pattern, replacement, _expected, needs_run)|
  Dir.mktmpdir do |dir|
    Bc2cppMutantPool.copy_generator(ROOT, dir)
    path = File.join(dir, 'bc2cpp', file)
    text = File.read(path)
    next :site_gone unless text.include?(pattern)

    File.write(path, text.sub(pattern) { replacement })
    env = { 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb') }
    env['SH_GENERATED_ONLY'] = '1' unless needs_run
    expected = MUTANTS.find { |m| m.first == _name }[4]
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/strict_hints_check.rb')],
                         stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

Bc2cppMutantPool.each_ordered(SELECTED, work: mutate) do |(name, file, _pattern, _replacement, expected, _needs_run), run|
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
  puts 'bc2cpp strict hints mutation check: PASS'
else
  warn "bc2cpp strict hints mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end

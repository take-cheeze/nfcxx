#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_CALLSITE_CONTRADICTION (TC1018): an RBS parameter declaration (Integer / Float / `T?` / a program class)
# that a call site provably contradicts is a type-check error: the entry guard (DECLARED_PARAM_GUARD) would raise
# BC2cppDeclarationViolation there. A site that only MAY pass another class is silent. Generated end to end through
# type_check's analysis on a fixture program with its own signature (no mruby build).
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/declared_callsite_check.rb
require 'json'
require 'tmpdir'
require_relative '../../tools/bc2cpp/world_root'
require_relative '../../tools/bc2cpp/type_check_run'
require_relative '../../tools/bc2cpp/type_check_report'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/codegen'
require_relative '../../tools/bc2cpp/codegen_class_pools'
require_relative '../../tools/bc2cpp/codegen_declared_callsites'
require_relative 'check_support'

suite = FixtureCheck.new('declared_callsite_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Dog
    def bark
      1
    end
  end

  class Cat
    def purr
      2
    end
  end

  class Zoo
    def tally_up(n)
      n
    end

    def maybe_count(n)
      n
    end

    def pet(animal)
      animal
    end

    def widen(x)
      x
    end

    def opt_name(n)
      n
    end

    def float_into_int
      tally_up(1.5)
    end

    def nil_into_int
      tally_up(nil)
    end

    def cat_into_dog
      pet(Cat.new)
    end

    def int_into_float
      widen(2)
    end

    def int_into_int
      tally_up(3)
    end

    def float_or_int(flag)
      maybe_count(flag ? 1 : 2.5)
    end

    def nil_into_nilable
      opt_name(nil) + opt_name(4)
    end

    def dog_into_dog
      pet(Dog.new)
    end

    def scale_ok
      widen(1.5)
    end
  end

  z = Zoo.new
  z.float_into_int
  z.nil_into_int
  z.cat_into_dog
  z.int_into_float
  z.int_into_int
  z.float_or_int(true)
  z.nil_into_nilable
  z.dog_into_dog
  z.scale_ok
RUBY

SIG = <<~RBS
  class Zoo
    def tally_up: (Integer n) -> untyped
    def maybe_count: (Integer n) -> untyped
    def pet: (Dog animal) -> untyped
    def widen: (Float x) -> untyped
    def opt_name: (Integer? n) -> untyped
  end
RBS

diagnostics = Dir.mktmpdir('declared_callsite') do |dir|
  source = File.join(dir, 'fixture.rb')
  File.write(source, SOURCE)
  sig = File.join(dir, 'sig')
  Dir.mkdir(sig)
  File.write(File.join(sig, 'zoo.rbs'), SIG)
  work = File.join(dir, 'work')
  Dir.mkdir(work)
  result = Dir.chdir(dir) do
    TypeCheckRun.run(root: BC2CPP_WORLD_ROOT, mrbc: File.expand_path(suite.mrbc), workdir: work, sources: [source],
                     sends: false, sig_dirs: [sig], display_root: dir)
  end
  facts = JSON.parse(File.read(result.facts_path))
  TypeCheckReport.diagnostics(facts, []).select { |d| d.code == 'TC1018' }
end

lines = diagnostics.map(&:message)
hit = ->(pattern) { lines.grep(pattern) }

check.call('Float into a declared Integer is an error',
           hit.call(/Zoo#tally_up parameter 1: declared Integer, but this call passes Float/).size == 1)
check.call('nil into a non-nilable Integer is an error', hit.call(/Zoo#tally_up .* passes nil/).size == 1)
check.call('another program class into a declared class is an error', hit.call(/Zoo#pet .* passes Cat/).size == 1)
check.call('Integer into a declared Float is an error', hit.call(/Zoo#widen .* passes Integer/).size == 1)
# A declared core class the flow gives its own bit (String here; in the engine mrblib defines it as a program class)
# must compare against that bit, not numeric_class_bit: a String passed to a String parameter is no contradiction.
bits = CodeGen.allocate
check.call('a declared String is the flow\'s STR bit, Array its ARR bit, `T?` adds nil',
           bits.declared_callsite_bits('String', :class, false) == NumericFlow::STR &&
             bits.declared_callsite_bits('Array', :class, true) == (NumericFlow::ARR | NumericFlow::NIL))
check.call('a class the flow gives no bit (TrueClass) is skipped, never claimed', bits.declared_callsite_bits('TrueClass', :class, false).nil?)
check.call('a site that may pass Integer or Float stays silent (maybe, not proven)', hit.call(/Zoo#maybe_count/).empty?)
check.call('nil and Integer into Integer? are silent', hit.call(/Zoo#opt_name/).empty?)
check.call('matching classes are silent (Integer, Dog, Float)',
           lines.none? { |m| m.include?('passes Integer') && m.include?('Zoo#tally_up') } &&
             lines.none? { |m| m.include?('passes Dog') } && lines.none? { |m| m.include?('Zoo#widen') && m.include?('passes Float') })
check.call('every row is an error with the signature location', diagnostics.all? { |d| d.severity == 'error' } &&
                                                                    lines.all? { |m| m.include?('declared at') })
check.call('exactly the four contradictions are reported', diagnostics.size == 4)

suite.finish!

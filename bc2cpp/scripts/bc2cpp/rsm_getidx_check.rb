#!/usr/bin/env ruby
# frozen_string_literal: true

# RSM_GETIDX (codegen_insn.rb): a core body's resumable variant reads `recv[i]` through the shared index helper, whose
# tail is the closed `[]` switch, instead of a by-name `[]` send. A subclass's own `[]` still runs.
#
#   1. generated code: the variants of Array#each, Array#find, Hash#each and String#each_char
#      carry no `[]` send, they call bc2cpp_getidx; BC2CPP_RSM_GETIDX=0 brings the sends back;
#   2. run on a full-core mruby, compiled against interpreted: inside a Fiber, the subclasses' `[]` runs (it logs) and
#      the iterators yield the same values.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/rsm_getidx_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp rsm getidx check')

# [label, fiber body]. Each body runs in its own compiled method, so the iterator takes its resumable variant.
SCENARIOS = [
  ['Array#each on a subclass', 'a = IdxArray[1, 2]; a.each { |x| Fiber.yield x }; $log.dup'],
  ['Array#find on a subclass', 'a = IdxArray[1, 2, 3]; [a.find { |x| Fiber.yield x; x == 2 }, $log.dup]'],
  ['Hash#each on a subclass', 'h = IdxHash.new; h[:a] = 1; h[:b] = 2; h.each { |k, v| Fiber.yield [k, v] }; $log.dup'],
  ['Hash#fetch_values on a subclass', 'h = IdxHash.new; h[:a] = 1; [h.fetch_values(:a) { |k| Fiber.yield k; 0 }, $log.dup]'],
  ['String#each_char on a subclass', 's = IdxString.new("ab"); s.each_char { |c| Fiber.yield c }; $log.dup'],
  ['Array#each on a plain Array', '[3, 4].each { |x| Fiber.yield x }; $log.dup'],
  ['Hash#each on a plain Hash', '{ c: 3 }.each { |k, v| Fiber.yield k }; $log.dup']
].freeze

PROBE = <<~RUBY
  $log = []
  class IdxArray < Array
    def [](i)
      $log << [:array, i]
      super
    end
  end

  class IdxHash < Hash
    def [](k)
      $log << [:hash, k]
      super
    end
  end

  class IdxString < String
    def [](i)
      $log << [:string, i]
      super
    end
  end

  class RsmGetidxProbe
  #{SCENARIOS.each_with_index.map { |(_, body), i| "  def fiber_#{i}\n    Fiber.new { #{body} }\n  end\n" }.join("\n")}
  end
RUBY

DRIVER = "#{Bc2cppStepCheck::SHOW}#{Bc2cppStepCheck::DRAIN}" +
         SCENARIOS.each_with_index.map { |(label, _), i| "$log = []; show('#{label}') { drain(RsmGetidxProbe.new.fiber_#{i}) }" }.join("\n") +
         "\nputs 'end'\n"

OWNERS = %w[Array Hash String Enumerable IdxArray IdxHash IdxString RsmGetidxProbe].freeze

# The variants whose body reads `self[i]`, with the unit that carries them.
VARIANTS = %w[Array_each Array_find Hash_each String_each_char].freeze

# The code of every resumable variant of one core method (its steps and its impl copies).
def variant(code, name)
  code.scan(/^(?:\[\[maybe_unused\]\] )?(?:static )?mrb_value #{name}(?:_\w+)?_rsm\w*\(.*?(?=^(?:\[\[maybe_unused\]\] )?(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

# The `bc2cpp_send` calls of one-argument `[]` in `text`, a part of `code` (which holds the name table).
def index_sends(code, text)
  names = code[/bc2cpp_sym_names\[\d+\] = \{(.*?)\};/m, 1].to_s.scan(/"((?:\\.|[^"\\])*)"/).flatten
  at = names.index('[]')
  at ? text.scan(/bc2cpp_send\(M, r\d+, #{at}, 1, r\d+\)/).size : 0
end

ENV['BC2CPP_RSM_GETIDX'] = '0'
off = suite.generate(PROBE, OWNERS, guards: true)
ENV.delete('BC2CPP_RSM_GETIDX')
code = suite.generate(PROBE, OWNERS, guards: true)

VARIANTS.each do |fn|
  text = variant(code, fn)
  suite.check("#{fn}: the variant is compiled", !text.empty?)
  suite.check("#{fn}: the variant reads `[]` through bc2cpp_getidx", text.include?('bc2cpp_getidx(M, '))
  suite.check("#{fn}: the variant sends no `[]` by name", index_sends(code, text).zero?)
  suite.check("#{fn}: BC2CPP_RSM_GETIDX=0 sends `[]` by name", index_sends(off, variant(off, fn)).positive?)
end

suite.behaviour(DRIVER, same: true) do |_interpreted, compiled|
  next unless compiled

  suite.check('the subclass `[]` runs inside the variant', compiled.any? { |l| l.start_with?('Array#each on a subclass: ') && l.include?(':array') })
end
suite.finish

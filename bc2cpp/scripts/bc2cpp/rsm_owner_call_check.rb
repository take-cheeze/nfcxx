#!/usr/bin/env ruby
# frozen_string_literal: true

# RSM_OWNER_CALL (OutsideOwnerCall#owner_call_world): a core body's resumable variant keeps no static binding of the
# program world, but its by-name sends become the owner call over every definer of the name, so a subclass's own
# definition still runs and the send is no by-name lookup.
#
#   1. generated code: the variants' self sends (`keys`, `length`, `replace`, `__uniq`) are owner calls listing the
#      fixture's subclass, and BC2CPP_RSM_OWNER_CALL=0 brings the by-name sends back;
#   2. run on a full-core mruby, compiled against interpreted: inside a Fiber, the subclass overrides run (they log)
#      and the iterators yield the same values.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/rsm_owner_call_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp rsm owner call check')

# [label, fiber body]. Each body runs in its own compiled method, so the iterator takes its resumable variant.
SCENARIOS = [
  ['Array#each on a subclass', 'a = LogArray[1, 2]; a.each { |x| Fiber.yield x }; $log.dup'],
  ['Array#each_index on a subclass', 'a = LogArray[1, 2]; a.each_index { |i| Fiber.yield i }; $log.dup'],
  ['Array#delete_if on a subclass', 'a = LogArray[1, 2, 3]; a.delete_if { |x| Fiber.yield x; x == 2 }; [a.to_a, $log.dup]'],
  ['Array#uniq on a subclass', 'a = LogArray[1, 1, 2]; [a.uniq { |x| Fiber.yield x; x }, $log.dup]'],
  ['Hash#each on a subclass', 'h = LogHash.new; h[:a] = 1; h[:b] = 2; h.each { |k, v| Fiber.yield [k, v] }; $log.dup'],
  ['Hash#each_key on a subclass', 'h = LogHash.new; h[:a] = 1; h.each_key { |k| Fiber.yield k }; $log.dup'],
  ['Array#each on a plain Array', '[3, 4].each { |x| Fiber.yield x }; $log.dup'],
  ['Hash#each on a plain Hash', '{ c: 3 }.each { |k, v| Fiber.yield k }; $log.dup']
].freeze

PROBE = <<~RUBY
  $log = []
  class LogArray < Array
    def length
      $log << :length
      super
    end

    def replace(other)
      $log << :replace
      super
    end

    def __uniq
      $log << :__uniq
      super
    end
  end

  class LogHash < Hash
    def keys
      $log << :keys
      super
    end
  end

  class RsmOwnerProbe
  #{SCENARIOS.each_with_index.map { |(_, body), i| "  def fiber_#{i}\n    Fiber.new { #{body} }\n  end\n" }.join("\n")}
  end
RUBY

DRIVER = "#{Bc2cppStepCheck::SHOW}#{Bc2cppStepCheck::DRAIN}" +
         SCENARIOS.each_with_index.map { |(label, _), i| "$log = []; show('#{label}') { drain(RsmOwnerProbe.new.fiber_#{i}) }" }.join("\n") +
         "\nputs 'end'\n"

OWNERS = %w[Array Hash Enumerable LogArray LogHash RsmOwnerProbe].freeze

# A step runs to the next function (its body has column-0 braces of its own).
def step(code, name)
  code[/^static mrb_value #{name}_rsm_step\(.*?(?=^(?:\[\[maybe_unused\]\] )?(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

SELF_SENDS = { 'Array_each' => %w[length LogArray], 'Array_each_index' => %w[length LogArray],
               'Array_delete_if' => %w[replace LogArray], 'Array_uniq' => %w[__uniq LogArray],
               'Hash_each' => %w[keys LogHash] }.freeze

ENV['BC2CPP_RSM_OWNER_CALL'] = '0'
off = suite.generate(PROBE, OWNERS, guards: true)
ENV.delete('BC2CPP_RSM_OWNER_CALL')
code = suite.generate(PROBE, OWNERS, guards: true)

SELF_SENDS.each do |fn, (name, sub)|
  text = step(code, fn)
  suite.check("#{fn}: the variant is compiled", !text.empty?)
  suite.check("#{fn}: `#{name}` is an owner call listing #{sub}",
              text.match?(/bc2cpp_owner_call\w*\(M, self, [^\n]*BC2CPP_OWNERS\([^)]*"#{sub}"[^\n]*owner-call: #{Regexp.escape(name)} \*\//))
  suite.check("#{fn}: BC2CPP_RSM_OWNER_CALL=0 sends `#{name}` by name", step(off, fn).include?('bc2cpp_send(M, self, '))
end

suite.behaviour(DRIVER, same: true) do |_interpreted, compiled|
  next unless compiled

  suite.check('the subclass override runs inside the variant', compiled.any? { |l| l.start_with?('Hash#each on a subclass: ') && l.include?(':keys') })
end
suite.finish

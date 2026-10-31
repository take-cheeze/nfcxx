#!/usr/bin/env ruby
# frozen_string_literal: true

# GUARD_FIBER_FREE (tools/bc2cpp/codegen_method.rb, guard_fiber_free?): the Fiber half of CORE_BLOCK_GUARD is dropped for
# a guarded core method that no Fiber.new body reaches, and such a method then keeps no saved bytecode (its mrblib body is
# stubbed, MrblibStubs). The fixture is a core-looking file (its path has /3rd/mruby/mrblib/, which CoreDefs.core_source?
# reads) and a user file whose Fiber body reaches some of its methods:
#
#   fiber_free_fill, fiber_unused_block   not reached from the Fiber body (called from a method nothing calls, or not at all)
#   fiber_reached_each                    called directly by the Fiber body (reached)
#   fiber_dyn_target                      reached through a computed send with a spelled name (crossable_dynamic_targets)
#   Enumerable#fiber_free_enum            an Enumerable method: its guard also tests `each`, so it keeps the guard whatever
#                                         the Fiber reach says
#
# Flag off (and BC2CPP_GUARD_FIBER_FREE set to anything but 1): every guard is emitted and saved, as before. Flag on: only
# the two unreached methods lose their guard, their saved bytecode and their stub (their bodies are no longer kept).
#
# Each run is a bc2cpp.rb run over the fixture with the closed-world probe environment; the generated C++ is on its
# stdout (--annotated), the stub manifest is OUT_DIR/<symbol>_stubs.txt. Needs MRBC (a host mrbc); SKIPs without it.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/guard_fiber_free_check.rb

require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/closed_world_env'

ROOT = File.expand_path('../..', __dir__)
suite = FixtureCheck.new('guard_fiber_free_check')
suite.require_mrbc!

CORE_RB = <<~'RUBY'
  class Array
    def fiber_free_fill(&blk)
      i = 0
      while i < size
        blk.call(self[i]) if blk
        i += 1
      end
      self
    end

    def fiber_unused_block(&blk)
      blk.call(self) if blk
      self
    end

    def fiber_reached_each(&blk)
      i = 0
      while i < size
        yield self[i]
        i += 1
      end
      self
    end

    def fiber_dyn_target(&blk)
      blk.call(self) if blk
      self
    end
  end

  module Enumerable
    def fiber_free_enum(&blk)
      each { |x| blk.call(x) if blk }
      self
    end
  end
RUBY

USER_RB = <<~'RUBY'
  class Driver
    def run_fiber(arr)
      Fiber.new do
        arr.fiber_reached_each { |x| Fiber.yield x }
        arr.__send__(:fiber_dyn_target) { |y| Fiber.yield y }
        arr.fiber_free_enum { |z| Fiber.yield z }
      end
    end

    def root_side
      [3].fiber_free_fill { |x| x }
    end
  end

  # Nothing calls Driver#root_side or Array#fiber_unused_block at load; the Fiber is only created, not resumed.
  Driver.new
RUBY

FREE = %w[Array#fiber_free_fill Array#fiber_unused_block].freeze
GUARDED = %w[Array#fiber_reached_each Array#fiber_dyn_target Enumerable#fiber_free_enum].freeze

# One bc2cpp.rb run over the fixture. +flag+ is the value of BC2CPP_GUARD_FIBER_FREE (nil: unset).
# Returns { code: the generated C++ (stdout), stubs: Set of Owner#name kept out of the residual }.
def run_fixture(mrbc, flag)
  Dir.mktmpdir('guard_fiber_free') do |dir|
    core = File.join(dir, '3rd/mruby/mrblib/fiber_free_core.rb')
    user = File.join(dir, 'fixture.rb')
    FileUtils.mkdir_p(File.dirname(core))
    File.write(core, CORE_RB)
    File.write(user, USER_RB)
    out = File.join(dir, 'out')
    FileUtils.mkdir_p(out)
    env = bc2cpp_closed_world_probe_env({ 'MRBC' => mrbc, 'OUT_SYMBOL' => 'guard_fiber_free', 'OUT_DIR' => out,
                                          'SKIP_UNSUPPORTED' => '1', 'BC2CPP_SELF_REGISTERING' => '1',
                                          'BC2CPP_SIG_DIRS' => '', 'BC2CPP_GUARD_FIBER_FREE' => flag })
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), '--annotated',
                                            core, user, chdir: ROOT)
    abort "bc2cpp.rb failed:\n#{stderr[-3000..] || stderr}" unless status.success?

    stubs_path = File.join(out, 'guard_fiber_free_stubs.txt')
    stubs = File.file?(stubs_path) ? File.read(stubs_path).lines.map(&:strip).reject(&:empty?).to_set : Set.new
    { code: stdout, stubs: stubs }
  end
end

# The C entry of Owner#name in the generated code: its body, and whether its registration saves the bytecode.
# Entry names are Owner_name (a `#` and a `?` or `!` are spelled out by bc2cpp; the fixture names are plain).
def entry_of(code, key)
  owner, name = key.split('#')
  c_name = "#{owner}_#{name}"
  lines = code.lines
  start = lines.index { |l| l.start_with?("static mrb_value #{c_name}(mrb_state* M, mrb_value self) {\n") }
  body = ''
  if start
    stop = start + 1
    stop += 1 until lines[stop].nil? || lines[stop] == "}\n"
    body = lines[start..stop].join
  end
  reg = lines.find { |l| l.include?(", #{c_name}, MRB_ARGS") && l.include?('mrb_define_method(') }.to_s
  { body: body, prologue: body.include?('bc2cpp_core_interpreted(M, self, '),
    saved: reg.include?('bc2cpp_core_save_interpreted('), registered: !reg.empty? }
end

def saves(code) = code.scan('bc2cpp_core_save_interpreted(M, ').size

mrbc = ENV['MRBC']
off = run_fixture(mrbc, nil)
on = run_fixture(mrbc, '1')
zero = run_fixture(mrbc, '0')

puts '  flag unset: every guard emitted and saved'
(FREE + GUARDED).each do |key|
  e = entry_of(off[:code], key)
  suite.check("#{key} keeps its entry hand-off and saved bytecode with the flag unset",
              e[:registered] && e[:prologue] && e[:saved])
end
suite.check('the flag unset keeps every stub out (each guarded body keeps its bytecode)',
            (FREE + GUARDED).none? { |key| off[:stubs].include?(key) })

puts '  BC2CPP_GUARD_FIBER_FREE=0 is the same as unset'
suite.check('a flag value other than 1 changes nothing (saved count and stubs)',
            saves(zero[:code]) == saves(off[:code]) && zero[:stubs] == off[:stubs])

puts '  BC2CPP_GUARD_FIBER_FREE=1'
FREE.each do |key|
  e = entry_of(on[:code], key)
  suite.check("#{key} is not reached from the Fiber body: no entry hand-off, no saved bytecode",
              e[:registered] && !e[:prologue] && !e[:saved])
  suite.check("#{key} keeps no bytecode (stubbed)", on[:stubs].include?(key))
end
GUARDED.each do |key|
  e = entry_of(on[:code], key)
  suite.check("#{key} stays guarded: entry hand-off and saved bytecode kept", e[:registered] && e[:prologue] && e[:saved])
  suite.check("#{key} keeps its bytecode (not stubbed)", !on[:stubs].include?(key))
end
suite.check('the Enumerable guard still tests that each is the builtin one',
            entry_of(on[:code], 'Enumerable#fiber_free_enum')[:body].include?('bc2cpp_core_each_is_builtin(M, self)'))
suite.check('two fewer saved-bytecode registrations than with the flag unset',
            saves(on[:code]) == saves(off[:code]) - FREE.size)

suite.finish!

#!/usr/bin/env ruby
# frozen_string_literal: true

# LEXICAL_CONST joins (ADR 0423, tools/bc2cpp/lexical_consts.rb): the holder of a `Holder::NAME` read, a superclass and
# a mixin argument are each read from the register the ternary arms write. A `c ? A : B` join gives one writer per arm,
# so each question must hold for every arm, or the answer is no key. Each fixture is compiled by the host mrbc and its
# reads are checked. Needs MRBC (a host mrbc); without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/lexical_join_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/lexical_consts'

mrbc = ENV['MRBC']
unless mrbc && File.executable?(mrbc)
  puts 'SKIP lexical_join_check: MRBC is not set to a host mrbc'
  exit 0
end

failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# [op, name, key] of every GETCONST/GETMCNST read of the fixture, in instruction order of each irep.
reads_of = lambda do |source|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'fixture.rb')
    File.write(path, source)
    ireps, _root = compile_ireps([path], 'lexical_join', dir)
    info = LexicalConsts.analyze(ireps, static: true)
    reads = []
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        reads << [insn.op, insn.const_name, info.read_keys[insn]] if %w[GETCONST GETMCNST].include?(insn.op)
      end
    end
    reads
  end
end

puts '== a scoped read through a ternary holder'
holder = reads_of.call(<<~RUBY)
  module A2; X = 1; end
  module B2; X = 2; end
  c = Time.now.year > 0
  def pick; (c ? A2 : B2)::X; end
RUBY
check.call('(c ? A2 : B2)::X is refused: the arms name different holders, and A2::X is reachable',
           holder.include?(['GETMCNST', 'X', nil]) && !holder.include?(['GETMCNST', 'X', 'B2::X']))

agree = reads_of.call(<<~RUBY)
  module A3; X = 1; end
  module B3; X = 2; end
  c = Time.now.year > 0
  def pick; (c ? A3 : A3)::X; end
RUBY
check.call('(c ? A3 : A3)::X resolves: both arms name A3, so the holder is one definition',
           agree.include?(['GETMCNST', 'X', 'A3::X']))

puts '== a superclass that is a ternary'
super_arm = reads_of.call(<<~RUBY)
  class B0; W = 2; end
  W = 1
  c = Time.now.year > 0
  class S0 < (c ? B0 : nil)
    def f; W; end
  end
RUBY
check.call('W in S0 is refused: the superclass arm B0 supplies B0::W ahead of the top-level W',
           super_arm.include?(['GETCONST', 'W', nil]) && !super_arm.include?(['GETCONST', 'W', 'W']))

puts '== a mixin argument that is a ternary'
mixin_arm = reads_of.call(<<~RUBY)
  U = 0
  module A1; U = 1; end
  module B1; end
  c = Time.now.year > 0
  class C1
    include(c ? A1 : B1)
    def f; U; end
  end
RUBY
check.call('U in C1 is refused: the included arm A1 supplies A1::U ahead of the top-level U',
           mixin_arm.include?(['GETCONST', 'U', nil]) && !mixin_arm.include?(['GETCONST', 'U', 'U']))

mixin_agree = reads_of.call(<<~RUBY)
  U = 0
  module B4; end
  c = Time.now.year > 0
  class C4
    include(c ? B4 : B4)
    def f; U; end
  end
RUBY
check.call('U in C4 resolves when both arms include B4 (a module that does not define U)',
           mixin_agree.include?(['GETCONST', 'U', 'U']))

if failures.empty?
  puts "lexical_join_check: #{checks} checks passed"
else
  puts "lexical_join_check: #{failures.size} failure(s)"
  exit 1
end

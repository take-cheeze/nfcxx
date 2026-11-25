#!/usr/bin/env ruby
# frozen_string_literal: true

# FIXED_TUPLE (tools/bc2cpp/codegen_fixed_tuples.rb): a destructuring AREF of an Array of proven length reads the
# element directly, with no Array test, bounds check or nil fallback.
#
# 1. With MRBC: the generated code of a closed-world fixture. Positive cases (a call whose every definition returns a
#    fresh pair, a literal destructured straight away, an index past the length, a join of literals of two lengths
#    that is still an Array) must take the direct read; refused cases (a second definition of another length, a
#    length-changing op on the Array before the destructure, a parameter, a reused Array, a block `return`, the
#    BC2CPP_FIXED_TUPLE=0 kill switch) must keep the checked read.
# 2. With a full-core libmruby (BC2CPP_MRUBY_FULL or BC2CPP_FULL_BUILD_DIR) and g++: the fixture runs interpreted and
#    compiled and must answer alike, plain and with BC2CPP_CLASS_REACH_VERIFY (the per-read length check) defined.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/fixed_tuple_check.rb

ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~RUBY
  class FtBox
    def initialize
      @n = 3
      @out = [0, 0]
    end

    def ft_pair(a)
      [a + 1, a * 2]
    end

    def ft_pair_use
      x, y = ft_pair(@n)
      x + y
    end

    def ft_beyond
      x, y, z = ft_pair(@n)
      [x, y, z]
    end

    def ft_poly_use(o)
      x, y = o.ft_pair(1)
      [x, y]
    end

    def ft_lit_use(a, b)
      @last = (x, y = [b, a])
      [x, y]
    end

    def ft_join_use(f)
      x, y = (f ? [1, 2] : [3, 4, 5])
      [x, y]
    end

    def ft_arity(a)
      [a, a]
    end

    def ft_arity_use
      x, y = ft_arity(@n)
      [x, y]
    end

    def ft_push_use
      t = ft_pair(@n)
      t << 9
      x, y, z = t
      [x, y, z]
    end

    def ft_param_use(t)
      x, y = t
      [x, y]
    end

    def ft_reused
      @out[0] = @n
      @out[1] = @n + 1
      @out
    end

    def ft_reused_use
      x, y = ft_reused
      [x, y]
    end

    def ft_run
      yield
    end

    def ft_blockret(a)
      ft_run { return [a] }
      [a, a]
    end

    def ft_blockret_use
      x, y = ft_blockret(@n)
      [x, y]
    end
  end

  class FtOther
    def ft_arity(a)
      [a, a, a]
    end
  end

  class FtDrv
    def ft_go
      b = FtBox.new
      [b.ft_pair_use, b.ft_beyond, b.ft_poly_use(b), b.ft_lit_use(1, 2), b.ft_join_use(true), b.ft_join_use(false), b.ft_arity_use,
       FtOther.new.ft_arity(1), b.ft_push_use, b.ft_param_use([7, 8]), b.ft_param_use(5), b.ft_param_use([1]),
       b.ft_reused_use, b.ft_blockret_use]
    end
  end
RUBY

OWNERS = %w[FtBox FtOther FtDrv].freeze

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC)'
  exit 0
end

generate = lambda do |env = {}|
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(FIXTURE, dir, only_owners: OWNERS) }
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
chunk_of = lambda do |code, owner_method|
  code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
end
checked_read = /mrb_array_p\(r\d+\) \? bc2cpp_ary_entry/

puts '-- generated code (closed world)'
# MULTI_RETURN would turn a direct self call's destructure into a buffer and leave no AREF to look at.
plain = { 'BC2CPP_MULTI_RETURN' => '0' }
code, = generate.call(plain)
direct = lambda do |method, count|
  chunk = chunk_of.call(code, method)
  !chunk.empty? && chunk.scan('/* FIXED_TUPLE */').size == count && !chunk.match?(checked_read)
end
# A refused read keeps its bounds check: the checked AREF, or the plain element read of a proven Array.
kept = lambda do |method|
  chunk = chunk_of.call(code, method)
  !chunk.empty? && !chunk.include?('/* FIXED_TUPLE */') &&
    (chunk.match?(checked_read) || chunk.include?('/* FIXED_TUPLE Array */'))
end

check.call('a call whose every definition returns a fresh pair reads both elements directly',
           direct.call('FtBox#ft_pair_use', 2))
check.call('so does a call on a receiver of unknown class', direct.call('FtBox#ft_poly_use', 2))
check.call('an index past the proven length is nil without a read',
           direct.call('FtBox#ft_beyond', 2) && chunk_of.call(code, 'FtBox#ft_beyond').include?('FIXED_TUPLE 2 >= 2'))
check.call('a literal kept as the masgn value reads both elements directly', direct.call('FtBox#ft_lit_use', 2))
join = chunk_of.call(code, 'FtBox#ft_join_use')
check.call('a join of literals of two lengths keeps the bounds check but drops the Array test',
           join.include?('/* FIXED_TUPLE Array */') && !join.include?('/* FIXED_TUPLE */') && !join.match?(checked_read))
check.call('the helper checks class and length in a CLASS_REACH_VERIFY build',
           code[/static inline mrb_value bc2cpp_tuple_entry\(.*?^\}/m].to_s.include?('#ifdef BC2CPP_CLASS_REACH_VERIFY'))
check.call('NEG: a second definition of another length keeps the bounds check', kept.call('FtBox#ft_arity_use'))
check.call('NEG: a push between the call and the destructure keeps the bounds check', kept.call('FtBox#ft_push_use'))
check.call('NEG: a reused ivar Array keeps the bounds check', kept.call('FtBox#ft_reused_use'))
check.call('NEG: a block `return` of another length keeps the bounds check', kept.call('FtBox#ft_blockret_use'))
check.call('NEG: a parameter (unknown producer) keeps the checked read',
           kept.call('FtBox#ft_param_use') && chunk_of.call(code, 'FtBox#ft_param_use').match?(checked_read))

off, = generate.call(plain.merge('BC2CPP_FIXED_TUPLE' => '0'))
check.call('BC2CPP_FIXED_TUPLE=0 emits no direct read and no helper',
           !off.include?('FIXED_TUPLE') && !off.include?('bc2cpp_tuple_entry') &&
             chunk_of.call(off, 'FtBox#ft_pair_use').match?(checked_read))

build = Bc2cppFixtureRuntime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? Bc2cppFixtureRuntime.full_or_build : nil)
if ENV['FT_GENERATED_ONLY'] || build.nil? || !Bc2cppFixtureRuntime.compiler?
  puts '  SKIP run: set BC2CPP_MRUBY_FULL or BC2CPP_FULL_BUILD_DIR (a full-core libmruby) and have g++'
else
  body = <<~CPP
    static int scenario(mrb_state* M) {
      mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "FtDrv"), 0, nullptr);
      call(M, "driver", drv, "ft_go");
      mrb_full_gc(M);
      call(M, "driver again", drv, "ft_go");
      return 0;
    }
  CPP
  [['plain', ''], ['CLASS_REACH_VERIFY', '-DBC2CPP_CLASS_REACH_VERIFY']].each do |label, flags|
    puts "-- fixture on real mruby (#{label}), interpreted and compiled"
    saved = ENV.values_at('BC2CPP_CXXFLAGS', 'BC2CPP_MULTI_RETURN')
    ENV['BC2CPP_CXXFLAGS'] = flags
    ENV['BC2CPP_MULTI_RETURN'] = '0'
    begin
      Dir.mktmpdir do |dir|
        _c, err = Bc2cppFixtureRuntime.generate(FIXTURE, dir, only_owners: OWNERS)
        built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true)
        check.call("#{label}: the fixture compiles and runs", built)
        puts output unless built
        next unless built

        sections = Bc2cppFixtureRuntime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        same = values.call('interpreted').size == 2 && values.call('interpreted') == values.call('compiled')
        check.call("#{label}: the compiled driver answers what the interpreter answers", same)
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || !same
      end
    ensure
      %w[BC2CPP_CXXFLAGS BC2CPP_MULTI_RETURN].zip(saved).each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end
end

if failures.empty?
  puts 'bc2cpp fixed tuple check: PASS'
else
  warn "bc2cpp fixed tuple check: #{failures.size} failure(s)"
  exit 1
end

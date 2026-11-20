#!/usr/bin/env ruby
# frozen_string_literal: true

# SCOPED_CONSTANT_WRITES (block_self_world.rb assignment_may_reach?): `Hash.new { }` / `Array.new(n) { }` are
# Class/Module/Struct factory sends (whose block runs as a class body, under another self) only when the constant may
# name such a class. A Ruby write of the same simple name used to count wherever it was (rbs's mrblib assigns
# RBS::BuiltinNames::Hash, ::Array, ...), which made every such block "rebound" and kept its method on the interpreter.
# A write now counts only where mruby's constant lookup can find it: on the read's lexical chain, in Object, or in a
# module some class may have as an ancestor (a mixin argument, a superclass, a module a native source names).
#
# The fixture writes ScwNames::Hash and ScwNames::Array (never mixed in): ScwUser's reads of Hash and Array outside it
# compile, with captured locals. ScwNames::Reader reads ScwNames::Hash (a Struct) lexically, and ScwIncluder reads
# ScwMix::Maker (a Struct) through its ancestors: both stay interpreted. ScwMix also writes Proc, so every bare Proc read
# is a possible factory once ScwMix is mixed in (mruby finds ::Proc first, on the top-level end of the lexical chain, but
# the proof does not order the chain before the ancestors): ScwUser#adder stays interpreted too. All of them behave as
# the interpreter does. The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('scoped_constant_writes_check')
suite.require_mrbc!

# The analysis alone, in worlds whose fact holds (no compiled block checks its self there): [holds?, rebound blocks].
analyze = lambda do |source|
  Dir.mktmpdir('bc2cpp-scoped-writes-world') do |dir|
    path = File.join(dir, 'world.rb')
    File.write(path, source)
    native = File.join(dir, 'native.c')
    File.write(native, "int scw_native(void) { return 0; }\n")
    ireps, = compile_ireps([path], 'scoped_writes', dir)
    world = BlockSelfWorld.analyze(ireps: ireps, native_paths: [native])
    [world.holds?, world.rebound.size]
  end
end
WRITER = "module ScwW; Hash = Struct; end\n"
USER = "class ScwU; def g(x) = Hash.new { |h, k| h[k] = x }; end\n"
suite.check('a world that holds: a Hash.new block outside the writing module is not rebound',
            analyze.call(WRITER + USER) == [true, 0])
suite.check('a world that holds: the read inside the writing module is',
            analyze.call("module ScwW; Hash = Struct; class R; def g = Hash.new { 1 }; end; end\n") == [true, 1])
suite.check('a world that holds: a mixed-in writing module makes it rebound',
            analyze.call("#{WRITER}class ScwI; include ScwW; end\n#{USER}") == [true, 1])
suite.check('a world that holds: an alias_method with an unproven name makes it rebound',
            analyze.call("#{WRITER}class ScwA; def self.n = :x; alias_method :y, n; end\n#{USER}") == [true, 1])

SOURCE = <<~RUBY
  module ScwNames
    Hash = Struct
    Array = Struct
    class Reader
      def make(n)
        Hash.new(:a) { def twice = a * 2 }.new(n).twice
      end
    end
  end
  module ScwMix
    Maker = Struct
    Proc = Struct
  end
  class ScwIncluder
    include ScwMix
    def make(n)
      Maker.new(:b) { def thrice = b * 3 }.new(n).thrice
    end
  end
  class ScwUser
    def groups(words, extra)
      out = Hash.new { |h, k| h[k] = [extra] }
      words.each { |w| out[w.size] << w }
      out.keys.sort.map { |k| [k, out[k]] }
    end

    def squares(n, base)
      Array.new(n) { |i| i * i + base }
    end

    def adder(base)
      Proc.new { |x| x + base }.call(1)
    end
  end
RUBY

OWNERS = %w[ScwNames ScwNames::Reader ScwMix ScwIncluder ScwUser].freeze

def compiled?(code, name)
  code.match?(/^(?:static )?mrb_value #{name}\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-scoped-constant-writes') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('Hash.new and Array.new blocks outside the writing module compile',
              compiled?(code, 'ScwUser_groups_impl') && compiled?(code, 'ScwUser_squares_impl'))
  suite.check('a read on the writing module\'s lexical chain stays interpreted', !compiled?(code, 'ScwNames_Reader_make_impl'))
  suite.check('a write in a mixed-in module keeps every read of its name interpreted',
              !compiled?(code, 'ScwIncluder_make_impl') && !compiled?(code, 'ScwUser_adder_impl'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP scoped constant writes behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value scw_new(mrb_state* M, struct RClass* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(cls), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value u = scw_new(M, mrb_class_get(M, "ScwUser"));
        mrb_value words = mrb_ary_new(M);
        for (const char* w : {"a", "bb", "cc", "d", "eee"}) mrb_ary_push(M, words, mrb_str_new_cstr(M, w));
        mrb_value gargs[] = {words, mrb_str_new_lit(M, "x")};
        call(M, "groups", u, "groups", 2, gargs);
        mrb_value sargs[] = {mrb_fixnum_value(4), mrb_fixnum_value(10)};
        call(M, "squares", u, "squares", 2, sargs);
        mrb_value base = mrb_fixnum_value(41);
        call(M, "adder", u, "adder", 1, &base);
        mrb_value n = mrb_fixnum_value(21);
        call(M, "reader", scw_new(M, mrb_class_get_under(M, mrb_module_get(M, "ScwNames"), "Reader")), "make", 1, &n);
        mrb_value m = mrb_fixnum_value(14);
        call(M, "includer", scw_new(M, mrb_class_get(M, "ScwIncluder")), "make", 1, &m);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter groups, squares and runs the Struct bodies',
                interpreted.include?('groups => [[1, ["x", "a", "d"]], [2, ["x", "bb", "cc"]], [3, ["x", "eee"]]]') &&
                interpreted.include?('squares => [10, 11, 14, 19]') &&
                interpreted.include?('adder => 42') &&
                interpreted.include?('reader => 42') && interpreted.include?('includer => 42'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!

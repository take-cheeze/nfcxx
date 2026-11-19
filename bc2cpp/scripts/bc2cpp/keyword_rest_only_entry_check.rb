#!/usr/bin/env ruby
# frozen_string_literal: true

# KEYWORD_REST_ONLY entry (codegen_method.rb, the kwrest_only wrapper): a compiled method whose only keyword parameter
# is `**opts` is entered from the VM with its keywords in the callinfo's keyword slot. The wrapper binds the
# positionals and reads that slot; the check runs such methods, with and without mandatory positionals, interpreted and
# compiled (and, beside them, `b = 5, **opts` and `b = 1, *rest, **opts`; `a, *rest, **opts`
# stays interpreted), through calls the VM dispatches (two definers of the name, so no direct call): keywords given, none given,
# a trailing Hash, and arity errors.
# Needs MRBC; the behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('keyword_rest_only_entry_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class KrA
    def one(a, **o)
      [:a, a, o]
    end
    def none(**o)
      [:a, o]
    end
    def two(a, b, **o)
      [:a, a, b, o]
    end
    def rest(a, *r, **o)
      [:a, a, r, o]
    end
    def opt(a, b = 5, **o)
      [:a, a, b, o]
    end
    def rest0(a, b = 1, *r, **o)
      [:a, a, b, r, o]
    end
  end

  class KrB
    def one(a, **o)
      [:b, a, o]
    end
    def none(**o)
      [:b, o]
    end
    def two(a, b, **o)
      [:b, a, b, o]
    end
    def rest(a, *r, **o)
      [:b, a, r, o]
    end
    def opt(a, b = 5, **o)
      [:b, a, b, o]
    end
    def rest0(a, b = 1, *r, **o)
      [:b, a, b, r, o]
    end
  end

  class KrDrive
    def one_kw(r) = r.one(1, k: 2, j: 3)
    def one_plain(r) = r.one(1)
    def one_hash(r) = r.one(1, {h: 4})
    def one_arity(r) = r.one(k: 2)
    def none_kw(r) = r.none(k: 2)
    def none_plain(r) = r.none
    def none_arity(r) = r.none(1, k: 2)
    def two_kw(r) = r.two(1, 2, k: 3)
    def two_arity(r) = r.two(1, k: 3)
    def rest_kw(r) = r.rest(1, 2, 3, k: 4)
    def rest_plain(r) = r.rest(1, 2)
    def rest_arity(r) = r.rest(k: 4)
    def opt_kw(r) = r.opt(1, k: 4)
    def opt_full(r) = r.opt(1, 2, k: 4)
    def opt_plain(r) = r.opt(1)
    def opt_arity(r) = r.opt(1, 2, 3, k: 4)
    def rest0_kw(r) = r.rest0(1, 2, 3, k: 4)
    def rest0_opt(r) = r.rest0(1, k: 4)
    def rest0_plain(r) = r.rest0(1)
    def rest0_arity(r) = r.rest0(k: 4)
  end
RUBY

OWNERS = %w[KrA KrB KrDrive].freeze
CASES = %w[one_kw one_plain one_hash one_arity none_kw none_plain none_arity two_kw two_arity rest_kw rest_plain rest_arity opt_kw opt_full opt_plain
           opt_arity rest0_kw rest0_opt rest0_plain rest0_arity].freeze

Dir.mktmpdir('bc2cpp-keyword-rest-only-entry') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('every **opts-only method is a compiled entry point',
              %w[KrA KrB].product(%w[one none two opt rest0]).all? { |c, m| err.include?("(#{c}##{m}, ") })
  suite.check('the generated source has the keyword-rest-only entries', code.include?('KrA_one'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP keyword rest only behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    calls = %w[KrA KrB].flat_map do |cls|
      CASES.map { |m| "  call(M, \"#{m}_#{cls}\", d, \"#{m}\", 1, &#{cls.downcase});\n" }
    end.join
    scenario = <<~CPP
      static mrb_value kr_new(mrb_state* M, const char* cls) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, cls)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value d = kr_new(M, "KrDrive");
        mrb_value kra = kr_new(M, "KrA");
        mrb_value krb = kr_new(M, "KrB");
      #{calls}  return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('every call ran', interpreted.size == 2 * CASES.size)
    expected = %w[a b].flat_map do |t|
      cls = "Kr#{t.upcase}"
      ["one_kw_#{cls} => [:#{t}, 1, {k: 2, j: 3}]", "one_plain_#{cls} => [:#{t}, 1, {}]",
       "one_hash_#{cls} => raised ArgumentError", "one_arity_#{cls} => raised ArgumentError",
       "none_kw_#{cls} => [:#{t}, {k: 2}]", "none_plain_#{cls} => [:#{t}, {}]",
       "none_arity_#{cls} => raised ArgumentError", "two_kw_#{cls} => [:#{t}, 1, 2, {k: 3}]",
       "two_arity_#{cls} => raised ArgumentError", "rest_kw_#{cls} => [:#{t}, 1, [2, 3], {k: 4}]",
       "rest_plain_#{cls} => [:#{t}, 1, [2], {}]", "rest_arity_#{cls} => raised ArgumentError",
       "opt_kw_#{cls} => [:#{t}, 1, 5, {k: 4}]", "opt_full_#{cls} => [:#{t}, 1, 2, {k: 4}]",
       "opt_plain_#{cls} => [:#{t}, 1, 5, {}]", "opt_arity_#{cls} => raised ArgumentError",
       "rest0_kw_#{cls} => [:#{t}, 1, 2, [3], {k: 4}]", "rest0_opt_#{cls} => [:#{t}, 1, 1, [], {k: 4}]",
       "rest0_plain_#{cls} => [:#{t}, 1, 1, [], {}]", "rest0_arity_#{cls} => raised ArgumentError"]
    end
    suite.check('the interpreter gives the expected answers', interpreted == expected)
    puts "  interpreted: #{interpreted.inspect}" unless interpreted == expected
    suite.check('compiled matches interpreted', compiled == interpreted)
    puts "  compiled: #{compiled.inspect}" unless compiled == interpreted
  end
end

suite.finish!

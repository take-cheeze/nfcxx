#!/usr/bin/env ruby
# frozen_string_literal: true

# METHOD_MISSING_ARMS (closed_world.rb, method_missing_arm_classes; codegen_send.rb, method_missing_arm_branches): a
# send whose receiver class is not proven used to keep dispatching by name (:method_missing_receiver) whenever the
# program defines any method_missing, since such a receiver would answer instead of raising. Each method_missing class
# (and each subclass inheriting it) now takes an exact-class arm that sends by name, so the else arm closes for every
# other receiver. The check reads the site and, with a full-core libmruby, runs it interpreted and compiled: the two
# definers, a method_missing class and its subclass, an object with a singleton class, and a receiver that raises.
# Needs MRBC; the behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('method_missing_arms_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class MaA
    def look(x) = [:a, x]
  end

  class MaB
    def look(x) = [:b, x]
  end

  class MaGhost
    def method_missing(name, *args) = [:ghost, name, args]
    def respond_to_missing?(name, priv = false) = true
  end

  class MaKidGhost < MaGhost
  end

  class MaUser
    def t(o) = o.look(1)
    def all(xs) = xs.map { |x| t(x) }
  end
RUBY

OWNERS = %w[MaA MaB MaGhost MaKidGhost MaUser].freeze

def user_method(code, name)
  code[/^mrb_value MaUser_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?(?:\[\[maybe_unused\]\] )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

Dir.mktmpdir('bc2cpp-method-missing-arms') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  body = user_method(code, 't')
  suite.check('each method_missing class takes an exact-class arm',
              body.include?('METHOD_MISSING_ARM MaGhost') && body.include?('METHOD_MISSING_ARM MaKidGhost'))
  suite.check('the site no longer keeps dispatching for a method_missing receiver',
              !body.include?('CLOSED_WORLD kept: method_missing_receiver') && !body.empty?)

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP method missing arms behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value ma_new(mrb_state* M, const char* name) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, name)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value u = ma_new(M, "MaUser");
        const char* names[] = { "MaA", "MaB", "MaGhost", "MaKidGhost" };
        for (const char* n : names) {
          mrb_value o = ma_new(M, n);
          call(M, n, u, "t", 1, &o);
        }
        mrb_value g = ma_new(M, "MaGhost");
        mrb_funcall_argv(M, g, mrb_intern_lit(M, "singleton_class"), 0, nullptr);
        call(M, "ghost_singleton", u, "t", 1, &g);
        mrb_value one = mrb_fixnum_value(1);
        call(M, "integer", u, "t", 1, &one);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    expected = ['MaA => [:a, 1]', 'MaB => [:b, 1]', 'MaGhost => [:ghost, :look, [1]]', 'MaKidGhost => [:ghost, :look, [1]]',
                'ghost_singleton => [:ghost, :look, [1]]', 'integer => raised NoMethodError']
    suite.check('the interpreter gives the expected answers', interpreted == expected)
    puts "  interpreted: #{interpreted.inspect}" unless interpreted == expected
    suite.check('compiled matches interpreted', compiled == interpreted)
    puts "  compiled: #{compiled.inspect}" unless compiled == interpreted
  end
end

suite.finish!

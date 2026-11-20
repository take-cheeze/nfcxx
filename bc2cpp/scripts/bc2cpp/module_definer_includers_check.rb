#!/usr/bin/env ruby
# frozen_string_literal: true

# MODULE_DEFINER_INCLUDERS (closed_world.rb, module_definer_includers): a module's instance method reaches only the
# instances of the classes that include or prepend it in a class body (directly or through another module), so such a
# definer adds those classes to a send's receiver set instead of making the name opaque. A module nothing includes
# (a `module_function` helper) adds none. A module's own singleton method still answers only for the module object,
# and a `:clone` that is only listed (CLONE_SYMBOL_PROOF) changes nothing. A module some unresolved or root mixin could take stays opaque. The check
# reads the sites and, with a full-core libmruby, runs them interpreted and compiled.
# Needs MRBC; the behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('module_definer_includers_check')
suite.require_mrbc!

def source(object_include)
  <<~RUBY
    module McUtil
      module_function

      def scan(x) = x + 1
    end

    module McSolo
      def self.tag = :solo
      def self.copy?(m) = %i[clone dup].include?(m)
    end

    class McTag
      def tag = :tag
    end

    module McMix
      def label = :mix
    end

    module McOuter
      include McMix
    end

    class McA
      include McMix
      def scan(x) = x * 2
    end

    class McC
      include McOuter
    end

    class McB
      def label = :b
    end

    class McUser
      def s(o) = o.scan(3)
      def l(o) = o.label
      def u = McUtil.scan(1)
      def t(o) = o.tag
    end
    #{object_include ? 'Object.include(McMix)' : ''}
  RUBY
end

OWNERS = %w[McA McB McC McUser McMix McOuter McUtil McSolo McTag].freeze

def user_method(code, name)
  code[/^mrb_value McUser_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?(?:\[\[maybe_unused\]\] )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

# The owner call's list names the definers it looks the method up in.
def owner_call_names?(body, name, owners)
  line = body.lines.find { |l| l.include?("/* CLOSED_WORLD owner-call: #{name} */") }
  !line.nil? && owners.all? { |o| line.include?(%("#{o}")) }
end

Dir.mktmpdir('bc2cpp-module-definer-includers') do |dir|
  plain_dir = File.join(dir, 'plain')
  Dir.mkdir(plain_dir)
  code, err = Bc2cppFixtureRuntime.generate(source(false), plain_dir, core: true, only_owners: OWNERS)
  suite.check("a module_function module's instance copy keeps no send dispatching",
              owner_call_names?(user_method(code, 's'), 'scan', %w[McA McUtil]))
  suite.check("an included module's method binds through its includers, also through another module",
              owner_call_names?(user_method(code, 'l'), 'label', %w[McB McMix]))
  suite.check('no site keeps dispatching for an opaque definer', err.lines.none? { |l| l.match?(/^\s+KEPT opaque_definer:/) })

  root_dir = File.join(dir, 'root')
  Dir.mkdir(root_dir)
  root_code, = Bc2cppFixtureRuntime.generate(source(true), root_dir, core: true, only_owners: OWNERS)
  suite.check('a module Object includes keeps its names dispatching by name',
              !user_method(root_code, 'l').include?('/* CLOSED_WORLD owner-call: label */') && !user_method(root_code, 'l').empty?)

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP module definer includers behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value mc_new(mrb_state* M, const char* name) {
        return mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, name)), mrb_intern_lit(M, "new"), 0, nullptr);
      }
      static int scenario(mrb_state* M) {
        mrb_value u = mc_new(M, "McUser");
        mrb_value a = mc_new(M, "McA");
        mrb_value b = mc_new(M, "McB");
        mrb_value c = mc_new(M, "McC");
        call(M, "s_a", u, "s", 1, &a);
        call(M, "s_b", u, "s", 1, &b);
        call(M, "l_a", u, "l", 1, &a);
        call(M, "l_b", u, "l", 1, &b);
        call(M, "l_c", u, "l", 1, &c);
        call(M, "u", u, "u", 0, nullptr);
        mrb_value solo = mrb_obj_value(mrb_module_get(M, "McSolo"));
        mrb_value tag = mc_new(M, "McTag");
        call(M, "t_solo", u, "t", 1, &solo);
        call(M, "t_tag", u, "t", 1, &tag);
        call(M, "t_a", u, "t", 1, &a);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(plain_dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    expected = ['s_a => 6', 's_b => raised NoMethodError', 'l_a => :mix', 'l_b => :b', 'l_c => :mix', 'u => 2', 't_solo => :solo',
                't_tag => :tag', 't_a => raised NoMethodError']
    suite.check('the interpreter gives the expected answers', interpreted == expected)
    puts "  interpreted: #{interpreted.inspect}" unless interpreted == expected
    suite.check('compiled matches interpreted', compiled == interpreted)
    puts "  compiled: #{compiled.inspect}" unless compiled == interpreted
  end
end

suite.finish!

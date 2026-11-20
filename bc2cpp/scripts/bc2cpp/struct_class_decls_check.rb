#!/usr/bin/env ruby
# frozen_string_literal: true

# STRUCT_CLASS_DECLS (closed_world.rb, struct_class?): a class- or top-level `X = Struct.new(:a, ...)` runs once,
# before main, and its members are definers the registry lists for X. The closed world declares X as a class below
# Struct, so a member read or a method of X's block binds through a closed-world owner call naming X, where before the
# members were unknown definers and every send of a member name kept dispatching by name. A struct constant written
# twice stays rebound, its members unknown definers; another namespace's constant of the same bare name does not
# rebind it (QUALIFIED_REBINDS). The check reads both programs' sites and, with a full-core libmruby, runs the literal one
# interpreted and compiled: member readers and writers, the block's method, and another class answering the same names.
# Needs MRBC; the behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('struct_class_decls_check')
suite.require_mrbc!

def source(second_write, other_point: false)
  <<~RUBY
    #{other_point ? "module ScOther\n  Point = Struct.new(:qq)\nend" : ''}
    module ScGame
      Point = Struct.new(:px, :py) do
        def sum = px + py
      end
      #{second_write ? 'Point = Struct.new(:px, :py)' : ''}
      class Other
        def px = 10
        def py=(v)
          v
        end
        def sum = 0
      end
      class User
        def gx(p) = p.px
        def gs(p) = p.sum
        def sy(p, v)
          p.py = v
        end
      end
    end
  RUBY
end

OWNERS = %w[ScGame::User ScGame::Other].freeze

def user_method(code, name)
  code[/^mrb_value ScGame__User_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?(?:\[\[maybe_unused\]\] )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

def owner_call?(body, name)
  body.include?("/* CLOSED_WORLD owner-call: #{name} */") && body.include?('"ScGame::Point"')
end

Dir.mktmpdir('bc2cpp-struct-class-decls') do |dir|
  literal_dir = File.join(dir, 'literal')
  Dir.mkdir(literal_dir)
  code, err = Bc2cppFixtureRuntime.generate(source(false), literal_dir, core: true, only_owners: OWNERS)
  suite.check('no site keeps dispatching for an unknown or opaque definer',
              err.lines.none? { |l| l.match?(/^\s+KEPT (unknown_definer|opaque_definer):/) })
  suite.check('a member read is an owner call naming the struct class', owner_call?(user_method(code, 'gx'), 'px'))
  suite.check("the struct block's method is an owner call naming the struct class", owner_call?(user_method(code, 'gs'), 'sum'))
  suite.check('a member write is an owner call naming the struct class', owner_call?(user_method(code, 'sy'), 'py='))

  rebound_dir = File.join(dir, 'rebound')
  Dir.mkdir(rebound_dir)
  rebound_code, = Bc2cppFixtureRuntime.generate(source(true), rebound_dir, core: true, only_owners: OWNERS)
  suite.check("a struct constant written twice keeps its members' sends dispatching by name",
              %w[gx sy].all? { |m| user_method(rebound_code, m).include?('/* CLOSED_WORLD kept: unknown_definer */') })

  # QUALIFIED_REBINDS: ScOther::Point is another constant; writing it rebinds neither ScGame::Point nor its members.
  other_dir = File.join(dir, 'other')
  Dir.mkdir(other_dir)
  other_code, = Bc2cppFixtureRuntime.generate(source(false, other_point: true), other_dir, core: true, only_owners: OWNERS)
  suite.check("another module's constant of the same bare name leaves the struct class declared",
              owner_call?(user_method(other_code, 'gx'), 'px'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP struct class decls behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static mrb_value sc_class(mrb_state* M, const char* name) {
        return mrb_obj_value(mrb_class_get_under(M, mrb_module_get(M, "ScGame"), name));
      }
      static int scenario(mrb_state* M) {
        mrb_value u = mrb_funcall_argv(M, sc_class(M, "User"), mrb_intern_lit(M, "new"), 0, nullptr);
        mrb_value pv[] = {mrb_fixnum_value(3), mrb_fixnum_value(4)};
        mrb_value p = mrb_funcall_argv(M, sc_class(M, "Point"), mrb_intern_lit(M, "new"), 2, pv);
        mrb_value o = mrb_funcall_argv(M, sc_class(M, "Other"), mrb_intern_lit(M, "new"), 0, nullptr);
        call(M, "gx_point", u, "gx", 1, &p);
        call(M, "gx_other", u, "gx", 1, &o);
        call(M, "gs_point", u, "gs", 1, &p);
        call(M, "gs_other", u, "gs", 1, &o);
        mrb_value sv[] = {p, mrb_fixnum_value(9)};
        call(M, "sy_point", u, "sy", 2, sv);
        call(M, "gs_after", u, "gs", 1, &p);
        mrb_value ov[] = {o, mrb_fixnum_value(9)};
        call(M, "sy_other", u, "sy", 2, ov);
        mrb_value one = mrb_fixnum_value(1);
        call(M, "gx_integer", u, "gx", 1, &one);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(literal_dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    expected = ['gx_point => 3', 'gx_other => 10', 'gs_point => 7', 'gs_other => 0', 'sy_point => 9', 'gs_after => 12',
                'sy_other => 9', 'gx_integer => raised NoMethodError']
    suite.check('the interpreter gives the expected answers', interpreted == expected)
    puts "  interpreted: #{interpreted.inspect}" unless interpreted == expected
    suite.check('compiled matches interpreted', compiled == interpreted)
    puts "  compiled: #{compiled.inspect}" unless compiled == interpreted
  end
end

suite.finish!

#!/usr/bin/env ruby
# frozen_string_literal: true

# SINGLETON_ARMS (docs/adr/0369): a guard chain whose only open reason is a `.singleton` definer of a
# module (`def self.x`, `class << self; attr_reader`) gets an identity arm for that module object, so its
# else can raise the NoMethodError the dispatch would instead of sending by name.
#
# 1. With MRBC: generated code, a positive world and one negative world per withdrawn proof (a class
#    object definer, a `clone` anywhere, a mixin on the singleton class, a runtime definer, the switch).
# 2. With MRBC, g++ and a mruby build: the positive world on real mruby, interpreted and compiled, must
#    answer alike (values, exception classes) and the compiled arms must make no dynamic dispatch.
#    Builds: BC2CPP_MRUBY_FULL / BC2CPP_FULL_BUILD_DIR (full-core), BC2CPP_MRUBY_CORE (core only).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir] [BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/singleton_arms_check.rb

require 'tmpdir'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

require_relative 'fixture_runtime'
runtime = Bc2cppFixtureRuntime
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

OWNERS = %w[SaBox SaCrate SaHud.singleton SaDriver SaClassHud.singleton SaMix].freeze

# The names are spelled by no native, so the closed world's only open reason is the singleton definer.
WORLD = <<~'RUBY'
  class SaBox
    def sa_width; 7; end
    def sa_height; 8; end
  end
  class SaCrate
    attr_reader :sa_width, :sa_height
    def initialize; @sa_width = 17; @sa_height = 18; end
  end
  class SaOther
  end
  module SaHud
    def self.sa_width; 640; end
    class << self
      attr_reader :sa_height
    end
    @sa_height = 480
  end
  class SaDriver
    def w(x); x.sa_width; end
    def h(x); x.sa_height; end
  end
  class SaRun
    def self.obj(i)
      case i
      when 0 then SaBox.new
      when 1 then SaCrate.new
      when 2 then SaHud
      when 3 then nil
      when 4 then 'str'
      when 5 then SaBox
      when 6 then SaOther.new
      else 3
      end
    end
  end
RUBY
OBJECTS = 8
ANSWERING = %w[o0 o1 o2].freeze

SCENARIO = <<~'CPP'
  static int scenario(mrb_state* M) {
    mrb_value run = mrb_obj_value(mrb_class_get(M, "SaRun"));
    mrb_value driver = mrb_obj_new(M, mrb_class_get(M, "SaDriver"), 0, nullptr);
    mrb_gc_protect(M, driver);
    char label[32];
    for (int i = 0; i < OBJECTS; ++i) {
      mrb_value idx = mrb_fixnum_value(i);
      mrb_value o = (mrb_funcall_argv)(M, run, mrb_intern_lit(M, "obj"), 1, &idx);
      mrb_gc_protect(M, o);
      std::snprintf(label, sizeof label, "o%d.w", i); call(M, label, driver, "w", 1, &o);
      std::snprintf(label, sizeof label, "o%d.h", i); call(M, label, driver, "h", 1, &o);
    }
    return 0;
  }
CPP

arm_for = lambda do |body, name, mod|
  body.match?(/CLOSED_WORLD_CONSTANT_OBJECT :#{name} -> #{mod}\.singleton##{name}/)
end
identity = ->(body, mod) { body.match?(/MRB_TT_MODULE && mrb_class_ptr\(r\d+\) == bc2cpp_owner_class_\d+\(M\)/) && body.include?(mod) }
generate = lambda do |source, env = {}|
  saved = env.to_h { |k, _| [k, ENV[k]] }
  env.each { |k, v| ENV[k] = v }
  begin
    Dir.mktmpdir { |dir| runtime.generate(source, dir, only_owners: OWNERS) }
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end

puts '-- generated code'
code, = generate.call(WORLD)
w = body_of.call(code, 'SaDriver_w')
h = body_of.call(code, 'SaDriver_h')
check.call('the driver methods are compiled', !w.empty? && !h.empty?)
check.call('a def self.x on a module is an identity-guarded direct call',
           arm_for.call(w, 'sa_width', 'SaHud') && w.include?('SaHud_singleton_sa_width_impl(M,') && identity.call(w, 'SaHud'))
check.call('a `class << self` attr_reader on the module is a guarded direct ivar read',
           arm_for.call(h, 'sa_height', 'SaHud') && h.include?('mrb_iv_get(M,') && identity.call(h, 'SaHud'))
check.call('the else raises the NoMethodError dispatch would (bc2cpp_nomethod) and no by-name send is left',
           w.include?('bc2cpp_nomethod(M,') && h.include?('bc2cpp_nomethod(M,') &&
             !w.include?('bc2cpp_send(') && !h.include?('bc2cpp_send(') && !w.include?('kept: singleton_definer'))

off, = generate.call(WORLD, 'BC2CPP_SINGLETON_ARMS' => '0')
off_w = body_of.call(off, 'SaDriver_w')
check.call('BC2CPP_SINGLETON_ARMS=0 keeps the by-name else',
           off_w.include?('kept: singleton_definer') && !off_w.include?('MRB_TT_MODULE'))

NEGATIVES = {
  'a class object definer (class-side inheritance) is not armed' =>
    ["class SaKlass\n  def self.sa_width; 1; end\nend\n", 'SaKlass'],
  'a `clone` anywhere copies singleton methods, so nothing is armed' =>
    ["class SaCloner\n  def go; SaHud.clone; end\nend\n", 'clone'],
  'a mixin on the singleton class could answer first' =>
    ["module SaMix\n  def sa_width; 5; end\nend\nmodule SaHud\n  class << self\n    include SaMix\n  end\nend\n", 'mixin'],
  'a runtime definer of the name keeps the dispatch' =>
    ["class SaDefiner\n  def go(n); SaBox.send(:define_method, n) { 1 }; end\nend\n", 'define_method']
}.freeze
NEGATIVES.each do |what, (extra, _tag)|
  neg, = generate.call(WORLD + extra)
  nw = body_of.call(neg, 'SaDriver_w')
  check.call(what, nw.include?('bc2cpp_send(') && !nw.include?('MRB_TT_MODULE && mrb_class_ptr'))
end

# -- 2. fixtures on real mruby -----------------------------------------------------------------

builds = []
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds << ['full-core', full, true] if full && runtime.compiler?
builds << ['core only', runtime.core, false] if runtime.core && runtime.compiler?
puts '  SKIP run: set BC2CPP_MRUBY_FULL / BC2CPP_FULL_BUILD_DIR / BC2CPP_MRUBY_CORE and have g++' if builds.empty?

values = lambda do |sections, name|
  sections.fetch(name, []).reject { |l| l.start_with?('  ') }
end
dispatches_of = lambda do |sections|
  sections.fetch('compiled', []).each_cons(2).select { |_l, n| n.include?('dispatches=') }
          .to_h { |l, n| [l[/\A\S+/], n[/dispatches=(\d+)/, 1].to_i] }
end
run_world = lambda do |source, build, full_flag, env = {}|
  saved = env.to_h { |k, _| [k, ENV[k]] }
  env.each { |k, v| ENV[k] = v }
  begin
    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(source, dir, only_owners: OWNERS, native: [['scenario.cpp', SCENARIO]])
      body = "static const int OBJECTS = #{OBJECTS};\n#{SCENARIO}"
      built, output = runtime.run(dir, err, OWNERS, body, build: build, full: full_flag, exact_arity: true)
      puts output unless built
      built ? runtime.sections(output) : nil
    end
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end

builds.each do |label, build, full_flag|
  puts "-- fixtures on real mruby (#{label}), interpreted and compiled"
  sections = run_world.call(WORLD, build, full_flag)
  check.call('the fixture compiles and runs against real mruby', !sections.nil?)
  next unless sections

  interpreted = values.call(sections, 'interpreted')
  compiled = values.call(sections, 'compiled')
  check.call("compiled answers what the interpreter answers (#{interpreted.size} calls)",
             interpreted.size == OBJECTS * 2 && interpreted == compiled)
  interpreted.zip(compiled).each { |i, c| puts "    interpreted: #{i[0, 200]}\n    compiled:    #{c.to_s[0, 200]}" unless i == c }
  text = compiled.join("\n")
  # mrb_open_core raises with corrupted messages and class names: the values are compared above on every build.
  if full_flag
    check.call('the module object answers both names, instances answer theirs, the rest raise NoMethodError',
               text.include?('o2.w => 640') && text.include?('o2.h => 480') && text.include?('o0.w => 7') &&
                 text.include?('o1.h => 18') && text.include?('o3.w => raised NoMethodError') &&
                 text.include?('o5.h => raised NoMethodError') && text.include?('o7.w => raised NoMethodError'))
  end
  per = dispatches_of.call(sections)
  check.call('the compiled arms for the instances and the module object make no dynamic dispatch',
             ANSWERING.all? { |o| per["#{o}.w"]&.zero? && per["#{o}.h"]&.zero? })
  control = run_world.call(WORLD, build, full_flag, 'BC2CPP_SINGLETON_ARMS' => '0')
  check.call('without the arms the module object still answers alike, but by name',
             control && values.call(control, 'compiled') == interpreted && dispatches_of.call(control)['o2.w'].to_i.positive?)
end

puts failures.empty? ? 'all checks passed' : "#{failures.size} FAILED"
exit(failures.empty? ? 0 : 1)

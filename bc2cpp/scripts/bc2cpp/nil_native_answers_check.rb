#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# NIL_NATIVE_ANSWERS (tools/bc2cpp/native_owner_map.rb nil_native_answers): the names native code may put on nil's
# lookup path are read per registration owner, not per file. mruby-rational's rational.c defines `nil.to_r` next to
# `Rational#+`, and the old file-level scan made `+` a nil operator, so `@nn_ticks += 1` on a slot that may still be nil
# could not prove "nil + raises" (CodeGen#numeric_nil_raises?).
#
#   scan (no mrbc needed)
#     - rational.c puts to_r, not +, on nil's path; a NilClass/Object/Kernel/BasicObject registration of an operator
#       does; a class-method registration does not; an unresolved owner keeps the name (conservative); a computed
#       name outside 3rd/mruby, or a native include of an unresolved module, refuses every name; a module a native
#       include adds to Object carries its registrations.
#   generated code (needs a host mrbc)
#     - with mruby-rational in the build, a may-be-nil `@nn_ticks += 1` proves its ivar (NUMIVAR INT);
#     - a program NilClass#+, Object#+, Kernel#+ or a module included into Object with #+ leaves it unproven, as does
#       a native `+` on an owner the scan cannot resolve.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same: NoMethodError on the nil slot, Integer arithmetic after reset.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/nil_native_answers_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/native_owner_map'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''

ROOT_DIR = File.expand_path('../..', __dir__)
RATIONAL_GEM = File.join(ROOT_DIR, '3rd/mruby/mrbgems/mruby-rational')
RATIONAL_C = File.join(RATIONAL_GEM, 'src/rational.c')

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

puts '-- scan'
answers = lambda do |sources|
  Dir.mktmpdir('bc2cpp-nil-native') do |dir|
    paths = sources.each_with_index.map do |text, i|
      File.join(dir, "src#{i}.c").tap { |path| File.write(path, text) }
    end
    NativeOwnerMap.nil_native_answers(NativeOwnerMap.build(paths))
  end
end
rational = NativeOwnerMap.nil_native_answers(NativeOwnerMap.build([RATIONAL_C]))
check.call('rational.c puts to_r on nil', rational.names&.include?('to_r'))
check.call('rational.c does not put + on nil (Rational#+ is on Rational)', rational.names && !rational.names.include?('+'))
on_nil = answers.call([<<~C])
  void init(mrb_state *mrb) {
    mrb_define_method(mrb, mrb->nil_class, "+", nil_plus, MRB_ARGS_REQ(1));
    mrb_define_method_id(mrb, mrb->kernel_module, MRB_OPSYM(sub), k_sub, MRB_ARGS_REQ(1));
    mrb_define_method(mrb, mrb->object_class, "*", o_mul, MRB_ARGS_REQ(1));
    mrb_define_class_method(mrb, mrb->nil_class, "/", nil_class_div, MRB_ARGS_REQ(1));
  }
C
check.call('a native NilClass#+ / Kernel#- / Object#* is on nil', on_nil.names && %w[+ - *].all? { |n| on_nil.names.include?(n) })
check.call('a class-method registration on NilClass is not', on_nil.names && !on_nil.names.include?('/'))
unresolved = answers.call([<<~C])
  void init(mrb_state *mrb) {
    struct RClass *c = opaque_class(mrb);
    mrb_define_method(mrb, c, "+", c_plus, MRB_ARGS_REQ(1));
  }
C
check.call('a registration on an unresolved owner stays on nil (conservative)', unresolved.names&.include?('+'))
computed = answers.call([<<~C])
  void init(mrb_state *mrb, const char *name) {
    struct RClass *c = opaque_class(mrb);
    mrb_define_method(mrb, c, name, c_any, MRB_ARGS_ANY());
  }
C
check.call('a computed name on an unresolved owner outside 3rd/mruby refuses every name',
           computed.names.nil? && !computed.reason.nil?)
mixin = answers.call([<<~C])
  void init(mrb_state *mrb) {
    struct RClass *m = mrb_define_module(mrb, "Adder");
    mrb_define_method(mrb, m, "+", adder_plus, MRB_ARGS_REQ(1));
    mrb_include_module(mrb, mrb->object_class, m);
  }
C
check.call('a module a native include adds to Object carries its registrations',
           mixin.names&.include?('+') && mixin.modules&.include?('Adder'))
opaque_mixin = answers.call([<<~C])
  void init(mrb_state *mrb) {
    mrb_include_module(mrb, mrb->object_class, opaque_module(mrb));
  }
C
check.call('a native include of an unresolved module refuses every name', opaque_mixin.names.nil?)

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit failures.empty? ? 0 : 1
end

# NnCounter#@nn_ticks is assigned in #reset, not #initialize, so its entry mask includes nil; `tick` before `reset` raises
# NoMethodError on nil.
SRC = <<~'RUBY'
  class NnCounter
    def initialize
      @y = 0
    end

    def reset
      @nn_ticks = 0
    end

    def tick
      @nn_ticks += 1
      @y += 1
      @nn_ticks
    end

    def ticks
      @nn_ticks
    end
  end
RUBY

OWNERS = %w[NnCounter].freeze
WITH_RATIONAL = { build_gems: [['mruby-rational', RATIONAL_GEM]] }.freeze

def numivar(err, name)
  err[/^  NUMIVAR #{Regexp.escape(name)} \(([^)]*)\)$/, 1]
end

def generate(src, owners: OWNERS, **opts)
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: owners, **opts) }
end

puts '-- generated code'
baseline_dir = Dir.mktmpdir('bc2cpp-nil-native')
at_exit { FileUtils.remove_entry(baseline_dir) }
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS, **WITH_RATIONAL)
check.call('the build scans rational.c', baseline_err.include?('== nil native answers:'))
check.call('with mruby-rational, a may-be-nil @nn_ticks += 1 proves its ivar (NnCounter#@nn_ticks)', numivar(baseline_err, 'NnCounter#@nn_ticks') == 'INT')
check.call('the nil native answers leave + out', !baseline_err[/^== nil native answers: (.*) ==$/, 1].to_s.split.include?('+'))
check.call('no #error in the generated code', !code.include?('#error'))

REOPENS = {
  'NilClass#+' => "class NilClass\n  def +(o)\n    o\n  end\nend\n",
  'Object#+' => "class Object\n  def +(o)\n    o\n  end\nend\n",
  'Kernel#+' => "module Kernel\n  def +(o)\n    o\n  end\nend\n",
  'a module included into Object' => "module NnAdd\n  def +(o)\n    o\n  end\nend\nclass Object\n  include NnAdd\nend\n",
  'singleton def on nil (NilClass#+)' => "def nil.+(o)\n  o\nend\n"
}.freeze
REOPENS.each do |what, reopen|
  owners = OWNERS + [reopen[/(?:class|module) (\w+)/, 1]].compact
  _, err = generate(SRC + reopen, owners: owners, **WITH_RATIONAL)
  check.call("a program #{what} leaves NnCounter\#@nn_ticks unproven", numivar(err, 'NnCounter#@nn_ticks').nil?)
end
opaque = ['nn_opaque.c', <<~C]
  void nn_init(mrb_state *mrb) {
    struct RClass *c = nn_opaque_class(mrb);
    mrb_define_method(mrb, c, "+", nn_plus, MRB_ARGS_REQ(1));
  }
C
_, opaque_err = generate(SRC, native: [opaque], **WITH_RATIONAL)
check.call('a native + on an unresolved owner leaves NnCounter#@nn_ticks unproven', numivar(opaque_err, 'NnCounter#@nn_ticks').nil?)

DRIVER = <<~'RUBY'
  c = NnCounter.new
  begin
    c.tick
    p :no_raise
  rescue NoMethodError => e
    p [:nil_slot, e.class]
  end
  c.reset
  p [c.tick, c.tick, c.ticks, c.ticks.class]
  c.reset
  p c.tick
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"NNC(#{DRIVER})NNC";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('the nil slot raises NoMethodError', interpreted&.include?('[:nil_slot, NoMethodError]'))
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp nil native answers check: PASS'
else
  warn "bc2cpp nil native answers check: #{failures.size} failure(s)"
  exit 1
end

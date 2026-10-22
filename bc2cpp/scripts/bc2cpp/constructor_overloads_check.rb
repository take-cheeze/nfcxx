#!/usr/bin/env ruby
# frozen_string_literal: true

# Check OVERLOADED_CONSTRUCT: the constructor overloads of sig/bc2cpp/declarations.rbs#rgss_constructors.
#
#   1. audit (no mrbc): the shipped declarations agree with the C and Ruby sources of each initialize; each mismatch
#      world refuses the file: an extra or missing form, a wrong parameter type, a dropped `else`, a wrong optional
#      default, a wrong literal for the empty Rect, a direct path converting too few positionals;
#   2. generated code (MRBC): every declared overload is reached by a call site and takes its direct path: Bitmap's
#      (String) and (Integer, Integer) forms with no test when the arguments' classes are proven, a String test with
#      the size form as the final branch otherwise, the one-argument Bitmap through its compiled initialize alone;
#      Rect.new() and Rect.new(x, y, w, h) (inside begin/rescue too), Tone/Color with their defaults; no site keeps a
#      by-name `new`, and a count no overload takes (Rect.new(a, b)) keeps the older path.
#
# The RGSS natives are not linked into the fixture runtime, so the interpreted-versus-compiled half of these forms
# runs where the game build does; here the audit is what ties each declaration to the native's behaviour.
#
# Usage: [MRBC=path/to/host/mrbc] ruby scripts/bc2cpp/constructor_overloads_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/native_constructor_sigs'

ENV['BC2CPP_SIG_DIRS'] ||= ''
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

puts '== audit'
real = NativeSigs.table_source(NativeConstructorSigs::PATH)
shipped = begin
  NativeConstructorSigs.table && true
rescue RuntimeError
  false
end
check.call('the shipped declarations agree with their sources', shipped)
mutations = {
  'Bitmap gains a three-Integer form' => ['(Integer | Float width, Integer | Float height) -> void',
                                         '(Integer | Float width, Integer | Float height) -> void | %a{bc2cpp:direct rgss::bitmap_new_direct int int int} (Integer | Float a, Integer | Float b, Integer | Float c) -> void'],
  'Rect loses its empty form' => ["def initialize: %a{bc2cpp:direct rgss::rect_new_direct 0 0 0 0} () -> void\n                | ", 'def initialize: '],
  'Tone declares a String red' => ['(?Integer | Float red, ?Integer | Float green, ?Integer | Float blue, ?Integer | Float gray)',
                                   '(?String red, ?Integer | Float green, ?Integer | Float blue, ?Integer | Float gray)'],
  'Rect loses its else' => ['%a{bc2cpp:direct rgss::rect_new_direct int int int int} %a{bc2cpp:else}', '%a{bc2cpp:direct rgss::rect_new_direct int int int int}'],
  'Color defaults alpha to 0' => ['float=0 float=0 float=0 float=255', 'float=0 float=0 float=0 float=0'],
  'the empty Rect passes a 1' => ['rect_new_direct 0 0 0 0', 'rect_new_direct 0 0 0 1'],
  'Bitmap size form converts one positional' => ['rgss::bitmap_new_direct int int', 'rgss::bitmap_new_direct int 0'],
  'Bitmap transparent declared String, not boolish' => ['?boolish transparent', '?String transparent'],
  'Bitmap transparent declared untyped' => ['?boolish transparent', '?untyped transparent']
}
Dir.mktmpdir('ctor-overloads') do |dir|
  mutations.each_with_index do |(what, (from, to)), i|
    raise "mutation #{what} does not apply" unless real.include?(from)

    path = File.join(dir, "m#{i}.rbs")
    File.write(path, real.sub(from, to))
    refused = begin
      NativeConstructorSigs.table(path)
      false
    rescue RuntimeError => e
      e.message.include?('constructor overloads disagree') || e.message.include?('annotation') ||
        e.message.include?('unsupported parameter type')
    end
    check.call("refused: #{what}", refused)
  end
end

if ENV['MRBC']
  puts '== generated code'
  source = <<~RUBY
    class OvProbe
      def bm_lit; Bitmap.new(3, 4); end
      def bm_str; Bitmap.new("Picture/x"); end
      def bm2(x, y); Bitmap.new(x, y); end
      def bm1(x); Bitmap.new(x); end
      def rc0; Rect.new; end
      def rc4(a); begin; Rect.new(a, 0, 1, 1); rescue; nil; end; end
      def rc2(a, b); Rect.new(a, b); end
      def tn2(a); Tone.new(a, 1); end
      def cl0; Color.new; end
    end
  RUBY
  lib = File.read(File.join(Bc2cppFixtureRuntime::ROOT, 'mruby-rgss/mrblib/lib.rb'))
  Dir.mktmpdir('ctor-overloads-gen') do |dir|
    code, = Bc2cppFixtureRuntime.generate(source, dir, only_owners: %w[OvProbe RGSS::Bitmap],
                                                       extra: [['mruby-rgss/mrblib/lib.rb', lib]])
    File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'constructor_overloads.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
    body = lambda do |fn|
      code.scan(/^(?:static )?mrb_value OvProbe_#{fn}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
    end
    after = ->(fn) { body.call(fn)[/OVERLOADED_CONSTRUCT.*/m].to_s }
    untested = ->(fn) { !after.call(fn).match?(/if \((?!mrb_class_ptr)/) }
    %w[bm_str bm2 bm1 rc0 tn2 cl0].each do |fn|
      check.call("#{fn}: an overload's direct path, no by-name new", body.call(fn).include?('OVERLOADED_CONSTRUCT :new') &&
                                                                     !body.call(fn).include?('bc2cpp_send('))
    end
    # The entry point's own path already takes proven Integers with no test and Rect's four-argument form with no
    # by-name else; the overloads are resolved only where that path would leave one.
    check.call('bm_lit: proven Integers keep the size entry point with no tag test and no by-name new',
               body.call('bm_lit').include?('rgss::bitmap_new_direct(') && !body.call('bm_lit').include?('mrb_integer_p(') &&
                 !body.call('bm_lit').include?('bc2cpp_send('))
    check.call('bm_str: a String literal takes the file form (compiled initialize) with no test',
               after.call('bm_str').include?('RGSS__Bitmap_initialize_impl(') && !after.call('bm_str').include?('bitmap_new_direct') && untested.call('bm_str'))
    check.call('bm2: a String test for the file form, the size form as the final branch',
               after.call('bm2').match?(/if \(mrb_string_p\(r\d+\)\) \{.*RGSS__Bitmap_initialize_impl.*\} else \{.*mrb_as_int.*rgss::bitmap_new_direct/m))
    check.call('bm1: one argument, no size form: the compiled initialize alone',
               after.call('bm1').scan('RGSS__Bitmap_initialize_impl(').size == 1 && untested.call('bm1'))
    check.call('rc0: the empty form passes the zero fields', after.call('rc0').include?('rgss::rect_new_direct(M, ') &&
                                                            after.call('rc0').match?(/rect_new_direct\(M, [^,]+, 0, 0, 0, 0\)/))
    check.call('rc4: Rect.new(x, y, w, h) inside begin/rescue: the class test misses into a guard violation, not a by-name new',
               body.call('rc4').include?('rgss::rect_new_direct(') && body.call('rc4').include?('bc2cpp_guard_violation(') &&
                 !body.call('rc4').include?('bc2cpp_send('))
    check.call('tn2: Tone with two arguments fills the declared defaults', after.call('tn2').match?(/tone_new_direct\(M, [^,]+, \w+, \w+, 0, 0\)/))
    check.call('cl0: Color.new fills 0, 0, 0, 255', after.call('cl0').match?(/color_new_direct\(M, [^,]+, 0, 0, 0, 255\)/))
    check.call('rc2: a count no Rect overload takes keeps the older path', !body.call('rc2').include?('OVERLOADED_CONSTRUCT'))
  end
  # A program that gives Rect a Ruby initialize replaces the audited C one: its declarations no longer describe it.
  Dir.mktmpdir('ctor-overloads-reopen') do |dir|
    reopened = "#{source}\nmodule RGSS\n  class Rect\n    def initialize(*a); end\n  end\nend\n"
    code, = Bc2cppFixtureRuntime.generate(reopened, dir, only_owners: %w[OvProbe RGSS::Bitmap RGSS::Rect],
                                                         extra: [['mruby-rgss/mrblib/lib.rb', lib]])
    rc0 = code[/^mrb_value OvProbe_rc0_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
    check.call('a Ruby initialize on Rect withdraws its overloads', !rc0.empty? && !rc0.include?('OVERLOADED_CONSTRUCT'))
  end
else
  puts '-- SKIP generated code: set MRBC'
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp constructor overloads check: PASS'

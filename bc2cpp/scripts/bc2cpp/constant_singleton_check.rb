#!/usr/bin/env ruby
# frozen_string_literal: true

# CONSTANT_SINGLETON (docs/adr/0281): a send whose receiver is a stable class or
# module constant reaches its singleton method without dispatch, both for
# Ruby-defined singleton methods (CLOSED_WORLD_CONSTANT_OBJECT) and, through the
# audited NativeDirect entries, for RGSS natives (NATIVE_SINGLETON_DIRECT).
#
# 1. With MRBC: the generated code for fixtures. A constant load inside a loop
#    that also holds a `break` (a JMPUW edge) still resolves; each way the
#    constant or its singleton lookup can change at run time keeps the dispatch.
# 2. With MRBC, BC2CPP_MRUBY_FULL and g++: the fixtures run against real mruby,
#    interpreted and compiled, and must answer alike.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/constant_singleton_check.rb

require 'tmpdir'
require_relative 'cxx'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

if ENV['MRBC']
  require_relative 'fixture_runtime'
  runtime = Bc2cppFixtureRuntime
  body_of = lambda do |code, fn|
    code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
  end

  LOOP_WORLD = <<~RUBY
    module CsCodec
      def self.read(list); list.shift; end
      def self.twice(list); list.shift; list.shift; end
    end
    class CsLoop
      # `break` inside a rescue body is a JMPUW, which used to make every
      # constant load after it unresolvable.
      def scan(list)
        out = []
        begin
          until list.empty?
            a = CsCodec.read(list)
            break if a == 0
            out << CsCodec.read(list)
          end
        rescue StopIteration
          out << :stop
        end
        out
      end
    end
  RUBY

  puts '-- constant load after a break in a rescue body'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(LOOP_WORLD, dir)
    # The rescue body is outlined into its own function, so count over the whole unit.
    check.call('both loads of the constant reach the singleton method directly',
               code.scan('CLOSED_WORLD_CONSTANT_OBJECT :read -> CsCodec.singleton#read').size == 2 &&
                 !code.match?(/POLY_DIAG[^\n]*name="read"/))
  end

  # The same loop shape with one way each for the constant or its lookup to change.
  loop_probe = <<~RUBY
    class CsLoop
      def scan(list)
        begin
          until list.empty?
            a = CsCodec.read(list)
            break if a == 0
          end
        rescue StopIteration
          a = 0
        end
        a
      end
    end
  RUBY
  variants = {
    'a singleton method defined a second time' => "module CsCodec\n  def self.read(list); list.pop; end\nend\n",
    'a class constant assigned again' => "class CsKlass\n  def self.read(list); 1; end\nend\nCsKlass = CsCodec\n",
    'an extend on the module' => "module CsExtra\n  def read(list); 9; end\nend\nCsCodec.extend(CsExtra)\n",
    'an alias over the singleton method' => "class << CsCodec\n  def other(list); 5; end\n  alias read other\nend\n"
  }
  puts '-- the loop shape keeps its dispatch when the lookup can change'
  variants.each do |what, extra|
    Dir.mktmpdir do |dir|
      probe = loop_probe.gsub('CsCodec.read', what.start_with?('a class constant') ? 'CsKlass.read' : 'CsCodec.read')
      code, = runtime.generate("module CsCodec\n  def self.read(list); list.shift; end\nend\n#{extra}#{probe}", dir)
      body = body_of.call(code, 'CsLoop_scan') + code[/^static mrb_value CsLoop_scan_impl_rescue_try.*?(?=^mrb_value )/m].to_s
      check.call("#{what} keeps the by-name dispatch", !body.include?('CLOSED_WORLD_CONSTANT_OBJECT :read') && body.match?(/name="read"/))
    end
  end

  # -- RGSS natives with a NativeDirect entry (ADR 0253, 0263) ------------------
  NATIVE_WORLD = <<~RUBY
    module RGSS
      class Bitmap
        def self.state; _load_error; end
        def self.via_constant; Bitmap._decoder_ran?; end
        def make(w, h); _init_size(w, h); end
      end
      module Input
        def self.mouse; RGSS.mouse_x; end
      end
      def self.retitle(t); RGSS.window_title = t; end
    end
  RUBY
  # Each world adds one way for the native lookup to change, and names the call
  # sites (owner#method => marker) that must keep dispatching.
  native_negatives = {
    'a Ruby redefinition of the singleton method' =>
      ["def RGSS.mouse_x; 42; end\n", { 'RGSS::Input.singleton_mouse' => 'mouse_x' }],
    'a class or module nested in the caller shadowing the constant' =>
      ["module CsShadow\n  module RGSS\n    def self.mouse_x; 5; end\n  end\n  def self.probe; RGSS.mouse_x; end\nend\n",
       { 'CsShadow.singleton_probe' => 'mouse_x' }],
    'an extend on the module' =>
      ["module CsExtra\n  def mouse_x; 9; end\nend\nRGSS.extend(CsExtra)\n", { 'RGSS::Input.singleton_mouse' => 'mouse_x' }],
    'an alias over the native inside its singleton class' =>
      ["class << RGSS\n  alias mouse_x mouse_y\nend\n", { 'RGSS::Input.singleton_mouse' => 'mouse_x' }],
    'a private_class_method on the native name' =>
      ["module RGSS\n  private_class_method :mouse_x\nend\n", { 'RGSS::Input.singleton_mouse' => 'mouse_x' }],
    'a prepend on the singleton class' =>
      ["module CsHook\n  def _decoder_ran?; true; end\nend\nclass << RGSS::Bitmap\n  prepend CsHook\nend\n",
       { 'RGSS::Bitmap.singleton_via_constant' => '_decoder_ran?' }],
    'a singleton method reopened with class << self' =>
      ["class RGSS::Bitmap\n  class << self\n    def _load_error; :own; end\n  end\nend\n", { 'RGSS::Bitmap.singleton_state' => '_load_error' }],
    'a define_singleton_method' =>
      ["RGSS.define_singleton_method(:mouse_x) { 1 }\n", { 'RGSS::Input.singleton_mouse' => 'mouse_x' }],
    'a subclass of the class' =>
      ["class CsBitmap < RGSS::Bitmap\n  def self._load_error; :sub; end\nend\n",
       { 'RGSS::Bitmap.singleton_state' => '_load_error', 'RGSS::Bitmap_make' => '_init_size' }]
  }

  puts '-- RGSS natives reached through a proven receiver'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(NATIVE_WORLD, dir)
    marker = ->(name, owner) { code.include?("NATIVE_EXACT_DIRECT :#{name} -> #{owner} (") }
    site = ->(fn) { body_of.call(code, fn) }
    check.call('`self` of a class-method calls the singleton entry point (implicit receiver)',
               marker.call('_load_error', 'RGSS::Bitmap.singleton') &&
                 site.call('RGSS__Bitmap_singleton_state').include?('rgss::bmp_load_error_direct(M, self)') &&
                 !site.call('RGSS__Bitmap_singleton_state').include?('bc2cpp_send('))
    check.call('a stable constant receiver calls the singleton entry point',
               marker.call('_decoder_ran?', 'RGSS::Bitmap.singleton') &&
                 site.call('RGSS__Bitmap_singleton_via_constant').match?(/rgss::bmp_decoder_ran_direct\(M, r\d+\)/) &&
                 !site.call('RGSS__Bitmap_singleton_via_constant').include?('bc2cpp_send('))
    check.call('a constant naming a module reaches its native module function',
               marker.call('mouse_x', 'RGSS.singleton') && site.call('RGSS__Input_singleton_mouse').include?('rgss::mouse_x_m_direct(') &&
                 !site.call('RGSS__Input_singleton_mouse').include?('bc2cpp_send('))
    check.call('an argument the binding passes through (:value) needs no guard and no fallback',
               marker.call('window_title=', 'RGSS.singleton') &&
                 site.call('RGSS_singleton_retitle').match?(/rgss::window_title_set_m_direct\(M, r\d+, r\d+\)/) &&
                 !site.call('RGSS_singleton_retitle').include?('bc2cpp_send('))
    make = site.call('RGSS__Bitmap_make')
    check.call('`self` of an exact class calls the instance entry point, converting both arguments as "ii" does (ADR 0372)',
               marker.call('_init_size', 'RGSS::Bitmap') && make.include?('rgss::bmp_init_size_direct(M, self, bc2cpp_pu') &&
                 make.scan('mrb_as_int(M, ').size == 2 && !make.include?('mrb_integer_p(') && !make.include?('bc2cpp_send('))
    include_dirs = ["-I#{dir}", "-I#{runtime.core}/include", "-I#{runtime::ROOT}/3rd/mruby/include", "-I#{runtime::ROOT}/include"]
    if runtime.core && runtime.compiler?
      check.call('the generated calls compile against include/rgss_native_direct.hxx',
                 Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-w', '-fsyntax-only', *include_dirs,
                        File.join(dir, 'fixture_gen.cpp')))
    end
  end
  native_negatives.each do |what, (extra, sites)|
    Dir.mktmpdir do |dir|
      code, = runtime.generate(NATIVE_WORLD + extra, dir)
      sites.each do |site, name|
        fn = site.gsub('::', '__').tr('.', '_') # the emitted function name
        body = body_of.call(code, fn)
        # It dispatches or, for a Ruby definition the closed world sees, calls that definition; never the native.
        check.call("#{what} keeps `#{name}` in #{fn} off the native entry point",
                   !body.empty? && !body.include?("NATIVE_EXACT_DIRECT :#{name}") &&
                     (body.include?('bc2cpp_send(') || body.include?("CLOSED_WORLD_CONSTANT_OBJECT :#{name}")))
      end
    end
  end

  full = runtime.full
  if full.nil? || !runtime.compiler?
    puts '  SKIP run: set BC2CPP_MRUBY_FULL (libmruby.a with the full-core gems, from the patched 3rd/mruby) and have g++'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(LOOP_WORLD, dir, closed: true, only_owners: %w[CsCodec.singleton CsLoop])
      body = <<~CPP
        static mrb_value ints(mrb_state* M, std::initializer_list<int> xs) {
          mrb_value list = mrb_ary_new(M);
          for (int x : xs) mrb_ary_push(M, list, mrb_fixnum_value(x));
          return list;
        }
        static int scenario(mrb_state* M) {
          mrb_value loop = mrb_obj_new(M, mrb_class_get(M, "CsLoop"), 0, nullptr);
          mrb_value a = ints(M, {3, 4, 5, 6, 0, 9});
          call(M, "scan stops at the zero", loop, "scan", 1, &a);
          mrb_value b = ints(M, {3, 4});
          call(M, "scan drains the list", loop, "scan", 1, &b);
          mrb_value c = ints(M, {});
          call(M, "scan of an empty list", loop, "scan", 1, &c);
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, %w[CsCodec.singleton CsLoop], body, build: full, full: true)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output unless built
      if built
        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        check.call('the compiled loop answers what the interpreter answers',
                   !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
      end
    end
  end
else
  puts '  SKIP generated code: set MRBC (a host mrbc built from the patched 3rd/mruby)'
end

puts(failures.empty? ? 'bc2cpp_constant_singleton_check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)

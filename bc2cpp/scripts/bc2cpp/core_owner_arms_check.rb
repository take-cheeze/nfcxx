#!/usr/bin/env ruby
# frozen_string_literal: true

# Check CORE_OWNER_ARMS (codegen_static_owner_arms.rb) on a closed-world fixture: an owner call with no block whose
# name an exact builtin receiver answers with a compiled mruby core body gets an exact-class arm calling that body's
# `_impl`, and the owner call stays as the else.
#
#   1. generated code: `o.abs` (Numeric#abs in mruby's mrblib, Float#abs native) gets an Integer arm calling
#      Numeric_abs_impl and no Float arm; `o.first(n)` (Array#first native)
#      keeps its owner call; a name only natives answer (`o.size`) gets no core arm; the owner call is the else of every arm;
#   2. run on a full-core mruby, compiled against interpreted: Integers (bignum included), Floats, a Numeric subclass
#      with its own `abs`, an Array, a Range and nil give the same value or error.
#
# The fixture compiles mruby's own mrblib in front of it (core: true), as the closed build does, so Numeric#abs is a
# compiled core body.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/core_owner_arms_check.rb
# The run needs a full-core libmruby built from this tree's patched 3rd/mruby (BC2CPP_MRUBY_FULL, or one built here).

require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']

SOURCE = <<~RUBY
  class Meter < Numeric
    def initialize(v); @v = v; end
    def abs; [:meter_abs, @v]; end
  end
  class Probe
    def ab(o); o.abs; end
    def fs(o, n); o.first(n); end
    def sz(o); o.size; end
  end
RUBY
OWNERS = %w[Meter Probe].freeze

body = ->(code, name) { code[/^mrb_value Probe_#{name}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }

Dir.mktmpdir('core-owner-arms') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS, core: true)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'core_owner_arms.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  ab = body.call(code, 'ab')
  check.call('abs: STATIC_OWNER_ARMS names Integer', ab.match?(/STATIC_OWNER_ARMS :abs -> [^\n]*Integer/))
  check.call('abs: the Integer arm calls Numeric_abs_impl', ab.match?(/if \(mrb_integer_p\(r\d+\)\) \{\n\s*r\d+ = Numeric_abs_impl\(M, r\d+\);/))
  check.call('abs: no Float arm (Float#abs is native)', !ab[/STATIC_OWNER_ARMS :abs -> [^\n]*/].to_s.include?('Float'))
  check.call('abs: the owner call stays as the else', ab.include?('bc2cpp_owner_call(M, ') &&
             ab.index('Numeric_abs_impl').to_i < ab.rindex('bc2cpp_owner_call(').to_i)
  fs = body.call(code, 'fs')
  check.call('first(n): the owner call stays as the else', fs.include?('bc2cpp_owner_call(M, '))
  check.call('size: no core arm (only natives answer it)', !body.call(code, 'sz').include?('STATIC_OWNER_ARMS :size'))

  harness = <<~CPP
    #include <cstdio>
    #include <string>
    struct Call { mrb_value obj; mrb_sym mid; mrb_int argc; mrb_value argv[2]; };
    static mrb_value call_body(mrb_state* M, void* ud) {
      Call* c = (Call*)ud;
      return mrb_funcall_argv(M, c->obj, c->mid, c->argc, c->argv);
    }
    static void row(mrb_state* M, const char* label, const char* meth, mrb_value recv, int argc, mrb_value arg) {
      mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
      Call c = { probe, mrb_intern_cstr(M, meth), argc + 1, { recv, arg } };
      mrb_bool raised = FALSE;
      mrb_value v = mrb_protect_error(M, call_body, &c, &raised);
      std::string out;
      if (raised) {
        mrb_value msg = mrb_funcall(M, v, "message", 0);
        out = std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
      } else {
        mrb_value s = mrb_inspect(M, v);
        out = std::string(RSTRING_PTR(s), RSTRING_LEN(s));
      }
      std::printf("%s => %s\\n", label, out.c_str());
    }
    static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
    static int scenario(mrb_state* M) {
      const char* ab[] = {"3", "-3", "0", "-4611686018427387904", "-(2**70)", "-2.5", "Float::NAN", "Meter.new(4)",
                          "nil", "'s'"};
      for (const char* e : ab) row(M, (std::string("abs ") + e).c_str(), "ab", eval(M, e), 0, mrb_nil_value());
      const char* fs[] = {"[1, 2, 3]", "(1..5)", "(1...1)", "nil"};
      for (const char* e : fs) {
        row(M, (std::string("first(2) ") + e).c_str(), "fs", eval(M, e), 1, mrb_fixnum_value(2));
        row(M, (std::string("first(-1) ") + e).c_str(), "fs", eval(M, e), 1, mrb_fixnum_value(-1));
      }
      return 0;
    }
  CPP
  build = runtime.full_or_build
  if build
    built, output = runtime.run(dir, err, OWNERS, harness, build: build, full: true)
    sections = runtime.sections(output)
    compiled = sections['compiled'].to_a
    interpreted = sections['interpreted'].to_a
    check.call('built and ran', built)
    check.call('runtime parity (every row)', !compiled.empty? && compiled == interpreted)
    check.call('abs -3 is 3', compiled.include?('abs -3 => 3'))
    check.call('Meter keeps its own abs', compiled.any? { |l| l.start_with?('abs Meter') && l.include?(':meter_abs') })
    warn output unless failures.empty?
  else
    puts '  SKIP run: no full-core mruby build'
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp core owner arms check: PASS'

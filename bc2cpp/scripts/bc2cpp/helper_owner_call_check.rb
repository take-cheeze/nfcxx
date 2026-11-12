#!/usr/bin/env ruby
# frozen_string_literal: true

# Check HELPER_OWNER_CALL (tools/bc2cpp/codegen_outside_owner_call.rb) on a closed-world fixture:
#   1. generated code: the numeric slow helpers' last-resort by-name send (`bc2cpp_funcall_keep(M, a, "<<", ...)`,
#      the rooted mrb_funcall) becomes the owner call over the name's owner set, so a non-Integer `a << b` (String,
#      Array) is one checked lookup the call's inline cache answers, not a by-name send each time;
#   2. run on a full-core mruby, compiled against interpreted: Integer, String, Array and a program class answer `<<`,
#      `+` and `-` the same, and nil raises the same NoMethodError.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/helper_owner_call_check.rb
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
  class Acc
    def initialize; @n = 0; end
    def <<(x); @n += x; self; end
    def +(x); [:acc_plus, x]; end
    def -(x); [:acc_minus, x]; end
    def inspect; "#<Acc \#{@n}>"; end
  end
  class Probe
    def sh(a, b); a << b; end
    def pl(a, b); a + b; end
    def mi(a, b); a - b; end
  end
RUBY
OWNERS = %w[Acc Probe].freeze

Dir.mktmpdir('helper-owner-call') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'helper_owner_call.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  helper = code[/static mrb_value bc2cpp_slow_lshift\(mrb_state\* M.*?\n\}\n/m].to_s
  check.call('the << slow helper is emitted', !helper.empty?)
  check.call('its fallback is the owner call over the << owner set',
             helper.match?(/bc2cpp_owner_call\(M, a, \d+, 0, BC2CPP_OWNERS\([^)]*"Acc"[^)]*\), mrb_nil_value\(\), 1, b\)/))
  check.call('no by-name fallback left in the numeric slow helpers',
             !code.match?(/bc2cpp_funcall_keep\(M, a, "(?:<<|\+|-)"/))

  unless ENV['CC_GENERATED_ONLY'] == '1'
    harness = <<~'CPP'
      #include <mruby/error.h>
      #include <string>
      struct Call { mrb_value obj; mrb_sym mid; mrb_value argv[2]; };
      static mrb_value call_body(mrb_state* M, void* ud) {
        Call* c = (Call*)ud;
        return mrb_funcall_argv(M, c->obj, c->mid, 2, c->argv);
      }
      static void row(mrb_state* M, const char* label, const char* meth, mrb_value a, mrb_value b) {
        mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
        Call c = { probe, mrb_intern_cstr(M, meth), { a, b } };
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
        std::printf("%s => %s\n", label, out.c_str());
      }
      static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
      static int scenario(mrb_state* M) {
        mrb_value three = mrb_int_value(M, 3);
        for (int k = 0; k < 2; ++k) {  // the second round runs on the owner call's inline cache
          row(M, "int << 3", "sh", mrb_int_value(M, 1), three);
          row(M, "str << 3", "sh", eval(M, "+'ab'"), three);
          row(M, "ary << 3", "sh", eval(M, "[1]"), three);
          row(M, "acc << 3", "sh", eval(M, "Acc.new"), three);
          row(M, "nil << 3", "sh", mrb_nil_value(), three);
          row(M, "str + str", "pl", eval(M, "'ab'"), eval(M, "'cd'"));
          row(M, "acc + 3", "pl", eval(M, "Acc.new"), three);
          row(M, "ary - ary", "mi", eval(M, "[1, 2]"), eval(M, "[2]"));
          row(M, "acc - 3", "mi", eval(M, "Acc.new"), three);
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
      check.call('String#<< through the owner call', compiled.any? { |l| l.start_with?('str << 3') && l.include?('"ab\\x03"') })
      check.call('a program class answers <<', compiled.any? { |l| l.start_with?('acc << 3') && l.include?('#<Acc 3>') })
      check.call('nil still raises NoMethodError', compiled.any? { |l| l.start_with?('nil << 3') && l.include?('NoMethodError') })
      warn output unless failures.empty?
    else
      puts '  SKIP run: no full-core mruby build'
    end
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp helper owner call check: PASS'

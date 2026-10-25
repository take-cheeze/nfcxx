#!/usr/bin/env ruby
# frozen_string_literal: true

# Check OWNER_SET_DIRECT on a closed-world fixture: an owner call whose name's every owner is an audited mruby native
# (tools/bc2cpp/codegen_owner_set_direct.rb) is computed in place, with no lookup.
#
#   1. generated code: `o.nil?` becomes mrb_nil_p with no owner call; `o.respond_to?(n)` becomes mrb_respond_to behind
#      mrb_symbol_p, the owner call kept as the else for any other argument; BC2CPP_OWNER_SET_DIRECT=0 keeps the
#      owner calls;
#   2. run on a full-core mruby, compiled against interpreted: nil?, respond_to? with a Symbol (public, private and
#      missing method, with and without the include_all flag), with a String (the else) and with a non-name
#      argument (TypeError) give the same value or error.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/owner_set_direct_check.rb
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
  class Bag
    def size; 2; end

    private

    def secret; 1; end
  end
  class Probe
    def nl(o); o.nil?; end
    def rt(o, n); o.respond_to?(n); end
    def rt2(o, n); o.respond_to?(n, true); end
  end
RUBY
OWNERS = %w[Bag Probe].freeze

body = ->(code, name) { code[/^mrb_value Probe_#{name}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }

Dir.mktmpdir('owner-set-direct') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'owner_set_direct.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  nl = body.call(code, 'nl')
  check.call('nil?: OWNER_SET_DIRECT marker', nl.include?('OWNER_SET_DIRECT :nil?'))
  check.call('nil?: computed as mrb_nil_p', nl.include?('mrb_bool_value(mrb_nil_p('))
  check.call('nil?: no owner call or by-name send left', !nl.include?('bc2cpp_owner_call(') && !nl.include?('bc2cpp_send('))
  rt = body.call(code, 'rt')
  check.call('respond_to?: OWNER_SET_DIRECT marker', rt.include?('OWNER_SET_DIRECT :respond_to?'))
  check.call('respond_to?: mrb_respond_to behind mrb_symbol_p',
             rt.match?(/if \([^\n]*mrb_symbol_p\(r\d+\)[^\n]*\) \{\n\s*r\d+ = mrb_bool_value\(mrb_respond_to\(M, /))
  check.call('respond_to?: the owner call stays as the else', rt.include?('} else {') && rt.include?('bc2cpp_owner_call(M, '))
  rt2 = body.call(code, 'rt2')
  check.call('respond_to?(n, true): also direct', rt2.include?('OWNER_SET_DIRECT :respond_to?'))

  off = begin
    ENV['BC2CPP_OWNER_SET_DIRECT'] = '0'
    Dir.mktmpdir('owner-set-direct-off') { |off_dir| runtime.generate(SOURCE, off_dir, only_owners: OWNERS).first }
  ensure
    ENV.delete('BC2CPP_OWNER_SET_DIRECT')
  end
  check.call('BC2CPP_OWNER_SET_DIRECT=0 keeps the owner calls',
             !off.include?('OWNER_SET_DIRECT :') && body.call(off, 'nl').include?('bc2cpp_owner_call(M, '))

  unless ENV['CC_GENERATED_ONLY'] == '1'
    harness = <<~'CPP'
      #include <mruby/error.h>
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
        std::printf("%s => %s\n", label, out.c_str());
      }
      static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
      static int scenario(mrb_state* M) {
        mrb_value bag = eval(M, "Bag.new");
        row(M, "nil.nil?", "nl", mrb_nil_value(), 0, mrb_nil_value());
        row(M, "bag.nil?", "nl", bag, 0, mrb_nil_value());
        row(M, "false.nil?", "nl", mrb_false_value(), 0, mrb_nil_value());
        row(M, "bag.respond_to?(:size)", "rt", bag, 1, eval(M, ":size"));
        row(M, "bag.respond_to?(:secret)", "rt", bag, 1, eval(M, ":secret"));
        row(M, "bag.respond_to?(:missing)", "rt", bag, 1, eval(M, ":missing"));
        row(M, "nil.respond_to?(:nil?)", "rt", mrb_nil_value(), 1, eval(M, ":nil?"));
        row(M, "bag.respond_to?('size') (String: owner call)", "rt", bag, 1, eval(M, "'size'"));
        row(M, "bag.respond_to?(1) (TypeError)", "rt", bag, 1, mrb_int_value(M, 1));
        row(M, "bag.respond_to?(:secret, true)", "rt2", bag, 1, eval(M, ":secret"));
        row(M, "bag.respond_to?(:missing, true)", "rt2", bag, 1, eval(M, ":missing"));
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
      check.call('nil.nil? is true', compiled.any? { |l| l.start_with?('nil.nil? =>') && l.end_with?('true') })
      check.call('a non-name argument still raises TypeError',
                 compiled.any? { |l| l.start_with?('bag.respond_to?(1)') && l.include?('TypeError') })
      warn output unless failures.empty?
    else
      puts '  SKIP run: no full-core mruby build'
    end
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp owner set direct check: PASS'

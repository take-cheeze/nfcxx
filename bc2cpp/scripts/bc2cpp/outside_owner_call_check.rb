#!/usr/bin/env ruby
# frozen_string_literal: true

# Check OUTSIDE_OWNER_CALL (docs/adr/0468) on a closed-world fixture: a guard chain whose else stayed a by-name send
# only because a core or native class also defines the name (`CLOSED_WORLD kept: core_or_native`) ends in a call
# checked against every outside owner of the name, and answers as the interpreter does.
#
#   1. generated code: `o.delete(x)`, `o.name`, `o.at`, `o.print(x)` next to a Ruby class that defines each name end
#      in bc2cpp_owner_call with the owners the native and outside Ruby scans name (Array, Hash, String for `delete`),
#      at the OP_SEND check level of an explicit receiver, with no by-name send left;
#   2. withdrawals, each keeping `kept: core_or_native`: an outside native registration of the name on a class the
#      owner map cannot name, an outside Ruby `def obj.delete` on an object it cannot name, and the owner map switched
#      off (BC2CPP_NATIVE_OWNER_MAP=0);
#   3. run on a full-core mruby, compiled against interpreted: the Ruby arm, the core owners (Array#delete, Hash#delete
#      in mrblib, String#delete, Symbol#name, NameError#name, Array#at), nil and an Integer (NoMethodError), a raw C
#      function called with the wrong argument count (OP_SEND's aspec check: ArgumentError), a private Kernel method
#      on an explicit receiver (NoMethodError), and StringIO#print (outside Ruby) give the same value or error class
#      and message; a definition installed behind the closed world's back (a C `Integer#delete` the scans never saw)
#      raises the owner violation in the compiled run only.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/outside_owner_call_check.rb
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
    def initialize; @items = [1, 2]; end
    def delete(x); @items.delete(x); end
    def name; "bag"; end
    def at; :bag_at; end
    def print(x); x; end
    def push(x); [:bag_push, x]; end
    def empty?; false; end
  end
  class Probe
    def del(o, x); o.delete(x); end
    def nm(o); o.name; end
    def at(o); o.at; end
    def pr(o, x); o.print(x); end
    def pk(o, f); o.pack(f); end
    def ps(o, x); o.push(x); end
    def em(o); o.empty?; end
  end
RUBY
OWNERS = %w[Bag Probe].freeze

body = ->(code, name) { code[/^mrb_value Probe_#{name}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
owners_of = ->(text) { text[/BC2CPP_OWNERS\(([^)]*)\)/, 1].to_s.scan(/"([^"]+)"/).flatten }

Dir.mktmpdir('outside-owner-call') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'outside_owner_call.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  del = body.call(code, 'del')
  check.call('delete: else is the owner call', del.include?('bc2cpp_owner_call(M, ') && del.include?('CLOSED_WORLD owner-call: delete'))
  check.call('delete: no by-name send left', !del.include?('bc2cpp_send(') && !del.include?('kept: core_or_native'))
  check.call('delete: owners are the core definers', (%w[Array Hash String] - owners_of.call(del)).empty?)
  check.call('delete: explicit receiver checks (level 2)', del.match?(/bc2cpp_owner_call\(M, r\d+, \d+, 2, /))
  check.call('delete: the Ruby arm stays first', del.index('Bag_delete_impl').to_i < del.index('bc2cpp_owner_call').to_i)
  check.call('name: owners include Symbol and NameError', (%w[NameError Symbol] - owners_of.call(body.call(code, 'nm'))).empty?)
  check.call('at: owners include Array', owners_of.call(body.call(code, 'at')).include?('Array'))
  check.call('print: owners include Kernel', owners_of.call(body.call(code, 'pr')).include?('Kernel'))
  pk = body.call(code, 'pk')
  check.call('bare pack (no guard chain): the send is the owner call with Array as its owner',
             pk.include?('OUTSIDE_OWNER_CALL :pack') && pk.include?('bc2cpp_owner_call(M, ') &&
               owners_of.call(pk).include?('Array') && !pk.include?('bc2cpp_send('))
  ps = body.call(code, 'ps')
  check.call('push, two owners (Array and the project Bag): owner call over exactly {Array, Bag}, no by-name send',
             ps.include?('bc2cpp_owner_call(M, ') && owners_of.call(ps) == %w[Array Bag] && !ps.include?('bc2cpp_send('))
  em = body.call(code, 'em')
  check.call('empty?: the registered-expression arms end in the owner call, not a by-name send',
             em.include?('bc2cpp_owner_call(M, ') && (%w[Array Bag Hash String] - owners_of.call(em)).empty? &&
               !em.include?('bc2cpp_send('))
  check.call('helper emitted once', code.scan('static mrb_value bc2cpp_owner_call(').size == 1)
  check.call('closed-world summary keeps no core_or_native', !err.include?('KEPT core_or_native'))

  unless ENV['CC_GENERATED_ONLY'] == '1'
    harness = <<~'CPP'
      #include <mruby/error.h>
      #include <string>
      static mrb_value rogue_delete(mrb_state* M, mrb_value self) { return mrb_str_new_lit(M, "rogue"); }
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
        mrb_value two = mrb_int_value(M, 2);
        row(M, "bag.delete", "del", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 1, two);
        row(M, "array.delete", "del", eval(M, "[1, 2, 3]"), 1, two);
        row(M, "hash.delete", "del", eval(M, "{2 => :two}"), 1, two);
        row(M, "string.delete", "del", eval(M, "'a2b2'"), 1, mrb_str_new_lit(M, "2"));
        row(M, "nil.delete", "del", mrb_nil_value(), 1, two);
        row(M, "symbol.name", "nm", eval(M, ":sym"), 0, mrb_nil_value());
        row(M, "name_error.name", "nm", eval(M, "NameError.new('m', :missing)"), 0, mrb_nil_value());
        row(M, "object.name", "nm", eval(M, "Object.new"), 0, mrb_nil_value());
        row(M, "array.at (aspec)", "at", eval(M, "[1]"), 0, mrb_nil_value());
        row(M, "object.print (private)", "pr", eval(M, "Object.new"), 1, two);
        row(M, "stringio.print", "pr", eval(M, "StringIO.new"), 1, two);
        row(M, "array.pack", "pk", eval(M, "[65, 66]"), 1, mrb_str_new_lit(M, "C*"));
        row(M, "string.pack", "pk", eval(M, "'ab'"), 1, mrb_str_new_lit(M, "C*"));
        row(M, "nil.pack", "pk", mrb_nil_value(), 1, mrb_str_new_lit(M, "C*"));
        row(M, "array.push", "ps", eval(M, "[1]"), 1, two);
        row(M, "bag.push", "ps", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 1, two);
        row(M, "nil.push", "ps", mrb_nil_value(), 1, two);
        row(M, "array.empty?", "em", eval(M, "[]"), 0, mrb_nil_value());
        row(M, "bag.empty?", "em", mrb_obj_new(M, mrb_class_get(M, "Bag"), 0, nullptr), 0, mrb_nil_value());
        row(M, "array subclass.empty?", "em", eval(M, "class SubArr < Array; end; SubArr.new"), 0, mrb_nil_value());
        row(M, "integer.empty?", "em", mrb_int_value(M, 3), 0, mrb_nil_value());
        mrb_define_method(M, M->integer_class, "delete", rogue_delete, MRB_ARGS_REQ(1));
        row(M, "rogue Integer#delete", "del", mrb_int_value(M, 5), 1, two);
        return 0;
      }
    CPP
    build = runtime.full_or_build
    if build
      built, output = runtime.run(dir, err, OWNERS, harness, build: build, full: true)
      sections = runtime.sections(output)
      compiled = sections['compiled'].to_a
      interpreted = sections['interpreted'].to_a
      rogue = ->(lines) { lines.find { |line| line.start_with?('rogue') }.to_s }
      plain = ->(lines) { lines.reject { |line| line.start_with?('rogue') } }
      check.call('built and ran', built)
      check.call('runtime parity (every non-rogue row)', !compiled.empty? && plain.call(compiled) == plain.call(interpreted))
      check.call('interpreted rogue definition runs', rogue.call(interpreted).include?('"rogue"'))
      check.call('compiled rogue definition is an owner violation',
                 rogue.call(compiled).include?('BC2cppGuardViolation') && rogue.call(compiled).include?('closed-world owner violation'))
      warn output unless failures.empty?
    else
      puts '  SKIP run: no full-core mruby build'
    end
  end
end

# Withdrawals: each world leaves `delete` kept. An outside source joins the closed world as a gem of the build, whose
# src/ and mrblib/ the closed world scans.
withdraw = lambda do |label, files = {}|
  Dir.mktmpdir('outside-owner-call-w') do |dir|
    gem = File.join(dir, 'rogue_gem')
    files.each { |path, text| FileUtils.mkdir_p(File.dirname(File.join(gem, path))) && File.write(File.join(gem, path), text) }
    options = files.empty? ? {} : { build_gems: [['rogue-gem', gem]] }
    code, = runtime.generate(SOURCE, dir, only_owners: OWNERS, **options)
    del = body.call(code, 'del')
    check.call("#{label}: delete keeps its by-name else", del.include?('kept: core_or_native') && !del.include?('bc2cpp_owner_call('))
  end
end
withdraw.call('native owner not nameable', 'src/rogue_owner.c' => <<~C)
  #include <mruby.h>
  static mrb_value rogue(mrb_state* mrb, mrb_value self) { return self; }
  void rogue_install(mrb_state* mrb, struct RClass* target) {
    mrb_define_method(mrb, target, "delete", rogue, MRB_ARGS_REQ(1));
  }
C
withdraw.call('outside Ruby owner not nameable', 'mrblib/rogue_owner.rb' => "HOLDER = Object.new\ndef HOLDER.delete(x) = x\n")
Dir.mktmpdir('outside-owner-call-mm') do |dir|
  code, = runtime.generate("#{SOURCE}\nclass Ghost\n  def method_missing(n, *a) = n\n  def respond_to_missing?(n, p = false) = true\nend\n",
                           dir, only_owners: OWNERS)
  pk = body.call(code, 'pk')
  check.call('a method_missing class makes every owner set unknown: pack keeps its by-name send',
             pk.include?('bc2cpp_send(') && !pk.include?('bc2cpp_owner_call('))
end
begin
  ENV['BC2CPP_NATIVE_OWNER_MAP'] = '0'
  withdraw.call('owner map off')
ensure
  ENV.delete('BC2CPP_NATIVE_OWNER_MAP')
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp outside owner call check: PASS'

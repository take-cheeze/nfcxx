#!/usr/bin/env ruby
# frozen_string_literal: true

# TouchScan's native funcall names (tools/bc2cpp/touch_scan.rb, NATIVE_HELPER and native_declarator?): a send whose
# name is a static helper's parameter is the set of names its calls spell, and a prototype is not a send. Anything
# the scan cannot enumerate must still give up, which makes every class the file names opaque.
require_relative '../../tools/bc2cpp/closed_world'

failures = []
checks = 0
check = lambda do |label, ok|
  checks += 1
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{label}"
  failures << label unless ok
end
open = ->(text) { !TouchScan.native(text, %w[Font]).reasons.empty? }

helper = <<~C
  static mrb_value attr_read(mrb_state* M, mrb_value obj, mrb_sym reader) {
    struct RClass* c = mrb_class(M, obj);
    const mrb_method_t m = mrb_method_search_vm(M, &c, reader);
    if (MRB_METHOD_UNDEF_P(m)) return mrb_funcall_argv(M, obj, reader, 0, nullptr);
    return mrb_funcall_with_method(M, obj, reader, &m, c, 0, nullptr, mrb_nil_value());
  }
C
calls = <<~C
  mrb_value font_size(mrb_state* M, mrb_value f) {
    mrb_value a = attr_read(M, f, mrb_intern_lit(M, "size"));
    return attr_read(M, f, MRB_SYM(bold));
  }
C

check.call('a static helper whose calls spell every name is closed', !open.call(helper + calls))
check.call('the names are those of the calls',
           TouchScan.native_facts(helper + calls)[:events].select { |e| e[3] }.map { |e| e[3] }.uniq == [%w[size bold]])
check.call('a call passing a computed name keeps it open',
           open.call(helper + calls + "mrb_value g(mrb_state* M, mrb_value f, mrb_sym s) { return attr_read(M, f, s); }\n"))
check.call('a pointer to the helper keeps it open',
           open.call(helper + calls + "static mrb_value (*ptr)(mrb_state*, mrb_value, mrb_sym) = attr_read;\n"))
check.call('a non-static helper keeps it open', open.call(helper.sub('static ', '') + calls))
check.call('an assignment to the parameter keeps it open',
           open.call(helper.sub('struct RClass* c', 'reader = MRB_SYM(include);\n  struct RClass* c') + calls))
check.call('a helper call spelling a class-shaping send gives up',
           open.call(helper + calls.sub('MRB_SYM(bold)', 'MRB_SYM(include)')))
check.call('a helper call spelling `new` on an unresolved receiver gives up',
           open.call(helper + calls.sub('MRB_SYM(bold)', 'MRB_SYM(new)')))
check.call('a computed name outside any helper gives up',
           open.call("mrb_value f(mrb_state* M, mrb_value o) { mrb_sym s = pick(); return mrb_funcall_argv(M, o, s, 0, 0); }\n"))

prototype = <<~C
  MRB_BEGIN_DECL
  mrb_value mrb_funcall_with_method(mrb_state*,
                                    mrb_value,
                                    mrb_sym,
                                    const mrb_method_t*,
                                    struct RClass*,
                                    mrb_int,
                                    const mrb_value*,
                                    mrb_value);
  MRB_END_DECL
C
check.call('a prototype of a funcall function is not a send', !open.call(prototype))
check.call('a definition of a funcall function is not a send',
           !open.call("mrb_value mrb_funcall_argv(mrb_state *mrb, mrb_value self, mrb_sym mid, mrb_int argc, const mrb_value *argv) {\n  return self;\n}\n"))
check.call('a returned call is still a send', open.call("mrb_value f(mrb_state* M, mrb_value o, mrb_sym s) {\n  return mrb_funcall_argv(M, o, s, 0, 0);\n}\n"))
check.call('a call statement is still a send', open.call("void f(mrb_state* M, mrb_value o, mrb_sym s) {\n  mrb_funcall_argv(M, o, s, 0, 0);\n}\n"))

abort "touch scan native helper check: #{failures.size} of #{checks} failed" unless failures.empty?
puts "touch scan native helper check: #{checks} checks passed"

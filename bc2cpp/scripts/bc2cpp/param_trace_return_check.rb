#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the BC2CPP_TRACE_PARAMS return tracing (tools/bc2cpp/param_trace.rb) on a generated-C++ fixture:
# every `return` of a traced `_impl` is wrapped in bc2cpp_ret_hit_<sym>, the lambda inside a body is left
# alone, and the static return fact rides in the site's meta row.
#
#   ruby scripts/bc2cpp/param_trace_return_check.rb

$LOAD_PATH.unshift(File.expand_path('../../tools/bc2cpp', __dir__))
require 'param_trace'

failures = []
check = ->(name, ok) { failures << name unless ok }

src = <<~CPP
  mrb_value Foo_bar_impl(mrb_state* M, mrb_value self) {
    mrb_value r0 = self;
    if (r0 == 0) return mrb_nil_value();
    mrb_value r1 = [&]() { return mrb_fixnum_value(3); }();
    return r1;
  }
  mrb_value Foo_baz_impl(mrb_state* M, mrb_value self, mrb_value x) {
    mrb_value r0 = self;
    return x;
  }
CPP
facts = -> { Hash.new { |h, k| h[k] = [] } }
infos = {
  'Foo_bar_impl' => { method: 'Foo#bar', mand: 0, opt: 0, rest: false, mono: true, defs: 1, facts: facts.call, ret: 'none' },
  'Foo_baz_impl' => { method: 'Foo#baz', mand: 1, opt: 0, rest: false, mono: true, defs: 1, facts: facts.call, ret: 'fixnum' }
}
text, summary = ParamTrace.instrument(src, 'fixture', infos)
rets = summary[:rets]

check.call('two returns of Foo#bar wrapped, the lambda return is not', rets.count { |r| r[:meta].include?('Foo#bar') } == 2 &&
  text.include?('return bc2cpp_ret_hit_fixture(M, 0, mrb_nil_value());') &&
  text.include?('return bc2cpp_ret_hit_fixture(M, 1, r1);') &&
  text.include?('{ return mrb_fixnum_value(3); }'))
check.call('return of Foo#baz wrapped with its static fact', rets.any? { |r| r[:meta].include?('Foo#baz') && r[:meta].end_with?('ret=fixnum') } &&
  text.include?('return bc2cpp_ret_hit_fixture(M, 2, x);'))
check.call('return ordinals are distinct per function', rets.map { |r| r[:meta] }.uniq.size == rets.size)
check.call('the recorder is declared before the first use', text.index('bc2cpp_ret_hit_fixture(mrb_state') < text.index('return bc2cpp_ret_hit_fixture(M, 0'))

if failures.empty?
  puts 'param trace return check: PASS'
else
  warn "param trace return check: FAIL\n  #{failures.join("\n  ")}"
  exit 1
end

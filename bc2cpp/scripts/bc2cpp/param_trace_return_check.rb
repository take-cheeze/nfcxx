#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the BC2CPP_TRACE_TYPES return tracing (tools/bc2cpp/param_trace.rb) on a generated-C++ fixture:
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

# A short body must not reach into the next function: the register line search stops at the closing brace.
short = <<~CPP
  mrb_value Foo_short_impl(mrb_state* M, mrb_value self, mrb_value it) {
    return it;
  }
  mrb_value Foo_next_impl(mrb_state* M, mrb_value self) {
    mrb_value r0 = self;
    return r0;
  }
CPP
short_infos = {
  'Foo_short_impl' => { method: 'Foo#short', mand: 1, opt: 0, rest: false, mono: true, defs: 1, facts: facts.call, ret: 'none' },
  'Foo_next_impl' => { method: 'Foo#next', mand: 0, opt: 0, rest: false, mono: true, defs: 1, facts: facts.call, ret: 'none' }
}
short_text, _short_summary = ParamTrace.instrument(short, 'fixture', short_infos)
check.call('a function with no register line of its own gets no parameter hit',
           !short_text.include?('bc2cpp_param_hit_fixture(M, 0, it)'))

# The receiver of a singleton method is a `self` site (kind self, index 0) ahead of its parameters, keyed by the
# class object; an instance method has none. The site is not a positional parameter: x stays `req` index 1.
singleton_src = <<~CPP
  mrb_value Foo_make_impl(mrb_state* M, mrb_value self, mrb_value n) {
    mrb_value r0 = self;
    return n;
  }
  mrb_value Foo_plain_impl(mrb_state* M, mrb_value self, mrb_value n) {
    mrb_value r0 = self;
    return n;
  }
CPP
singleton_infos = {
  'Foo_make_impl' => { method: 'Foo.singleton#make', mand: 1, opt: 0, rest: false, mono: true, defs: 1, facts: facts.call,
                       ret: 'none', singleton: true },
  'Foo_plain_impl' => { method: 'Foo#plain', mand: 1, opt: 0, rest: false, mono: true, defs: 1, facts: facts.call,
                        ret: 'none', singleton: false }
}
singleton_text, singleton_summary = ParamTrace.instrument(singleton_src, 'fixture', singleton_infos)
self_sites = singleton_summary[:sites].select { |s| s[:kind] == 'self' }
check.call('a singleton method gets one self site, keyed by the method and named self',
           self_sites.size == 1 && self_sites.first[:method] == 'Foo.singleton#make' && self_sites.first[:index] == 0 &&
             self_sites.first[:meta].split("\t").values_at(5, 6) == %w[self none:self])
check.call('the self hit is recorded through bc2cpp_self_hit with the receiver before the parameter hit',
           singleton_text.include?('bc2cpp_self_hit_fixture(M, 0, self);') &&
             singleton_text.include?('bc2cpp_param_hit_fixture(M, 1, n);') &&
             singleton_text.index('bc2cpp_self_hit_fixture(M, 0, self);') < singleton_text.index('bc2cpp_param_hit_fixture(M, 1, n);'))
check.call('an instance method gets no self site and its parameter stays site 0',
           singleton_summary[:sites].none? { |s| s[:method] == 'Foo#plain' && s[:kind] == 'self' } &&
             singleton_text.include?('bc2cpp_param_hit_fixture(M, 2, n);'))
check.call('the self hit helper keys the site by the class object and names non-classes as one bucket',
           singleton_text.include?('static inline void bc2cpp_self_hit_fixture(mrb_state* M, unsigned site, mrb_value v)') &&
             singleton_text.include?('(mrb_class_p(v) || mrb_module_p(v)) ? mrb_class_ptr(v) : NULL') &&
             singleton_text.include?('"(non-class)"'))

if failures.empty?
  puts 'param trace return check: PASS'
else
  warn "param trace return check: FAIL\n  #{failures.join("\n  ")}"
  exit 1
end

#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the BC2CPP_TRACE_TYPES return, ivar and constant tracing (tools/bc2cpp/param_trace.rb) on a generated-C++ fixture:
# every `return` of a traced `_impl` is wrapped in bc2cpp_ret_hit_<sym>, the lambda inside a body is left
# alone, and the static return fact rides in the site's meta row. A GETIV marker becomes an ivar hit, a GETCONST or
# GETMCNST marker a constant hit.
#
#   ruby scripts/bc2cpp/param_trace_return_check.rb

$LOAD_PATH.unshift(File.expand_path('../../tools/bc2cpp', __dir__))
require 'param_trace'
require 'codegen_insn'

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

# GETIV markers (codegen_insn.rb ivar_trace_marker): a marker after a read in a traced _impl becomes an ivar hit, named
# by its owner class and ivar; a marker in an untraced function stays a comment, so it is never a hit with no row.
ivar_src = <<~CPP
  mrb_value Foo_get_impl(mrb_state* M, mrb_value self) {
    mrb_value r0 = self;
    mrb_value r1 = mrb_iv_get(M, self, mrb_intern_cstr(M, "@hp"));
    /*BC2CPP_IVAR_HIT Foo @hp r1*/
    return r1;
  }
  mrb_value Stray_impl(mrb_state* M, mrb_value self) {
    mrb_value r0 = self;
    mrb_value r1 = mrb_iv_get(M, self, mrb_intern_cstr(M, "@x"));
    /*BC2CPP_IVAR_HIT Stray @x r1*/
    return r1;
  }
CPP
ivar_infos = {
  'Foo_get_impl' => { method: 'Foo#get', mand: 0, opt: 0, rest: false, mono: true, defs: 1, facts: facts.call, ret: 'none' }
}
ivar_text, ivar_summary = ParamTrace.instrument(ivar_src, 'fixture', ivar_infos)
ivars = ivar_summary[:ivars]
check.call('a marker in a traced _impl is rewritten into a hit on its register, in place',
           ivar_text.include?("mrb_value r1 = mrb_iv_get(M, self, mrb_intern_cstr(M, \"@hp\"));\n  bc2cpp_ivar_hit_fixture(M, 0, r1);\n"))
check.call('one ivar site, named by its owner and ivar', ivars.size == 1 && ivars.first[:owner] == 'Foo' && ivars.first[:ivar] == '@hp')
check.call('a marker in an untraced function stays a comment and is not a site',
           ivar_text.include?('/*BC2CPP_IVAR_HIT Stray @x r1*/') && ivars.size == 1)
check.call('the ivar site table and its dump rows are generated', ivar_text.include?('bc2cpp_ivar_sites_fixture[1]') &&
           ivar_text.include?('"IVAR_SITE\\t%s') && ivar_text.include?('"IVAR_CLASS\\t%s') && ivar_text.include?('"Foo\\011@hp"'))

# Without any marker the ivar table is empty and the output has no hit call (the untraced output is unchanged otherwise).
plain_text, plain_summary = ParamTrace.instrument(src, 'fixture', infos)
check.call('a file with no ivar marker has no ivar sites and no ivar hit call',
           plain_summary[:ivars].empty? && !plain_text.include?('bc2cpp_ivar_hit_fixture(M, '))

# The codegen side: a marker only for a known, non-singleton owner under BC2CPP_TRACE_TYPES=1, so the untraced output
# is byte-identical.
gen = CodeGen.allocate
traced = ENV['BC2CPP_TRACE_TYPES']
begin
  ENV['BC2CPP_TRACE_TYPES'] = '1'
  check.call('a GETIV of a known class leaves its marker under BC2CPP_TRACE_TYPES=1',
             gen.send(:ivar_trace_marker, 'Foo', 'hp', 3) == "  /*BC2CPP_IVAR_HIT Foo @hp r3*/\n")
  check.call('a singleton owner or an unknown class leaves no marker',
             gen.send(:ivar_trace_marker, 'Foo.singleton', 'hp', 3).empty? && gen.send(:ivar_trace_marker, nil, 'hp', 3).empty?)
  ENV.delete('BC2CPP_TRACE_TYPES')
  check.call('without BC2CPP_TRACE_TYPES=1 no marker is emitted', gen.send(:ivar_trace_marker, 'Foo', 'hp', 3).empty?)
ensure
  traced ? ENV['BC2CPP_TRACE_TYPES'] = traced : ENV.delete('BC2CPP_TRACE_TYPES')
end

# CONST markers (codegen_insn.rb const_trace_marker): a marker after a constant read in a traced _impl becomes a constant
# hit, one site per read, named by the owner it resolved to (`-` when unproven) and the name as written. An untraced
# function keeps the comment, and the untraced output has no constant table row.
const_src = <<~CPP
  mrb_value Foo_lim_impl(mrb_state* M, mrb_value self) {
    mrb_value r0 = self;
    mrb_value r1 = mrb_const_get(M, self, mrb_intern_cstr(M, "LIMIT"));
    /*BC2CPP_CONST_HIT Game::Foo::LIMIT LIMIT r1*/
    mrb_value r2 = mrb_const_get(M, self, mrb_intern_cstr(M, "MAX"));
    /*BC2CPP_CONST_HIT - MAX r2*/
    return r1;
  }
  mrb_value Stray_impl(mrb_state* M, mrb_value self) {
    mrb_value r0 = self;
    mrb_value r1 = mrb_const_get(M, self, mrb_intern_cstr(M, "ZZ"));
    /*BC2CPP_CONST_HIT Stray::ZZ ZZ r1*/
    return r1;
  }
CPP
const_infos = {
  'Foo_lim_impl' => { method: 'Foo#lim', mand: 0, opt: 0, rest: false, mono: true, defs: 1, facts: facts.call, ret: 'none' }
}
const_text, const_summary = ParamTrace.instrument(const_src, 'fixture', const_infos)
const_sites = const_summary[:consts]
check.call('a constant marker in a traced _impl is rewritten into a hit on its register, in place',
           const_text.include?("mrb_value r1 = mrb_const_get(M, self, mrb_intern_cstr(M, \"LIMIT\"));\n  bc2cpp_const_hit_fixture(M, 0, r1);\n") &&
             const_text.include?("  bc2cpp_const_hit_fixture(M, 1, r2);\n"))
check.call('two constant sites, one per read, named by the resolved owner (or `-`) and the name as written',
           const_sites.size == 2 && const_sites[0][:key] == 'Game::Foo::LIMIT' && const_sites[0][:written] == 'LIMIT' &&
             const_sites[1][:key] == '-' && const_sites[1][:written] == 'MAX')
check.call('a constant marker in an untraced function stays a comment and is not a site',
           const_text.include?('/*BC2CPP_CONST_HIT Stray::ZZ ZZ r1*/') && const_sites.size == 2)
check.call('the constant site table and its dump rows are generated',
           const_text.include?('bc2cpp_const_sites_fixture[2]') && const_text.include?('"CONST_SITE\\t%s') &&
             const_text.include?('"CONST_CLASS\\t%s') && const_text.include?('"Game::Foo::LIMIT\\011LIMIT"') &&
             const_text.include?('"-\\011MAX"'))
plain_const_text, plain_const_summary = ParamTrace.instrument(src, 'fixture', infos)
check.call('a file with no constant marker has no constant sites and no constant hit call',
           plain_const_summary[:consts].empty? && !plain_const_text.include?('bc2cpp_const_hit_fixture(M, ') &&
             plain_const_text.include?('bc2cpp_const_sites_fixture[1]'))

# The codegen side of the constant marker: only under BC2CPP_TRACE_TYPES=1, and `-` without a closed-world proof.
read = Struct.new(:op, :const_name, :mcnst_name, :reg).new('GETCONST', 'LIMIT', nil, 4)
scoped = Struct.new(:op, :const_name, :mcnst_name, :reg).new('GETMCNST', nil, 'MAX', 5)
begin
  ENV['BC2CPP_TRACE_TYPES'] = '1'
  check.call('a constant read without a closed world leaves an unproven marker (the written name, the register)',
             gen.send(:const_trace_marker, read) == "  /*BC2CPP_CONST_HIT - LIMIT r4*/\n" &&
               gen.send(:const_trace_marker, scoped) == "  /*BC2CPP_CONST_HIT - MAX r5*/\n")
  ENV.delete('BC2CPP_TRACE_TYPES')
  check.call('without BC2CPP_TRACE_TYPES=1 no constant marker is emitted', gen.send(:const_trace_marker, read).empty?)
ensure
  traced ? ENV['BC2CPP_TRACE_TYPES'] = traced : ENV.delete('BC2CPP_TRACE_TYPES')
end

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

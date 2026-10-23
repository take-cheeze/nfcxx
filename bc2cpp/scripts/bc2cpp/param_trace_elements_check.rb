#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the element sampling of BC2CPP_TRACE_TYPES (tools/bc2cpp/param_trace.rb) on a generated fixture. The
# sampler reads the first ParamTrace::ELEM_SAMPLE elements of an Array (entries of a Hash), so a 9th or later
# element is joined into the slot's classes, and an element past the sample is counted as overflow, never dropped:
# an overflowed slot is left out of every candidate. The C side is compiled and run against the host libmruby when
# 3rd/mruby/build/host/lib/libmruby.a exists (otherwise only the generated text is checked).
#
#   bundle exec ruby scripts/bc2cpp/param_trace_elements_check.rb

require 'tmpdir'
require 'open3'
require 'rbconfig'

$LOAD_PATH.unshift(File.expand_path('../../tools/bc2cpp', __dir__))
require 'param_trace'

ROOT = File.expand_path('../..', __dir__)
failures = []
check = ->(name, ok) { failures << name unless ok }

SOURCE = <<~CPP
  mrb_value Foo_take_impl(mrb_state* M, mrb_value self, mrb_value arr) {
    mrb_value r0 = self;
    return r0;
  }
CPP
INFOS = {
  'Foo_take_impl' => { method: 'Foo#take', mand: 1, opt: 0, rest: false, mono: true, defs: 1,
                       facts: Hash.new { |h, k| h[k] = [] }, ret: 'none' }
}.freeze

text, _summary = ParamTrace.instrument(SOURCE, 'fixture', INFOS)
check.call("the sample is #{ParamTrace::ELEM_SAMPLE} in the generated code",
           text.include?("#define BC2CPP_ELEM_SAMPLE #{ParamTrace::ELEM_SAMPLE}\n"))
check.call('the sample bound is a min, not a loop stop (the tail goes to overflow)',
           text.include?('mrb_int m = n < BC2CPP_ELEM_SAMPLE ? n : BC2CPP_ELEM_SAMPLE;') &&
           text.include?('t[0].overflow += n - m;') && text.include?('t[1].overflow += n - m;') &&
           text.include?('t[2].overflow += n - m;'))
check.call('the parameter is traced', text.include?('bc2cpp_param_hit_fixture(M, 0, arr)'))

libmruby = File.join(ROOT, '3rd/mruby/build/host/lib/libmruby.a')
includes = [File.join(ROOT, 'include'), File.join(ROOT, '3rd/mruby/include'), File.join(ROOT, '3rd/mruby/build/host/include')]
if File.exist?(libmruby) && File.exist?(File.join(ROOT, '3rd/mruby/build/host/include/mrbconf.h'))
  driver = <<~CPP
    #include <cstdio>
    #include <mruby/string.h>
    #include <mruby/array.h>
    // A 12-element Array with a String at index 10 (the 11th element, past the first ten), and a 40-element Array
    // with a Symbol at index 35, past the sample: the Symbol is not sampled, so it reads as overflow.
    static mrb_value make(mrb_state* M, int n, int at, mrb_value odd) {
      mrb_value a = mrb_ary_new(M);
      for (int i = 0; i < n; i++) mrb_ary_push(M, a, i == at ? odd : mrb_fixnum_value(i));
      return a;
    }
    int main() {
      mrb_state* M = mrb_open();
      Foo_take_impl(M, mrb_nil_value(), make(M, 12, 10, mrb_str_new_cstr(M, "x")));
      Foo_take_impl(M, mrb_nil_value(), make(M, 40, 35, mrb_symbol_value(mrb_intern_cstr(M, "s"))));
      mrb_close(M);
      return 0;
    }
  CPP
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'fixture.cxx'), text + driver)
    dump = File.join(dir, 'trace.tsv')
    cxx = ENV.fetch('CXX', 'c++')
    flags = includes.flat_map { |i| ['-I', i] }
    out, status = Open3.capture2e(cxx, '-std=c++17', '-O1', *flags, '-o', File.join(dir, 'fixture'),
                                  File.join(dir, 'fixture.cxx'), libmruby, '-lm')
    check.call("the trace fixture compiles and links (#{out.lines.first(3).join.strip})", status.success?)
    if status.success?
      ran, = Open3.capture2e({ 'BC2CPP_TRACE_TYPES_OUT' => dump }, File.join(dir, 'fixture'))
      rows = File.exist?(dump) ? File.readlines(dump, chomp: true).map { |l| l.split("\t", -1) } : []
      elem = rows.select { |f| f[0] == 'PARAM_ELEM_SITE' && f[3] == 'array' }
      cls = rows.select { |f| f[0] == 'PARAM_ELEM_CLASS' && f[3] == 'array' }
      classes = cls.to_h { |f| [f[4], f[5].to_i] }
      check.call("the fixture runs and dumps the array slot (#{ran.lines.first(2).join.strip})", elem.size == 1)
      # Sampled: 12 elements all, and 32 of the 40 (the rest overflow). Integer 11 + 31, String 1, no Symbol.
      check.call('the 11th element (a String, past the first ten) is joined into the element classes',
                 classes['String'] == 1)
      check.call('the sampled elements are counted, the first 32 of 40 and all 12', elem.any? { |f| f[4].to_i == 44 })
      check.call('an element past the sample is not claimed: the slot overflows by the unsampled tail (8)',
                 elem.any? { |f| f[5].to_i == 8 })
      check.call('the unsampled Symbol is absent from the classes', !classes.key?('Symbol'))
    end
  end
else
  puts "  SKIP run: no #{libmruby} (build 3rd/mruby with `bundle exec rake` in 3rd/mruby)"
end

if failures.empty?
  puts 'param trace elements check: PASS'
else
  warn "param trace elements check: FAIL\n  #{failures.join("\n  ")}"
  exit 1
end

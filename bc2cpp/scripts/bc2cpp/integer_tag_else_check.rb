#!/usr/bin/env ruby
# frozen_string_literal: true

# Check ADR 0394 (INTEGER_TAG_ELSE): the by-name else of an Integer-tag guard on an index argument becomes a direct call
# to the native Array body (mrb_ary_aget1_impl / mrb_ary_aset2_impl) when the receiver is exactly Array and the closed
# world answers the name with that body alone.
#
# 1. The emitter, driven in process: the kill switch, each refusal reason counted, and the direct text.
# 2. Generated code (needs MRBC): a positive compiles to the direct call; each negative keeps the by-name else and
#    counts its refusal; the kill switch and every refused fixture are byte-identical to the baseline tool
#    (BC2CPP_BASE_TOOL: a bc2cpp.rb from origin/master, e.g. `git archive origin/master tools | tar -x -C DIR`).
# 3. Mutant (MUTANT=1): the ancestor-definer rule (both of its lines) removed; the refused fixture must then emit the direct call,
#    which this check reports as a kill.
#
# Usage: MRBC=path/to/mrbc BC2CPP_BASE_TOOL=path/to/base/bc2cpp.rb ruby scripts/bc2cpp/integer_tag_else_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# -- 1. the emitter, in process --------------------------------------------------------------------
require File.join(runtime::ROOT, 'tools/bc2cpp/bc2cpp')
cg = CodeGen.allocate
cg.instance_variable_set(:@integer_tag_else_counts, nil)
cg.define_singleton_method(:index_closed_world?) { true }
cg.define_singleton_method(:integer_tag_else_array_refusal) { |_name| @stub_refusal }

ENV.delete('BC2CPP_INTEGER_TAG_ELSE')
cg.instance_variable_set(:@stub_refusal, nil)
text = cg.integer_tag_else_array_call('[]', true, 'r3', ['r4'])
check.call('a proven exact Array and no refusal: the direct call text', text == 'mrb_ary_aget1_impl(M, r3, r4)')
check.call('the direct call records its body for the prototype', cg.instance_variable_get(:@integer_tag_else_bodies_used) == Set['[]'])
check.call('[]= takes the index and the value',
           cg.integer_tag_else_array_call('[]=', true, 'r3', %w[r4 r5]) == 'mrb_ary_aset2_impl(M, r3, r4, r5)')
check.call('a receiver not proven exact keeps the by-name else (counted)',
           cg.integer_tag_else_array_call('[]', false, 'r3', ['r4']).nil? &&
           cg.integer_tag_else_counts[['[]', :receiver_not_exact]] == 1)
%i[unbounded singleton_definer no_native_array ancestor_definer module_definer arm_not_linked arm_unverified
   blocked_name disabled].each do |reason|
  cg.instance_variable_set(:@stub_refusal, reason)
  got = cg.integer_tag_else_array_call('[]', true, 'r3', ['r4'])
  check.call("refusal #{reason}: no direct text, counted", got.nil? && cg.integer_tag_else_counts[['[]', reason]] == 1)
end
cg.instance_variable_set(:@stub_refusal, nil)
ENV['BC2CPP_INTEGER_TAG_ELSE'] = '0'
before = cg.integer_tag_else_counts.values.sum
check.call('BC2CPP_INTEGER_TAG_ELSE=0: no direct text and nothing counted',
           cg.integer_tag_else_array_call('[]', true, 'r3', ['r4']).nil? && cg.integer_tag_else_counts.values.sum == before)
ENV.delete('BC2CPP_INTEGER_TAG_ELSE')

# -- 2. generated code -----------------------------------------------------------------------------
abort 'SKIP: set MRBC' unless ENV['MRBC']
DIRECT = /mrb_ary_aget1_impl\(M, r\d+|mrb_ary_aset2_impl\(M, r\d+/.freeze

POSITIVE = <<~RUBY
  class Probe
    def get(i)
      a = [1, 2, 3]
      a[i]
    end

    def put(i, v)
      a = [1, 2, 3]
      a[i] = v
    end
  end
RUBY

# A literal receiver is exact (INDEX_EXACT), so the Array branch is reached; a parameter receiver is not. A prepended
# module defines `[]` for every Array, which is the ancestor case the check refuses; an included module never overrides
# Array's own `[]`, and a definer on Object is unbounded, so those two only assert the by-name else and the bytes.
EXACT_PROBE = <<~RUBY
  class Probe
    def get(i)
      a = [1, 2, 3]
      a[i]
    end
  end
RUBY
PARAM_PROBE = <<~RUBY
  class Probe
    def get(a, i)
      a[i]
    end
  end
RUBY
# A subclass of Array with its own `[]` is not on the exact Array's ancestry: the direct call still applies.
SUBCLASS_DEFINER = <<~RUBY
  class Sub < Array
    def [](k)
      0
    end
  end
RUBY
NEGATIVES = {
  ancestor_definer: ["module Mx\n  def [](k)\n    k\n  end\nend\nclass Array\n  prepend Mx\nend\n" + EXACT_PROBE, 'ancestor_definer'],
  object_definer: ["class Object\n  def [](k)\n    k\n  end\nend\n" + EXACT_PROBE, nil],
  receiver_not_exact: [PARAM_PROBE, nil]
}.freeze

def generated(source, dir, tool: nil, env: {})
  saved = ENV.to_h.slice(*env.keys)
  env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  prev = Bc2cppFixtureRuntime::BC2CPP
  Bc2cppFixtureRuntime.send(:remove_const, :BC2CPP)
  Bc2cppFixtureRuntime.const_set(:BC2CPP, tool || prev)
  Bc2cppFixtureRuntime.generate(source, dir, closed: true, only_owners: %w[Probe])
ensure
  Bc2cppFixtureRuntime.send(:remove_const, :BC2CPP) if Bc2cppFixtureRuntime.const_defined?(:BC2CPP, false)
  Bc2cppFixtureRuntime.const_set(:BC2CPP, prev)
  saved.each { |k, v| ENV[k] = v }
  env.each_key { |k| ENV.delete(k) unless saved.key?(k) }
end

summary = ->(err) { err[/== integer-tag else \(INTEGER_TAG_ELSE, ADR 0394\): (.*) ==/, 1].to_s }
base = ENV['BC2CPP_BASE_TOOL']
# The reference for "unchanged" fixtures: the baseline tool when given, else this tool with the kill switch.
reference = lambda do |source, dir|
  if base && File.file?(base)
    generated(source, dir, tool: base)
  else
    generated(source, dir, env: { 'BC2CPP_INTEGER_TAG_ELSE' => '0' })
  end
end

Dir.mktmpdir('bc2cpp-ite') do |work|
  code, err = generated(POSITIVE, File.join(work, 'pos'))
  check.call('positive: the exact Array index else calls mrb_ary_aget1_impl / mrb_ary_aset2_impl',
             code.scan(DIRECT).size >= 2)
  check.call('positive: the prototype is declared at file scope, extern "C"',
             code.include?('extern "C" mrb_value mrb_ary_aget1_impl(mrb_state*, mrb_value, mrb_value);'))
  check.call("positive: stderr counts the direct sites (#{summary.call(err)})", summary.call(err).start_with?('direct '))
  off_code, = generated(POSITIVE, File.join(work, 'pos-off'), env: { 'BC2CPP_INTEGER_TAG_ELSE' => '0' })
  check.call('kill switch: no direct call and no prototype', !off_code.match?(DIRECT) && !off_code.include?('mrb_ary_aget1_impl(mrb_state*'))
  if base && File.file?(base)
    base_code, = generated(POSITIVE, File.join(work, 'pos-base'), tool: base)
    check.call('kill switch: byte-identical to the baseline tool', off_code == base_code)
  end

  sub_code, sub_err = generated(SUBCLASS_DEFINER + POSITIVE, File.join(work, 'subclass'))
  check.call("positive: a subclass's own [] does not block the exact Array's direct call (#{summary.call(sub_err)})",
             sub_code.scan(DIRECT).size >= 2)

  NEGATIVES.each do |name, (prelude, expected)|
    src = prelude
    ncode, nerr = generated(src, File.join(work, name.to_s))
    check.call("negative #{name}: no direct call#{expected ? ", refusal #{expected} counted" : ''} (#{summary.call(nerr)})",
               !ncode.match?(DIRECT) && (expected.nil? || summary.call(nerr).include?(expected)))
    bcode, = reference.call(src, File.join(work, "#{name}-ref"))
    check.call("negative #{name}: byte-identical to #{base && File.file?(base) ? 'the baseline tool' : 'the kill switch'}",
               ncode == bcode)
  end

  if ENV['MUTANT'] == '1'
    mut = File.join(work, 'mutant')
    FileUtils.mkdir_p(mut)
    # A whole tree (the lint reads scripts/ and the sources beside them) without 3rd/ and the build directories.
    abort 'copy failed' unless system("tar --exclude=./3rd --exclude='./build*' -C #{runtime::ROOT} -cf - . | tar -x -C #{mut}")
    file = File.join(mut, 'tools/bc2cpp/codegen_integer_tag_else.rb')
    text = File.read(file)
    # The whole ancestor rule: a prepended module is also a module definer, so both lines go.
    text.sub!(/    return :ancestor_definer if .*\n/, '').sub!(/    return :module_definer unless .*\n/, '')
    File.write(file, text)
    mcode, = generated(NEGATIVES[:ancestor_definer].first, File.join(work, 'mutant-run'),
                       tool: File.join(mut, 'tools/bc2cpp/bc2cpp.rb'))
    check.call('mutant (ancestor check dropped) is killed: the refused fixture then emits the direct call',
               mcode.match?(DIRECT))
  end
end

puts failures.empty? ? 'PASS' : "FAILED: #{failures.size}"
exit(failures.empty? ? 0 : 1)

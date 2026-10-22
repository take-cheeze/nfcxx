#!/usr/bin/env ruby
# frozen_string_literal: true

# Behaviour oracle for the sealed int16 local array (the design in progress for bc2cpp): a local array
# literal of int16-range values, indexed and stored inside one method, must answer the same as the interpreter.
# The rows cover the sealed shape, a store that is out of int16 range (the generic path must still answer
# correctly), an out-of-bounds read (nil), size, and negative int16 bounds.
#
#   1. run (full-core mruby), interpreted against compiled: every row prints the same value on both sides, and
#      each value matches the value written here.
#
# This check is parity-only. A generated-code check that the sealed array is a std::vector<int16_t> is added
# with the emitter arm, not before it exists.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/sealed_int16_local_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/sealed_int16_locals'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']

SOURCE = <<~RUBY
  class SealedInt16
    def sum3
      a = [1, 2, 3]
      a[1] = 40
      a[0] + a[1] + a[2]
    end

    def spill
      a = [1, 2]
      a[1] = 70000
      a[1]
    end

    def oob
      a = [5]
      a[3]
    end

    def sized
      a = [4, 5, 6]
      a.size
    end

    def neg
      a = [-1, -32768, 32767]
      a[0] + a[1] + a[2]
    end
  end
RUBY
OWNERS = %w[SealedInt16].freeze

# The expected value of each row, as the interpreter prints it.
EXPECTED = {
  'SealedInt16.new.sum3' => '44',
  'SealedInt16.new.spill' => '70000',
  'SealedInt16.new.oob' => 'nil',
  'SealedInt16.new.sized' => '3',
  'SealedInt16.new.neg' => '-2',
}.freeze

Dir.mktmpdir('sealed-int16-local') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'sealed_int16_local.cxx'), code) if ENV['BC2CPP_KEEP_DIR']

  # The method body of one generated function, as the emitter writes it.
  body = ->(fn) { code[/^mrb_value #{fn}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
  # With BC2CPP_SEALED_INT16=1, sum3's literal array is a std::vector and spill's out-of-range store refuses it.
  # With the switch off, no method is rewritten.
  sum3 = body.call('SealedInt16_sum3')
  spill = body.call('SealedInt16_spill')
  if SealedInt16Locals.enabled?
    check.call('sum3: the literal array is a std::vector<int16_t> (sealed)',
               sum3.include?('std::vector<int16_t>{ 1, 2, 3 }') && !sum3.include?('mrb_ary_new'))
    check.call('spill: the out-of-int16 store refuses the array (generic Array path)',
               !spill.include?('std::vector<int16_t>') && spill.include?('mrb_ary_new_from_values'))
    # NUMERIC_INTERVAL_OPERANDS: the elements' int16 interval makes sum3's additions Fixnum operations.
    check.call('sum3: the element reads are proven Fixnum (no mrb_funcall fallback on the additions)',
               sum3.scan('operands proven Fixnum').size >= 2 && !sum3.include?('mrb_funcall(M, r3, "+"'))
  else
    check.call('switch off: no method is rewritten to a std::vector',
               !code.include?('std::vector<int16_t>'))
  end

  unless ENV['CC_GENERATED_ONLY'] == '1'
    harness = <<~'CPP'
      static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
      static int scenario(mrb_state* M) {
        const char* rows[] = {
          "SealedInt16.new.sum3",
          "SealedInt16.new.spill",
          "SealedInt16.new.oob",
          "SealedInt16.new.sized",
          "SealedInt16.new.neg",
        };
        for (const char* src : rows) {
          mrb_value v = eval(M, src);
          if (M->exc) { show_exc(M, src); continue; }
          show(M, src, v);
        }
        return 0;
      }
    CPP
    build = runtime.full_or_build
    if build
      built, output = runtime.run(dir, err, OWNERS, harness, build: build, full: true)
      sections = runtime.sections(output)
      check.call('built and ran', built)
      check.call('runtime parity, interpreted against compiled', !sections['compiled'].to_a.empty? &&
                                                                  sections['compiled'] == sections['interpreted'])
      EXPECTED.each do |src, value|
        check.call("#{src} => #{value}", sections['compiled'].to_a.include?("#{src} => #{value}"))
      end
      warn output unless failures.empty?
    else
      puts '  SKIP run: no full-core mruby build'
    end
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp sealed int16 local check: PASS'

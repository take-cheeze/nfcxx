#!/usr/bin/env ruby
# frozen_string_literal: true

# EXACT_NATIVE_SLOT (tools/bc2cpp/codegen_exact_native_slot.rb, symbol_cache.rb NATIVE_SLOT): an explicit-receiver
# send whose receiver the class flow proves one class, and whose lookup there reaches no Ruby definition, calls the
# method through its method id's slot instead of the owner call.
#
#   1. generated: `s.strip` / `n.abs` / `s.getbyte(i)` on declared receivers are slot calls with no owner call; a Ruby
#      method on the exact class (Box#strip) and an unproven receiver keep their dispatch; BC2CPP_EXACT_NATIVE_SLOT=0
#      keeps the owner calls;
#   2. run on a full-core mruby against interpreted: the answers, an argument-count error, a private native (Kernel#format
#      on a String raises NoMethodError) and a method redefined at run time after the slot was filled (the slot looks it
#      up again) give what the interpreter gives.
#
# Usage: MRBC=path/to/host/mrbc [BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/exact_native_slot_check.rb

require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('exact_native_slot_check')
check = suite.method(:check)
suite.require_mrbc!
runtime = Bc2cppFixtureRuntime

SOURCE = <<~RUBY
  class Box
    def strip; :box; end
  end

  class SlotFx
    def st(s); s.strip; end
    def ab(n); n.abs; end
    def gb(s, i); s.getbyte(i); end
    def bad(s); s.strip(1); end
    def priv(s); s.format; end
    def boxed(b); b.strip; end
    def loose(x); x.abs; end

    def run
      out = [st('  a '), ab(-3), gb('xyz', 1), boxed(Box.new), loose(-2.5)]
      begin
        bad(' b ')
      rescue ArgumentError => e
        out << e.class
      end
      begin
        priv('c')
      rescue NoMethodError => e
        out << e.class
      end
      out
    end

    def again; st(' d '); end
  end
RUBY

SIGNATURES = <<~RBS
  class SlotFx
    def st: (String s) -> untyped
    def ab: (Integer n) -> Integer
    def gb: (String s, Integer i) -> Integer?
    def bad: (String s) -> String
    def priv: (String s) -> untyped
    def boxed: (Box b) -> Symbol
  end
RBS
OWNERS = %w[Box SlotFx].freeze

HARNESS = <<~'CPP'
  static int scenario(mrb_state* M) {
    mrb_value fx = mrb_obj_new(M, mrb_class_get(M, "SlotFx"), 0, nullptr);
    call(M, "run", fx, "run");
    // The slot of `strip` was filled by #run; a definition the closed world never saw must still be found.
    mrb_load_string(M, "class String; def strip; :redefined; end; end");
    call(M, "again", fx, "again");
    return 0;
  }
CPP

generate = lambda do |dir, env = {}|
  env.each { |k, v| ENV[k] = v }
  sigs = File.join(dir, 'sig')
  FileUtils.mkdir_p(sigs)
  File.write(File.join(sigs, 'slot_fx.rbs'), SIGNATURES)
  ENV['BC2CPP_SIG_DIRS'] = sigs
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS, core: true)
  [code, err, code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }]
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  env.each_key { |k| ENV.delete(k) }
end
slot = ->(body, name) { body.to_s.include?("EXACT_NATIVE_SLOT: ") && body.to_s.match?(/bc2cpp_native_slot\(M, \w+, \d+, bc2cpp_xslot_\d+/) && !body.to_s.include?("owner-call: #{name} */") }
owner_call = ->(body, name) { body.to_s.include?("owner-call: #{name} */") }

Dir.mktmpdir('exact-native-slot') do |dir|
  _code, err, by = generate.call(dir)
  check.call('`s.strip` on a declared String is a slot call', slot.call(by['SlotFx#st'], 'strip'))
  check.call('`n.abs` on a declared Integer is a slot call', slot.call(by['SlotFx#ab'], 'abs'))
  check.call('`s.getbyte(i)` is a slot call or a direct native', slot.call(by['SlotFx#gb'], 'getbyte') ||
               by['SlotFx#gb'].to_s.include?('NATIVE_CORE'))
  check.call('a Ruby method on the exact class is no slot', !by['SlotFx#boxed'].to_s.include?('EXACT_NATIVE_SLOT'))
  check.call('an unproven receiver is no slot', !by['SlotFx#loose'].to_s.include?('EXACT_NATIVE_SLOT'))

  Dir.mktmpdir('exact-native-slot-off') do |off_dir|
    _, _, off = generate.call(off_dir, 'BC2CPP_EXACT_NATIVE_SLOT' => '0')
    check.call('BC2CPP_EXACT_NATIVE_SLOT=0 keeps the owner call', owner_call.call(off['SlotFx#st'], 'strip') &&
               !off['SlotFx#st'].to_s.include?('EXACT_NATIVE_SLOT'))
  end

  build = runtime.full_or_build
  if build
    built, output = runtime.run(dir, err, OWNERS, HARNESS, build: build, full: true)
    sections = runtime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    compiled = plain.call(sections['compiled'])
    check.call('built and ran', built)
    check.call('compiled answers as interpreted (values, errors, a run-time redefinition)',
               built && !compiled.empty? && compiled == plain.call(sections['interpreted']))
    check.call('the redefinition is seen', compiled.any? { |l| l.include?('redefined') })
  else
    puts '  SKIP: no full-core libmruby (set BC2CPP_FULL_BUILD_DIR); the behavioural check needs it'
  end
end

suite.finish!

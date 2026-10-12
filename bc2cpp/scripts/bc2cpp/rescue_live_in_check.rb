#!/usr/bin/env ruby
# encoding: UTF-8
# Check that an extracted `rescue` try body (emit_rescue_try_body) starts from
# the registers' real values at the protected region's begin_addr, not from the
# method's raw C++ parameters. A region reached only after other code ran -- an
# optional argument's default, or an `if ...; return; end` guard -- must capture
# the register file by value (rescue_entry_saved_fields). Caught live:
# `RPG2k::Scene::Map#drive_battle(it = @interpreter)` called with no argument
# ran its whole `begin` body with `it == nil` ("undefined method
# 'battle_request' for NilClass"), because the try body read the raw nil
# parameter instead of the defaulted r1.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SRC = <<~'RUBY'
  class Driver
    def initialize
      @it = 1
    end

    def defaulted(it = @it)
      begin
        it.succ
      rescue StandardError
        nil
      end
    end

    def guarded(x)
      y = x.to_s
      return nil if y.empty?

      begin
        y.size
      rescue StandardError
        nil
      end
    end

    def plain(x)
      begin
        x.succ
      rescue StandardError
        nil
      end
    end

    def exception_message
      begin
        raise 'caught'
      rescue RuntimeError => e
        copied = e
        copied.message
      end
    end
  end
RUBY

Dir.mktmpdir do |dir|
  path = File.join(dir, 'rescue_live_in.rb')
  File.write(path, SRC)
  ireps, root_label = compile_ireps(path, 'bc2cpp_rescue_live_in', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code = lambda do |name|
    gen.compile_method(registry.fetch(name).find { |d| d.owner == 'Driver' }.irep).fetch(:code)
  end

  defaulted = code.call('defaulted')
  check.call('an optional-argument method compiles its rescue region at all', defaulted.include?('_rescue_try_Ctx'))
  check.call('the try body takes r1 from the defaulted register, not the raw parameter',
             defaulted.include?('mrb_value r1 = bc2cpp_saved_r1;') && !defaulted.include?('mrb_value r1 = ctx->'))
  check.call('the glue passes the live register r1 into the ctx', defaulted.match?(/_Ctx ctx\{self, \w+, r1[,}]/))

  guarded = code.call('guarded')
  guarded = code.call('guarded')
  try_body = guarded[/static mrb_value Driver_guarded_impl_rescue_try\(.*?\n\}/m].to_s
  check.call('a region after an early-return guard starts every register from the capture (the local `y` included)',
             try_body.include?('bc2cpp_saved_r') && !try_body.match?(/mrb_value r\d+ = mrb_nil_value\(\);/))

  plain = code.call('plain')
  check.call('a region right after ENTER keeps the lean self+arguments ctx',
             plain.include?('_rescue_try_Ctx') && !plain.include?('bc2cpp_saved_r'))

  message_def = registry.fetch('exception_message').find { |d| d.owner == 'Driver' }
  message_irep = ireps.fetch(message_def.irep)
  message_idx = message_irep.instructions.index { |insn| insn.op.start_with?('SEND') && insn.args.include?(':message') }
  check.call('the caught exception remains proven through RESCUE input and MOVE aliases',
             !message_idx.nil? && gen.rescued_exception_receiver?(message_irep, message_idx,
                                                                  message_irep.instructions[message_idx].reg))

  registry['message'] = [MethodDef.new(name: 'message', owner: '<native>', irep: nil)]
  message_gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  message_code = message_gen.compile_method(message_def.irep).fetch(:code)
  check.call('a recognized rescued Exception#message uses the direct exc_to_s path',
             message_code.include?('EXCEPTION_MESSAGE_DIRECT'))
end

if failures.empty?
  puts 'bc2cpp rescue live-in check: PASS'
else
  warn "bc2cpp rescue live-in check: #{failures.size} failure(s)"
  exit 1
end

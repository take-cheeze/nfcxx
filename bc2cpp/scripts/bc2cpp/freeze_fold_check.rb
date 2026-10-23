#!/usr/bin/env ruby
# frozen_string_literal: true

# FREEZE_FOLD: `nil?`, `is_a?`, `kind_of?` and `frozen?` whose answer the
# NumericFlow class set proves are emitted as a bool. BC2CPP_FREEZE_FOLD=1 turns it on; unset or 0 emits the send as before.
#
# 1. Host (CRuby, no mrbc): the frozen? mask rule on a hand-built frozen table shape, with the kernel audit stubbed.
#    A table bit or nil folds to true; an unfrozen class bit, an Integer, or a mix with OTHER keeps the send.
# 2. Compiled (MRBC): a closed-world fixture of literal receivers. The gate on folds the proven predicates and keeps the
#    unknown ones; the gate off keeps every send. The native core sources are passed so class narrowing is on.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/freeze_fold_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/type_facts'

suite = FixtureCheck.new('freeze_fold_check')

NF = NumericFlow
ROOT = File.expand_path('../..', __dir__)

puts '== frozen? mask rule (host)'
cg = CodeGen.allocate
cg.instance_variable_set(:@frozen_symbol_bit, nil)
registry = FrozenTables::Registry.new(symbol_bit: nil)
table = registry.intern(:array, [NF::INT, NF::INT], nil)
cg.instance_variable_set(:@frozen_tables, registry)
cg.define_singleton_method(:freeze_fold_frozen_safe?) { true }
suite.check('a frozen literal shape folds to true', cg.send(:freeze_fold_frozen, table.bit) == true)
suite.check('nil folds to true (an immediate)', cg.send(:freeze_fold_frozen, NF::NIL) == true)
suite.check('a table with nil folds to true', cg.send(:freeze_fold_frozen, table.bit | NF::NIL) == true)
suite.check('an unfrozen Array class bit is not folded', cg.send(:freeze_fold_frozen, NF::ARR).nil?)
suite.check('an Integer (maybe a bignum) is not folded', cg.send(:freeze_fold_frozen, NF::INT).nil?)
suite.check('a table mixed with OTHER is not folded', cg.send(:freeze_fold_frozen, table.bit | NF::OTHER).nil?)
cg.define_singleton_method(:freeze_fold_frozen_safe?) { false }
suite.check('a refused Kernel#frozen? audit keeps every send', cg.send(:freeze_fold_frozen, table.bit).nil?)

puts '== freeze self producer (host)'
# TypeFacts.textual_producer names the producer of a value only when every reaching definition agrees.
def fold_insn(addr, op, args) = Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
def fold_irep(list) = Irep.new(label: 'fold', nregs: 10, reps: [], pool: ['s'], catch_handlers: [], nlocals: 2,
                               instructions: list)
# r = c ? "s" : 1; r.freeze -- the textually last arm is the Integer literal, but the String arm reaches the freeze.
join = fold_irep([fold_insn(0, 'JMPNOT', "R1\t3"), fold_insn(1, 'STRING', "R2\tL[0]"), fold_insn(2, 'JMP', '4'),
                  fold_insn(3, 'LOADI_1', "R2\t(1)"), fold_insn(4, 'SEND0', "R2\t:freeze")])
suite.check('a join of a String and an Integer has no literal producer',
            TypeFacts.textual_producer(nil, join, 4, 2) == 'unreadable')
single = fold_irep([fold_insn(0, 'STRING', "R2\tL[0]"), fold_insn(1, 'SEND0', "R2\t:freeze")])
suite.check('a straight-line String keeps its literal producer',
            TypeFacts.textual_producer(nil, single, 1, 2) == 'literal:String')
param = fold_irep([fold_insn(0, 'ENTER', '1:0:0:0:0:0:0:0 (0x0)'), fold_insn(1, 'SEND0', "R1\t:freeze")])
suite.check('a frame argument is a param, not a literal', TypeFacts.textual_producer(nil, param, 1, 1) == 'param')

puts '== gate (host)'
previous = ENV.fetch('BC2CPP_FREEZE_FOLD', nil)
begin
  ENV.delete('BC2CPP_FREEZE_FOLD')
  suite.check('unset: the fold is off', !cg.freeze_fold_enabled?)
  ENV['BC2CPP_FREEZE_FOLD'] = '0'
  suite.check('0: the fold is off', !cg.freeze_fold_enabled?)
  ENV['BC2CPP_FREEZE_FOLD'] = '1'
  suite.check('1: the fold is on', cg.freeze_fold_enabled?)
ensure
  previous ? ENV['BC2CPP_FREEZE_FOLD'] = previous : ENV.delete('BC2CPP_FREEZE_FOLD')
end

suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Probe
    def nil_of_nil
      v = nil
      v.nil?
    end

    def nil_of_string
      s = "a"
      s.nil?
    end

    def string_is_string
      s = "a"
      s.is_a?(String)
    end

    def string_kind_of_integer
      s = "a"
      s.kind_of?(Integer)
    end

    def unknown_nil(x)
      x.nil?
    end

    def unknown_is(x)
      x.is_a?(String)
    end

    def join_nil_string(x)
      v = x ? nil : "a"
      v.nil?
    end
  end
RUBY

# The generated C++ of one Probe method with the gate set to +gate+ ('1' or '0').
method_code = lambda do |gate, name|
  previous_gate = ENV.fetch('BC2CPP_FREEZE_FOLD', nil)
  ENV['BC2CPP_FREEZE_FOLD'] = gate
  native = core_native_srcs("#{ROOT}/3rd/mruby")
  suite.compile(SOURCE + "\n") do |ireps, root|
    registry = build_registry(ireps, root)[0]
    world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: {}, walked: [], native_paths: native, ruby_paths: [])
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                      Set.new, Set.new, {}, {}, {}, Set.new, closed_world: world, outside_const_names: Set.new,
                      nil_operator_names: Set.new, outside_ivar_names: Set.new)
    method = registry.fetch(name).find { |d| d.owner == 'Probe' }
    gen.compile_method(method.irep).fetch(:code)
  end
ensure
  ENV['BC2CPP_FREEZE_FOLD'] = previous_gate
end

folds = ->(code) { code.scan(/FREEZE_FOLD :/).size }
sends = ->(code) { code.scan(/"(?:nil\?|is_a\?|kind_of\?)"|mrb_nil_p\(|mrb_obj_is_kind_of/).size }

on = {}
off = {}
%w[nil_of_nil nil_of_string string_is_string string_kind_of_integer unknown_nil unknown_is join_nil_string].each do |name|
  on[name] = method_code.call('1', name)
  off[name] = method_code.call('0', name)
end

puts '== proven predicates fold (gate on)'
suite.check('nil on a nil literal folds to true', folds.call(on['nil_of_nil']) == 1 &&
                                                  on['nil_of_nil'].include?('mrb_true_value()'))
suite.check('nil on a String literal folds to false', folds.call(on['nil_of_string']) == 1 &&
                                                      on['nil_of_string'].include?('mrb_false_value()'))
suite.check('is_a?(String) on a String literal folds to true', folds.call(on['string_is_string']) == 1 &&
                                                              on['string_is_string'].include?('mrb_true_value()'))
suite.check('kind_of?(Integer) on a String literal folds to false', folds.call(on['string_kind_of_integer']) == 1 &&
                                                                   on['string_kind_of_integer'].include?('mrb_false_value()'))

puts '== unproven predicates keep their send (gate on)'
suite.check('nil? on an unknown parameter is kept', folds.call(on['unknown_nil']).zero? && sends.call(on['unknown_nil']) >= 1)
suite.check('is_a? on an unknown parameter is kept', folds.call(on['unknown_is']).zero? && sends.call(on['unknown_is']) >= 1)
suite.check('nil? on a nil-or-String join is kept', folds.call(on['join_nil_string']).zero? && sends.call(on['join_nil_string']) >= 1)

puts '== gate off'
suite.check('gate off emits no FREEZE_FOLD line anywhere', %w[nil_of_nil nil_of_string string_is_string
                                                             string_kind_of_integer unknown_nil].all? { |n| folds.call(off[n]).zero? })
suite.check('gate off keeps the nil? and is_a? sends of the proven methods', sends.call(off['nil_of_string']) >= 1 &&
                                                                              sends.call(off['string_is_string']) >= 1)
suite.check('gate off and gate on differ only where a fold fired',
            on.keys.all? { |n| folds.call(on[n]).positive? || on[n] == off[n] })

suite.finish!

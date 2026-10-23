#!/usr/bin/env ruby
# frozen_string_literal: true

# An explicit receiver's send takes the contract of every class the receiver can be (docs/bc2cpp-ir-feedback.md,
# "Explicit receivers"). Host-only: hand-built hierarchies, a one-send irep (`def use(o); o.greet; end` with `o`
# declared Base), and the closed-world bound given as a lambda, so the prepared (IrContracts) and direct (ir_types)
# paths both run. Fixtures:
#   * an override in a subclass joins its contract with the owner's (Symbol | Integer), never Symbol alone;
#   * a send whose receivers do not override keeps the owner's contract;
#   * a declared receiver with no closed-world bound (an outside subclass may exist) is untyped.
#
# Usage: ruby scripts/bc2cpp/explicit_receiver_override_contracts_check.rb

require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/rbs_signatures'
require_relative '../../tools/bc2cpp/rbs_ir_contracts'

$failures = []
def check(label, condition)
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{label}"
  $failures << label unless condition
end

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

# `def use(o); o.greet; end`: R1 is the required argument, the SEND on R1 (index 1) sends :greet, RETURN R1 (index 2).
def explicit_call_irep(label)
  instructions = [insn(0, 'ENTER', '1:0:0:0:0:0:0:0 (0x0)'), insn(1, 'SEND', "R1\t:greet\tn=0"), insn(2, 'RETURN', 'R1')]
  Irep.new(label: label, instructions: instructions, catch_handlers: [], nregs: 4, nlocals: 2, reps: [], pool: [])
end

def applied(ir_methods:, returns:, owner:, arg_types:)
  RbsSignatures::Applied.new(
    ir_methods: ir_methods.to_set, ir_named_returns: returns, ir_owners: { 'use' => owner },
    ir_arg_types: { 'use' => arg_types }, ir_optional_types: {}, ir_keyword_types: {}, ir_arg_elements: {},
    ir_const_elements: {}, ir_return_types: {}, ir_ivar_types: {}, ir_ivar_elements: {}
  )
end

HIERARCHY = { 'Child' => 'Base', 'Base' => :none }.freeze

# The fact of the send's result (R1 at the RETURN), on the prepared path and on the direct path.
def results(applied_world, subclasses:, method_missing_classes: Set.new)
  world = { superclass_of: HIERARCHY, included_modules: {}, prepended_modules: {}, unknown_mixins: Set.new }
  prepared = RbsSignatures::IrContracts.new(applied_world, **world, subclasses: subclasses,
                                                           method_missing_classes: method_missing_classes)
  prepared_refusal = {}
  prepared_result = RbsSignatures.ir_types(applied_world, explicit_call_irep('use'), prepared: prepared)
                                 .fact_at(2, '1', refusal: prepared_refusal)
  direct_refusal = {}
  direct_result = RbsSignatures.ir_types(applied_world, explicit_call_irep('use'), **world, subclasses: subclasses,
                                                                                 method_missing_classes: method_missing_classes)
                                .fact_at(2, '1', refusal: direct_refusal)
  [prepared_result, direct_result, direct_refusal]
end

def declared_classes(fact)
  fact&.declared? ? fact.classes : nil
end

bounded = ->(klass) { klass == 'Base' ? %w[Base Child] : nil }
base_greet = { ['Base', 'greet'] => Set[:Symbol] }
child_greet = { ['Child', 'greet'] => Set[:Integer] }
declared_base = { '1' => Set[:Base] }

# (a) Override: Child#greet returns Integer, and a Base-declared receiver may be a Child.
overridden = applied(ir_methods: [['Base', 'greet'], ['Child', 'greet']], returns: base_greet.merge(child_greet),
                     owner: 'Base', arg_types: declared_base)
prepared_fact, direct_fact, = results(overridden, subclasses: bounded)
check('override: prepared path joins the subclass contract (Symbol | Integer)',
      declared_classes(prepared_fact) == Set[:Symbol, :Integer])
check('override: direct path joins the subclass contract (Symbol | Integer)',
      declared_classes(direct_fact) == Set[:Symbol, :Integer])

# (b) No receiver overrides greet: the owner's contract is kept.
plain = applied(ir_methods: [['Base', 'greet']], returns: base_greet, owner: 'Base', arg_types: declared_base)
prepared_fact, direct_fact, = results(plain, subclasses: bounded)
check('no override: prepared path keeps the owner contract (Symbol)', declared_classes(prepared_fact) == Set[:Symbol])
check('no override: direct path keeps the owner contract (Symbol)', declared_classes(direct_fact) == Set[:Symbol])

# (c) Unbounded: no closed-world bound, so a subclass from outside the program may exist; the send is untyped.
open_fact, open_direct, open_refusal = results(overridden, subclasses: ->(_klass) {})
check('unbounded receiver (no closed-world bound) is untyped on both paths',
      declared_classes(open_fact).nil? && declared_classes(open_direct).nil?)
check('unbounded receiver records why the send is untyped', open_refusal[:cause] == 'call_receiver_unbounded:Base#greet')

mm_fact, = results(overridden, subclasses: bounded, method_missing_classes: Set['Child'])
check('method_missing subclass makes the receiver unbounded (untyped)', declared_classes(mm_fact).nil?)

if $failures.empty?
  puts 'explicit receiver override contract checks passed'
  exit 0
end
warn "FAILED: #{$failures.join('; ')}"
exit 1

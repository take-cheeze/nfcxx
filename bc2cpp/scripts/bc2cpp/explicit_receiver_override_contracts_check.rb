#!/usr/bin/env ruby
# frozen_string_literal: true

# An explicit receiver's send takes the contract of every class the receiver can be (docs/bc2cpp-ir-feedback.md,
# "Explicit receivers"). Host-only: hand-built hierarchies, a one-send irep (`def use(o); o.greet; end` with `o`
# declared Base), and the closed-world bound given as a lambda, so the prepared (IrContracts) and direct (ir_types)
# paths both run. Fixtures:
#   * an override in a subclass joins its contract with the owner's (Symbol | Integer), never Symbol alone;
#   * a send whose receivers do not override keeps the owner's contract;
#   * a declared receiver with no closed-world bound (an outside subclass may exist) is untyped;
#   * a declared core class is a receiver too (CORE_ROOT, docs/bc2cpp-ir-feedback.md): Array#size keeps its core
#     Integer with no program subclass, with a program subclass that does not override it, and is untyped when a
#     subclass overrides it or the program defines it on Array itself. Object, with core subclasses, stays untyped.
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

# `def use(o); o.greet; end`: R1 is the required argument, the SEND on R1 (index 1) sends +sym+, RETURN R1 (index 2).
def explicit_call_irep(label, sym = 'greet')
  instructions = [insn(0, 'ENTER', '1:0:0:0:0:0:0:0 (0x0)'), insn(1, 'SEND', "R1\t:#{sym}\tn=0"), insn(2, 'RETURN', 'R1')]
  Irep.new(label: label, instructions: instructions, catch_handlers: [], nregs: 4, nlocals: 2, reps: [], pool: [])
end

def applied(ir_methods:, returns:, owner:, arg_types:)
  RbsSignatures::Applied.new(
    ir_methods: ir_methods.to_set, ir_named_returns: returns, ir_owners: { 'use' => owner },
    ir_arg_types: { 'use' => arg_types }, ir_optional_types: {}, ir_keyword_types: {}, ir_arg_elements: {}, ir_rest_elements: {},
    ir_const_elements: {}, ir_return_types: {}, ir_ivar_types: {}, ir_ivar_elements: {}
  )
end

HIERARCHY = { 'Child' => 'Base', 'Base' => :none }.freeze
CORE_HIERARCHY = { 'Child' => 'Array' }.freeze
NOT_REDEFINED = ->(_owner, _name) { false }

# The fact of the send's result (R1 at the RETURN), on the prepared path and on the direct path.
def results(applied_world, subclasses:, method_missing_classes: Set.new, superclass_of: HIERARCHY, core_redefined: NOT_REDEFINED,
            sym: 'greet')
  world = { superclass_of: superclass_of, included_modules: {}, prepended_modules: {}, unknown_mixins: Set.new }
  prepared = RbsSignatures::IrContracts.new(applied_world, **world, subclasses: subclasses,
                                                           method_missing_classes: method_missing_classes, core_redefined: core_redefined)
  prepared_refusal = {}
  prepared_result = RbsSignatures.ir_types(applied_world, explicit_call_irep('use', sym), prepared: prepared)
                                 .fact_at(2, '1', refusal: prepared_refusal)
  direct_refusal = {}
  direct_result = RbsSignatures.ir_types(applied_world, explicit_call_irep('use', sym), **world, subclasses: subclasses,
                                                                                 method_missing_classes: method_missing_classes,
                                                                                 core_redefined: core_redefined)
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

# CORE_ROOT: a declared core class keeps its core contract when the program does not subclass or redefine it.
core_array = ->(klass) { klass == 'Array' ? %w[Array] : nil }
core_array_child = ->(klass) { { 'Array' => %w[Array Child], 'Child' => %w[Child] }[klass] }
array_size = { ['Array', 'size'] => Set[:Integer] }
declared_array = { '1' => Set[:Array] }

# (a) No program subclass: Array#size keeps the core Integer.
core_plain = applied(ir_methods: [['Array', 'size']], returns: array_size, owner: 'Base', arg_types: declared_array)
prepared_fact, direct_fact, = results(core_plain, subclasses: core_array, superclass_of: CORE_HIERARCHY, sym: 'size')
check('core root without a subclass: prepared path keeps the core contract (Integer)',
      declared_classes(prepared_fact) == Set[:Integer])
check('core root without a subclass: direct path keeps the core contract (Integer)',
      declared_classes(direct_fact) == Set[:Integer])

# (b) A program subclass overrides size (its own Symbol contract): the override rule leaves the send untyped.
core_overridden = applied(ir_methods: [['Array', 'size'], ['Child', 'size']],
                          returns: array_size.merge(['Child', 'size'] => Set[:Symbol]), owner: 'Base', arg_types: declared_array)
prepared_fact, direct_fact, direct_refusal = results(core_overridden, subclasses: core_array_child, superclass_of: CORE_HIERARCHY, sym: 'size')
check('core root with an overriding subclass is untyped (prepared path)', declared_classes(prepared_fact).nil?)
check('core root with an overriding subclass is untyped (direct path)', declared_classes(direct_fact).nil?)
check('core root with an overriding subclass records call_contract_missing', direct_refusal[:cause] == 'call_contract_missing:Array#size')

# (c) A program subclass that does not override size keeps the core Integer.
core_inherited = applied(ir_methods: [['Array', 'size']], returns: array_size, owner: 'Base', arg_types: declared_array)
prepared_fact, direct_fact, = results(core_inherited, subclasses: core_array_child, superclass_of: CORE_HIERARCHY, sym: 'size')
check('core root with a non-overriding subclass keeps the core contract (prepared path)',
      declared_classes(prepared_fact) == Set[:Integer])
check('core root with a non-overriding subclass keeps the core contract (direct path)',
      declared_classes(direct_fact) == Set[:Integer])

# (d) The program defines size on Array itself (a reopen): the core contract is not trusted.
redefined = ->(owner, name) { owner == 'Array' && name == 'size' }
prepared_fact, direct_fact, direct_refusal = results(core_plain, subclasses: core_array, superclass_of: CORE_HIERARCHY,
                                                     core_redefined: redefined, sym: 'size')
check('core root redefined by the program is untyped (prepared path)', declared_classes(prepared_fact).nil?)
check('core root redefined by the program is untyped (direct path)', declared_classes(direct_fact).nil?)
check('core root redefined by the program records call_contract_missing', direct_refusal[:cause] == 'call_contract_missing:Array#size')

# (e) Object has core subclasses (Array, Hash, ...), so an instance of one is a receiver the program does not list.
object_size = applied(ir_methods: [['Object', 'size']], returns: { ['Object', 'size'] => Set[:Integer] }, owner: 'Base',
                      arg_types: { '1' => Set[:Object] })
object_bounded = ->(klass) { klass == 'Object' ? %w[Object] : nil }
_, object_direct, object_refusal = results(object_size, subclasses: object_bounded, superclass_of: CORE_HIERARCHY, sym: 'size')
check('core ancestor with core subclasses (Object) is untyped', declared_classes(object_direct).nil?)
check('core ancestor with core subclasses records call_receiver_unbounded:Object#size',
      object_refusal[:cause] == 'call_receiver_unbounded:Object#size')

# (f) A core root with no closed-world bound (an outside subclass may exist) is untyped.
_, open_core_direct, open_core_refusal = results(core_plain, subclasses: ->(_klass) {}, superclass_of: CORE_HIERARCHY, sym: 'size')
check('core root with no closed-world bound is untyped', declared_classes(open_core_direct).nil?)
check('core root with no closed-world bound records call_receiver_unbounded:Array#size',
      open_core_refusal[:cause] == 'call_receiver_unbounded:Array#size')

if $failures.empty?
  puts 'explicit receiver override contract checks passed'
  exit 0
end
warn "FAILED: #{$failures.join('; ')}"
exit 1

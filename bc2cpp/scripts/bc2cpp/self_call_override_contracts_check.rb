#!/usr/bin/env ruby
# frozen_string_literal: true

# Implicit-self sends take the contract of every class the receiver can be (docs/bc2cpp-ir-feedback.md,
# "Implicit self-calls"). Host-only: hand-built hierarchies, a one-send irep, and the closed-world bound given as
# a lambda, so the prepared (IrContracts) and direct (ir_types) paths both run. Fixtures:
#   * an override in a subclass joins its contract with the owner's (Symbol | Integer), never Symbol alone;
#   * a send whose receivers do not override keeps the owner's contract;
#   * an open receiver set (no closed-world bound), a module owner, a method_missing receiver, an unknown mixin
#     in a receiver's chain, and a core ancestor owner each leave the send untyped.
#
# Usage: ruby scripts/bc2cpp/self_call_override_contracts_check.rb

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

# The method body `def via_self; greet; end`: self (R0) sends :greet with no arguments, the result in R1 is returned.
def self_call_irep(label)
  instructions = [insn(0, 'ENTER', '0:0:0:0:0:0:0:0 (0x0)'), insn(1, 'SSEND', 'R1 :greet n=0'), insn(2, 'RETURN', 'R1')]
  Irep.new(label: label, instructions: instructions, catch_handlers: [], nregs: 4, nlocals: 1, reps: [], pool: [])
end

def applied(ir_methods:, returns:, owner:)
  RbsSignatures::Applied.new(
    ir_methods: ir_methods.to_set, ir_named_returns: returns, ir_owners: { 'use' => owner },
    ir_arg_types: { 'use' => {} }, ir_optional_types: {}, ir_keyword_types: {}, ir_arg_elements: {},
    ir_const_elements: {}, ir_return_types: {}, ir_ivar_types: {}, ir_ivar_elements: {}
  )
end

# The fact of the send's result (R1 at the RETURN), on the prepared path and on the direct path.
def results(applied_world, hierarchy: { 'Child' => 'Base', 'Base' => :none }, included: {}, unknown_mixins: Set.new,
            subclasses:, method_missing_classes: Set.new)
  world = { superclass_of: hierarchy, included_modules: included, prepended_modules: {}, unknown_mixins: unknown_mixins }
  prepared = RbsSignatures::IrContracts.new(applied_world, **world, subclasses: subclasses,
                                                           method_missing_classes: method_missing_classes)
  direct = RbsSignatures.ir_types(applied_world, self_call_irep('use'), **world, subclasses: subclasses,
                                                                         method_missing_classes: method_missing_classes)
  prepared_result = prepared && RbsSignatures.ir_types(applied_world, self_call_irep('use'), prepared: prepared)
  [prepared_result&.fact_at(2, '1', refusal: {}), direct.fact_at(2, '1', refusal: {})]
end

def declared_classes(fact)
  fact&.declared? ? fact.classes : nil
end

bounded = ->(klass) { klass == 'Base' ? %w[Base Child] : nil }
base_greet = { ['Base', 'greet'] => Set[:Symbol] }
child_greet = { ['Child', 'greet'] => Set[:Integer] }

# (a) Child overrides greet with Integer: Base#via_self joins Symbol with Integer.
overridden = applied(ir_methods: [['Base', 'greet'], ['Child', 'greet']],
                     returns: base_greet.merge(child_greet), owner: 'Base')
prepared_fact, direct_fact = results(overridden, subclasses: bounded)
check('override: prepared path joins the subclass contract (Symbol | Integer)',
      declared_classes(prepared_fact) == Set[:Symbol, :Integer])
check('override: direct path joins the subclass contract (Symbol | Integer)',
      declared_classes(direct_fact) == Set[:Symbol, :Integer])
check('override: the owner-only answer (Symbol alone) is not reported',
      declared_classes(prepared_fact) != Set[:Symbol] && declared_classes(direct_fact) != Set[:Symbol])

# (b) No receiver overrides greet: the owner's contract is kept.
plain = applied(ir_methods: [['Base', 'greet']], returns: base_greet, owner: 'Base')
prepared_fact, direct_fact = results(plain, subclasses: bounded)
check('no override: prepared path keeps the owner contract (Symbol)', declared_classes(prepared_fact) == Set[:Symbol])
check('no override: direct path keeps the owner contract (Symbol)', declared_classes(direct_fact) == Set[:Symbol])

# The owner's own subclass set alone: a method in Child answers its own class's contract.
child_owned = applied(ir_methods: [['Child', 'greet']], returns: child_greet, owner: 'Child')
child_fact, = results(child_owned, subclasses: ->(klass) { klass == 'Child' ? ['Child'] : nil })
check('owner with no subclasses answers its own contract (Integer)', declared_classes(child_fact) == Set[:Integer])

# (c) Unbounded receivers: no closed-world bound, a module owner (the closed world lists no module), a method_missing
# receiver, an unknown mixin in a receiver chain, and a core ancestor owner.
open_fact, open_direct = results(overridden, subclasses: ->(_klass) {})
check('open receiver set (no closed-world bound) is untyped on both paths',
      declared_classes(open_fact).nil? && declared_classes(open_direct).nil?)

module_owned = applied(ir_methods: [['M', 'greet']], returns: { ['M', 'greet'] => Set[:Symbol] }, owner: 'M')
mod_fact, = results(module_owned, hierarchy: {}, subclasses: ->(_klass) {})
check('module owner is untyped (includers and extenders are not bounded)', declared_classes(mod_fact).nil?)

mm_fact, = results(overridden, subclasses: bounded, method_missing_classes: Set['Child'])
check('method_missing receiver is untyped', declared_classes(mm_fact).nil?)

mix_fact, = results(overridden, included: { 'Child' => ['Mix'] }, unknown_mixins: Set['Mix'], subclasses: bounded)
check('unknown mixin in a receiver chain is untyped', declared_classes(mix_fact).nil?)

core_owner = applied(ir_methods: [['Object', 'greet']], returns: { ['Object', 'greet'] => Set[:Symbol] }, owner: 'Object')
core_fact, = results(core_owner, hierarchy: { 'Child' => 'Object', 'Object' => :none }, subclasses: ->(_klass) { %w[Object Child] })
check('core ancestor owner (Object) is untyped: core receivers are undeclared', declared_classes(core_fact).nil?)

# The receiver set itself, from the prepared tables.
contracts = RbsSignatures::IrContracts.new(overridden, superclass_of: { 'Child' => 'Base', 'Base' => :none },
                                           included_modules: {}, prepended_modules: {}, unknown_mixins: Set.new,
                                           subclasses: bounded)
check('receivers of Base are the bounded program classes', contracts.receivers('Base') == %w[Base Child])
check('receivers of a module are open', RbsSignatures.self_receivers('M', lookup: ->(k) { [k] }, subclasses: ->(_k) {},
                                                                       method_missing_classes: Set.new).nil?)

# Pipeline part: the same shapes through the real analysis, where the closed world bounds the receivers (needs MRBC).
unless ENV['MRBC']
  puts 'SKIP self-call pipeline fixtures (set MRBC)'
  exit($failures.empty? ? 0 : 1)
end

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/bc2cpp/type_check_run'
root = File.expand_path('../..', __dir__)
Dir.mktmpdir('self-call-override') do |dir|
  source = File.join(dir, 'mruby-rpg2k/mrblib/fixture.rb')
  FileUtils.mkdir_p(File.dirname(source))
  File.write(source, <<~SOURCE)
    class SelfOverrideBase
      def greet; :sym; end
      def via_self; greet; end
    end
    class SelfOverrideChild < SelfOverrideBase
      def greet; 1; end
    end
    class SelfOverridePlain < SelfOverrideBase
    end
    class SelfOverrideLeaf
      def greet; :leaf; end
      def via_leaf; greet; end
    end
  SOURCE
  sig = File.join(dir, 'sig')
  Dir.mkdir(sig)
  File.write(File.join(sig, 'self_override.rbs'), <<~RBS)
    class SelfOverrideBase
      def greet: () -> Symbol
    end
    class SelfOverrideChild
      def greet: () -> Integer
    end
  RBS
  work = File.join(dir, 'work')
  Dir.mkdir(work)
  result = TypeCheckRun.run(root: root, mrbc: File.expand_path(ENV.fetch('MRBC')), workdir: work,
                            sources: [source], sig_dirs: [sig], display_root: dir, sends: false)
  rows = JSON.parse(File.read(result.facts_path))['ir_feedback']
  via = rows.find { |row| row['owner'] == 'SelfOverrideBase' && row['method'] == 'via_self' && row['kind'] == 'return' }
  leaf = rows.find { |row| row['owner'] == 'SelfOverrideLeaf' && row['method'] == 'via_leaf' && row['kind'] == 'return' }
  warn "DEBUG via=#{via.inspect} leaf=#{leaf.inspect}" if ENV['SELF_CALL_DEBUG']
  # The body's own return is inferred from the send, so the row is 'inferred'; the type is what the join yields.
  check('pipeline: an overridden self-call is not reported as the owner contract (Symbol alone)',
        via && via['type'] != 'Symbol')
  check('pipeline: an overridden self-call reports the join (Symbol | Integer)',
        via && via['type'].to_s.split(' | ').sort == %w[Integer Symbol])
  check('pipeline: a self-call with no override keeps its owner contract (Symbol)',
        leaf && leaf['type'] == 'Symbol')
end

if $failures.empty?
  puts 'implicit self-call override contract checks passed'
  exit 0
end
warn "FAILED: #{$failures.join('; ')}"
exit 1

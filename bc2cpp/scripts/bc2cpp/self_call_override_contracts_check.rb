#!/usr/bin/env ruby
# frozen_string_literal: true

# Implicit-self sends take the contract of every class the receiver can be (docs/bc2cpp-ir-feedback.md,
# "Implicit self-calls"). Host-only: hand-built hierarchies, a one-send irep, and the closed-world bound given as
# a lambda, so the prepared (IrContracts) and direct (ir_types) paths both run. Fixtures:
#   * an override in a subclass joins its contract with the owner's (Symbol | Integer), never Symbol alone;
#   * a send whose receivers do not override keeps the owner's contract;
#   * an open receiver set (no closed-world bound), a method_missing receiver, an unknown mixin in a receiver's
#     chain, and a core ancestor owner each leave the send untyped;
#   * a name the program undefines or removes (ClosedWorld#method_removed?) is untyped;
#   * a module owner is bounded by its includers: two bounded includers join, an unknown includer, a prepend, or
#     no closed-world candidates leave the send untyped;
#   * the inferred call result of a removed name (section g) is untyped on the direct and context-results paths;
#   * the return-class oracle (section h) refuses a send of a removed name, so no proven return class comes from it.
# The pipeline part (MRBC) runs the same shapes through the real analysis, with the declared contract isolated
# (BC2CPP_IR_CALL_RESULTS=0), so the refusal is what the type reports.
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
  instructions = [insn(0, :ENTER, '0:0:0:0:0:0:0:0 (0x0)'), insn(1, :SSEND, 'R1 :greet n=0'), insn(2, :RETURN, 'R1')]
  Irep.new(label: label, instructions: instructions, catch_handlers: [], nregs: 4, nlocals: 1, reps: [], pool: [])
end

def applied(ir_methods:, returns:, owner:)
  RbsSignatures::Applied.new(
    ir_methods: ir_methods.to_set, ir_named_returns: returns, ir_owners: { 'use' => owner },
    ir_arg_types: { 'use' => {} }, ir_optional_types: {}, ir_keyword_types: {}, ir_arg_elements: {}, ir_rest_elements: {},
    ir_const_elements: {}, ir_return_types: {}, ir_ivar_types: {}, ir_ivar_elements: {}
  )
end

# The fact of the send's result (R1 at the RETURN), on the prepared path and on the direct path. `removed` is the
# name predicate of ClosedWorld#method_removed?; `includer_candidates` is ClosedWorld#known_includer_candidates.
def results(applied_world, hierarchy: { 'Child' => 'Base', 'Base' => :none }, included: {}, prepended: {}, unknown_mixins: Set.new,
            subclasses:, method_missing_classes: Set.new, removed: nil, includer_candidates: nil)
  world = { superclass_of: hierarchy, included_modules: included, prepended_modules: prepended, unknown_mixins: unknown_mixins }
  prepared = RbsSignatures::IrContracts.new(applied_world, **world, subclasses: subclasses,
                                                           method_missing_classes: method_missing_classes,
                                                           includer_candidates: includer_candidates)
  direct = RbsSignatures.ir_types(applied_world, self_call_irep('use'), **world, subclasses: subclasses,
                                                                         method_missing_classes: method_missing_classes,
                                                                         removed: removed, includer_candidates: includer_candidates)
  prepared_result = prepared && RbsSignatures.ir_types(applied_world, self_call_irep('use'), prepared: prepared, removed: removed)
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

# (c) Unbounded receivers: no closed-world bound, a method_missing receiver, an unknown mixin in a receiver chain, and
# a core ancestor owner.
open_fact, open_direct = results(overridden, subclasses: ->(_klass) {})
check('open receiver set (no closed-world bound) is untyped on both paths',
      declared_classes(open_fact).nil? && declared_classes(open_direct).nil?)

mm_fact, = results(overridden, subclasses: bounded, method_missing_classes: Set['Child'])
check('method_missing receiver is untyped', declared_classes(mm_fact).nil?)

mix_fact, = results(overridden, included: { 'Child' => ['Mix'] }, unknown_mixins: Set['Mix'], subclasses: bounded)
check('unknown mixin in a receiver chain is untyped', declared_classes(mix_fact).nil?)

core_owner = applied(ir_methods: [['Object', 'greet']], returns: { ['Object', 'greet'] => Set[:Symbol] }, owner: 'Object')
core_fact, = results(core_owner, hierarchy: { 'Child' => 'Object', 'Object' => :none }, subclasses: ->(_klass) { %w[Object Child] })
check('core ancestor owner (Object) is untyped: core receivers are undeclared', declared_classes(core_fact).nil?)

# (d) A name the program may undefine or remove (undef_method, remove_method, or a computed name) has no self-call
# contract, in any receiver. The predicate is what ClosedWorld#method_removed? answers.
removed_fact, removed_direct = results(overridden, subclasses: bounded, removed: ->(name) { name == 'greet' })
check('removed name: the self-call is untyped on both paths', declared_classes(removed_fact).nil? && declared_classes(removed_direct).nil?)
other_fact, = results(overridden, subclasses: bounded, removed: ->(name) { name == 'other' })
check('removed other name: greet keeps its join (Symbol | Integer)', declared_classes(other_fact) == Set[:Symbol, :Integer])

# (e) Module owner M, bounded by its includers A and B (both declare greet): the send joins their contracts.
module_hierarchy = { 'A' => :none, 'B' => :none, 'M' => :none }
module_subclasses = ->(klass) { { 'A' => ['A'], 'B' => ['B'] }[klass] }
module_candidates = ->(mod) { mod == 'M' ? %w[A B] : nil }
module_world = applied(ir_methods: [['A', 'greet'], ['B', 'greet']], returns: { ['A', 'greet'] => Set[:Symbol], ['B', 'greet'] => Set[:Integer] },
                       owner: 'M')
joined_fact, joined_direct = results(module_world, hierarchy: module_hierarchy, included: { 'A' => ['M'], 'B' => ['M'] },
                                     subclasses: module_subclasses, includer_candidates: module_candidates)
check('module with two bounded includers joins their contracts (Symbol | Integer), prepared path',
      declared_classes(joined_fact) == Set[:Symbol, :Integer])
check('module with two bounded includers joins their contracts (Symbol | Integer), direct path',
      declared_classes(joined_direct) == Set[:Symbol, :Integer])

# (f) The same module with an includer the program does not bound (no candidate list): untyped.
unbounded_fact, unbounded_direct = results(module_world, hierarchy: module_hierarchy, included: { 'A' => ['M'], 'B' => ['M'] },
                                           subclasses: module_subclasses, includer_candidates: ->(_mod) {})
check('unbounded module (no includer candidates) is untyped on both paths',
      declared_classes(unbounded_fact).nil? && declared_classes(unbounded_direct).nil?)

# A class in the candidates whose chain is unknown (an unrecognized include) could include M: untyped.
unknown_includer_fact, = results(module_world, hierarchy: module_hierarchy.merge('C' => :none), included: { 'A' => ['M'], 'B' => ['M'] },
                                 unknown_mixins: Set['C'], subclasses: ->(k) { { 'A' => ['A'], 'B' => ['B'], 'C' => ['C'] }[k] },
                                 includer_candidates: ->(mod) { mod == 'M' ? %w[A B C] : nil })
check('module with an unknown includer is untyped', declared_classes(unknown_includer_fact).nil?)

# A prepend in a receiver's chain: untyped.
prepend_fact, = results(module_world, hierarchy: module_hierarchy, included: { 'A' => ['M'], 'B' => ['M'] },
                        prepended: { 'B' => ['P'] }, subclasses: module_subclasses, includer_candidates: module_candidates)
check('module with a prepend in a receiver chain is untyped', declared_classes(prepend_fact).nil?)

# A module nothing includes has no receiver: untyped (its methods only run on an extender, a closed-world refusal).
orphan_fact, = results(module_world, hierarchy: module_hierarchy, subclasses: module_subclasses,
                       includer_candidates: ->(mod) { mod == 'M' ? [] : nil })
check('module with no includer is untyped', declared_classes(orphan_fact).nil?)

# The receiver set itself, from the prepared tables.
contracts = RbsSignatures::IrContracts.new(overridden, superclass_of: { 'Child' => 'Base', 'Base' => :none },
                                           included_modules: {}, prepended_modules: {}, unknown_mixins: Set.new,
                                           subclasses: bounded)
check('receivers of Base are the bounded program classes', contracts.receivers('Base') == %w[Base Child])
check('receivers of a module with no bound are open',
      RbsSignatures.self_receivers('M', lookup: ->(k) { [k] }, subclasses: ->(_k) {}, method_missing_classes: Set.new).nil?)
check('receivers of a bounded module are its includers and their descendants',
      RbsSignatures.self_receivers('M', lookup: ->(k) { { 'M' => %w[M], 'A' => %w[A M], 'B' => %w[B M] }.fetch(k, []) },
                                   subclasses: module_subclasses, method_missing_classes: Set.new,
                                   includer_candidates: module_candidates, prepended_modules: {}) == %w[A B])

# (g) The inferred call result (BC2CPP_IR_CALL_RESULTS, the default) of a send of a removed name. The send of `greet`
# takes the body join of its target, stubbed to Integer; the removal scan is the real ClosedWorld. Covers
# CodeGen#bytecode_ir_call_result_classes and IrContextResults#dispatch.
require_relative '../../tools/bc2cpp/codegen_return_classes'
require_relative '../../tools/bc2cpp/closed_world'
require_relative '../../tools/bc2cpp/ir_context_results'

# A CodeGen over a real ClosedWorld. The return-class oracle answers the body join: Integer for every send.
class InferredCallHarness < CodeGen
  Oracle = Struct.new(:mask) do
    def send_mask(_irep, _index, _insn, _state) = mask
  end

  def initialize(closed_world, body_join: NumericFlow::INT)
    @foreign_method_names = Set.new
    @native_results_ready = @rc_scoped_ready = true
    @closed_world = closed_world
    @oracle = Oracle.new(body_join)
  end

  def return_class_states(_irep) = { 1 => [] }
  def return_class_table_oracle(_irep) = @oracle
  # IrContextResults reads these at construction; no frozen tables or extra numeric classes in this world.
  def frozen_tables_model = nil
  def numeric_class_bit_count = 0
end

# A frame whose receiver is unknown falls back to bytecode_ir_call_result_classes, so the context path reaches the
# direct result only through this stub.
class InferredContextHarness < IrContextResults
  def frame(_node, _body, _index, _insn, _state) = [NumericFlow::OTHER, [], {}]
end

def call_irep(name)
  instructions = [insn(0, :ENTER, '0:0:0:0:0:0:0:0 (0x0)'), insn(1, :SEND, "R1 :#{name} n=0"), insn(2, :RETURN, 'R1')]
  Irep.new(label: 'use', instructions: instructions, catch_handlers: [], nregs: 4, nlocals: 1, reps: [], pool: [])
end

# A body that undefines `name` with a literal name (LOADSYM before the send), or with a computed name (a MOVE).
def remover_irep(label, load:, name: 'greet')
  instructions = [insn(0, :ENTER, '0:0:0:0:0:0:0:0 (0x0)'), insn(1, load, load == :LOADSYM ? "R1 :#{name}" : 'R1 R2'),
                  insn(2, :SEND, 'R0 :undef_method n=1'), insn(3, :RETURN, 'R0')]
  Irep.new(label: label, instructions: instructions, catch_handlers: [], nregs: 4, nlocals: 1, reps: [], pool: [])
end

def removal_world(*ireps)
  ClosedWorld.new(ireps: ireps.to_h { |irep| [irep.label, irep] }, registry: {}, class_decls: {}, walked: Set.new,
                  native_paths: [], ruby_paths: [])
end

def direct_result(world, name, join: NumericFlow::INT)
  InferredCallHarness.new(world, body_join: join).bytecode_ir_call_result_classes(call_irep(name), 1)
end

def context_result(world, name)
  gen = InferredCallHarness.new(world)
  InferredContextHarness.new(gen, {}).send(:dispatch, nil, call_irep(name), 1, call_irep(name).instructions[1], {})
end

literal_world = removal_world(call_irep('use'), remover_irep('zap', load: :LOADSYM))
check('inferred: a call of a name removed in a subclass has no body-inferred result (direct path)',
      direct_result(literal_world, 'greet').nil?)
check('inferred: the context-results send of a removed name is unknown, not the body join',
      context_result(literal_world, 'greet') == NumericFlow::OTHER)

plain_world = removal_world(call_irep('use'))
check('inferred: with no removal the body join stays (Integer, direct path)',
      direct_result(plain_world, 'greet') == Set[:Integer])
check('inferred: with no removal the body join stays (Integer, context path)',
      context_result(plain_world, 'greet') == NumericFlow::INT)

# The literal removal above names `greet`: another name keeps its join.
check('inferred: an unrelated removal keeps the join (Integer) for another name',
      direct_result(literal_world, 'other') == Set[:Integer] && context_result(literal_world, 'other') == NumericFlow::INT)

computed_world = removal_world(call_irep('use'), remover_irep('zap', load: :MOVE))
check('inferred: a computed removal refuses every name (greet)', direct_result(computed_world, 'greet').nil?)
check('inferred: a computed removal refuses every name (any other name)', direct_result(computed_world, 'other').nil?)
check('inferred: a computed removal refuses the context-results send too',
      context_result(computed_world, 'greet') == NumericFlow::OTHER)

# (h) The return-class oracle (CodeGen#return_class_send_mask, keyed by name in @rc_return). A method whose return is a
# send of a removed name keeps the body join in its own return class unless the send itself is refused. The table
# holds Integer for `greet`; the send reads it only when no class may undefine `greet`.
class ReturnTableHarness < CodeGen
  def initialize(closed_world, table)
    @foreign_method_names = Set.new
    @native_results_ready = @rc_scoped_ready = true
    @closed_world = closed_world
    @rc_return = table
  end

  def frozen_tables_model = nil
  def numeric_class_bit_count = 0
end

def return_table_mask(world, name)
  gen = ReturnTableHarness.new(world, { 'greet' => NumericFlow::INT })
  gen.send(:return_class_send_mask, call_irep(name), 1, call_irep(name).instructions[1])
end

check('return oracle: with no removal the send of greet keeps its class (Integer)',
      return_table_mask(plain_world, 'greet') == NumericFlow::INT)
check('return oracle: a send of a name removed in a subclass is refused (OTHER)',
      return_table_mask(literal_world, 'greet') == NumericFlow::OTHER)
check('return oracle: a computed removal refuses every name (OTHER for greet)',
      return_table_mask(computed_world, 'greet') == NumericFlow::OTHER)
other_world = removal_world(call_irep('use'), remover_irep('zap', load: :LOADSYM, name: 'other'))
check('return oracle: an unrelated removal keeps the send of greet (Integer)',
      return_table_mask(other_world, 'greet') == NumericFlow::INT)

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

# The ir_feedback row of `owner#method`'s return, from a pipeline run over `source` with the given RBS.
# BC2CPP_IR_CALL_RESULTS=0 turns off the inferred call results, so the row reports the declared self-call contract.
def pipeline_row(root, source_text, rbs_text, owner:, method:)
  Dir.mktmpdir('self-call-override') do |dir|
    source = File.join(dir, 'mruby-rpg2k/mrblib/fixture.rb')
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, source_text)
    sig = File.join(dir, 'sig')
    Dir.mkdir(sig)
    File.write(File.join(sig, 'self_override.rbs'), rbs_text)
    work = File.join(dir, 'work')
    Dir.mkdir(work)
    result = TypeCheckRun.run(root: root, mrbc: File.expand_path(ENV.fetch('MRBC')), workdir: work,
                              sources: [source], sig_dirs: [sig], display_root: dir, sends: false,
                              extra_env: { 'BC2CPP_IR_CALL_RESULTS' => '0' })
    rows = JSON.parse(File.read(result.facts_path))['ir_feedback']
    rows.find { |row| row['owner'] == owner && row['method'] == method && row['kind'] == 'return' }
  end
end

BASE_RBS = <<~RBS
  class SelfOverrideBase
    def greet: () -> Symbol
  end
  class SelfOverrideChild
    def greet: () -> Integer
  end
RBS
BASE_SOURCE = <<~SOURCE
  class SelfOverrideBase
    def greet; :sym; end
    def via_self; greet; end
  end
  class SelfOverrideChild < SelfOverrideBase
    def greet; 1; end
  end
SOURCE

plain_source = BASE_SOURCE + <<~SOURCE
  class SelfOverridePlain < SelfOverrideBase
  end
  class SelfOverrideLeaf
    def greet; :leaf; end
    def via_leaf; greet; end
  end
SOURCE
leaf_rbs = BASE_RBS + <<~RBS
  class SelfOverrideLeaf
    def greet: () -> Symbol
  end
RBS

via = pipeline_row(root, plain_source, leaf_rbs, owner: 'SelfOverrideBase', method: 'via_self')
leaf = pipeline_row(root, plain_source, leaf_rbs, owner: 'SelfOverrideLeaf', method: 'via_leaf')
# The body's own return is inferred from the send, so the row is 'inferred'; the type is what the join yields.
check('pipeline: an overridden self-call reports the join (Symbol | Integer), declared path',
      via && via['type'].to_s.split(' | ').sort == %w[Integer Symbol])
check('pipeline: a self-call with no override keeps its owner contract (Symbol)',
      leaf && leaf['type'] == 'Symbol')

# Removal shapes: each refuses greet on the declared path, and an unrelated removal does not.
removal_cases = {
  'undef_method in a subclass' => "class SelfOverridePlain < SelfOverrideBase\n  undef_method :greet\nend\n",
  'remove_method in the owner' => "class SelfOverrideBase\n  remove_method :greet\nend\n",
  'undef keyword in a subclass' => "class SelfOverridePlain < SelfOverrideBase\n  undef greet\nend\n",
  'string literal name' => "class SelfOverridePlain < SelfOverrideBase\n  undef_method 'greet'\nend\n",
  'computed name' => "class SelfOverridePlain < SelfOverrideBase\n  def self.zap(n); undef_method n; end\nend\n",
  'send of remove_method' => "class SelfOverridePlain < SelfOverrideBase\n  send(:remove_method, :greet)\nend\n",
  'computed send target' => "class SelfOverridePlain < SelfOverrideBase\n  def self.zap(m); send(m, :greet); end\nend\n"
}
removal_cases.each do |label, tail|
  row = pipeline_row(root, BASE_SOURCE + tail, BASE_RBS, owner: 'SelfOverrideBase', method: 'via_self')
  check("pipeline: #{label} leaves greet untyped (declared path)", row && row['status'] == 'unknown' && row['type'].nil?)
end
other = pipeline_row(root, BASE_SOURCE + "class SelfOverridePlain < SelfOverrideBase\n  undef_method :other\nend\n",
                     BASE_RBS, owner: 'SelfOverrideBase', method: 'via_self')
check('pipeline: undef of an unrelated name keeps the join (Symbol | Integer)',
      other && other['type'].to_s.split(' | ').sort == %w[Integer Symbol])

# Module shapes: two bounded includers join; an unknown includer or an extender leaves the send untyped.
MODULE_SOURCE = <<~SOURCE
  module SelfMod
    def via_mod; greet; end
  end
  class SelfModA
    include SelfMod
    def greet; :sym; end
  end
  class SelfModB
    include SelfMod
    def greet; 1; end
  end
SOURCE
MODULE_RBS = <<~RBS
  class SelfModA
    def greet: () -> Symbol
  end
  class SelfModB
    def greet: () -> Integer
  end
RBS
module_joined = pipeline_row(root, MODULE_SOURCE, MODULE_RBS, owner: 'SelfMod', method: 'via_mod')
check('pipeline: a closed module with two includers joins their contracts (Symbol | Integer)',
      module_joined && module_joined['type'].to_s.split(' | ').sort == %w[Integer Symbol])

module_unknown = pipeline_row(root, MODULE_SOURCE + "class SelfModC\n  include(*[SelfMod])\n  def greet; 2.5; end\nend\n",
                              MODULE_RBS, owner: 'SelfMod', method: 'via_mod')
check('pipeline: a module with an unknown includer is untyped', module_unknown && module_unknown['type'].nil?)

module_extended = pipeline_row(root, MODULE_SOURCE + "Object.new.extend(SelfMod)\n", MODULE_RBS, owner: 'SelfMod', method: 'via_mod')
check('pipeline: a module that is extended at runtime is untyped', module_extended && module_extended['type'].nil?)

# A singleton class's include makes a class object a receiver, which no declared class lists: untyped.
module_singleton = pipeline_row(root, MODULE_SOURCE + "class SelfModA\n  class << self\n    include SelfMod\n  end\nend\n",
                                MODULE_RBS, owner: 'SelfMod', method: 'via_mod')
check('pipeline: a module included in a singleton class is untyped', module_singleton && module_singleton['type'].nil?)

if $failures.empty?
  puts 'implicit self-call override contract checks passed'
  exit 0
end
warn "FAILED: #{$failures.join('; ')}"
exit 1

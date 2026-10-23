#!/usr/bin/env ruby
# frozen_string_literal: true

# Return contracts through mixins and unknown receivers (docs/bc2cpp-ir-feedback.md, Boundaries).
#
# Host-only part: RbsSignatures.contract_owners and IrContracts#target on hand-built hierarchies, and
# RbsSignatures.ir_types on a one-call irep, so the call resolver runs as the real analysis runs it. One accepted and
# one refused lookup per rule:
#   * a method inherited through one include path resolves to the module's own declared contract;
#   * a module reached twice (two include paths) supplies no contract, because Ruby's position for it depends on
#     load order (CRuby: `Base` includes M and `Child < Base` includes M again gives [Child, Base, M]);
#   * an unknown receiver with a single declared contract in the program is not assumed to be that class.
# The pipeline part, when MRBC is set, runs the same shapes through the real analysis.
#
# Usage: ruby scripts/bc2cpp/rbs_mixin_contracts_check.rb        (MRBC=path for the pipeline part)

require 'json'
require 'set'
require 'tmpdir'
require 'fileutils'
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

# ENTER takes one required argument, R1, the receiver; the call at index 1 sends :m to it and index 2 returns it.
def call_irep(label)
  instructions = [insn(0, 'ENTER', '1:0:0:0:0:0:0:0 (0x0)'), insn(1, 'SEND', 'R1 :m n=0'), insn(2, 'RETURN', 'R1')]
  Irep.new(label: label, instructions: instructions, catch_handlers: [], nregs: 4, nlocals: 1, reps: [], pool: [])
end

def applied(ir_methods:, returns:, owner:, arg_types: {})
  RbsSignatures::Applied.new(
    ir_methods: ir_methods.to_set, ir_named_returns: returns, ir_owners: { 'use' => owner },
    ir_arg_types: { 'use' => arg_types }, ir_optional_types: {}, ir_keyword_types: {}, ir_arg_elements: {},
    ir_const_elements: {}, ir_return_types: {}, ir_ivar_types: {}, ir_ivar_elements: {}
  )
end

# The fact of the call result (R1 at the RETURN) and the refusal the query recorded.
def result_fact(world, applied_world)
  analysis = RbsSignatures.ir_types(applied_world, call_irep('use'), **world)
  refusal = {}
  [analysis.fact_at(2, '1', refusal: refusal), refusal]
end

# Accepted: Child < Base, Child includes M once; M declares m, Base does not.
hierarchy = { 'Child' => 'Base', 'Base' => :none }
owners = RbsSignatures.contract_owners('Child', hierarchy, included_modules: { 'Child' => ['M'] })
check('single include path keeps Ruby order (Child, M, Base, Object)', owners == %w[Child M Base Object])
# The closed world bounds declared receivers (a declared Child may be any program subclass of Child); Child is a leaf.
closed = ->(klass) { { 'Child' => %w[Child], 'Base' => %w[Base Child] }[klass] }
world = { superclass_of: hierarchy, included_modules: { 'Child' => ['M'] }, prepended_modules: {}, unknown_mixins: Set.new,
          subclasses: closed }
contracts = RbsSignatures::IrContracts.new(applied(ir_methods: [['M', 'm']], returns: { ['M', 'm'] => Set[:Symbol] }, owner: 'Use'),
                                           **world)
check('module-declared contract is found through the include', contracts.target('Child', 'm') == 'M')

# Accepted: prepend and nested include keep the mixin chain (Wrap, Child, Greets, Inner, Base).
nested = RbsSignatures.contract_owners('Child', hierarchy, included_modules: { 'Child' => ['Greets'], 'Greets' => ['Inner'] },
                                                          prepended_modules: { 'Child' => ['Wrap'] })
check('prepend and nested include follow mixin order', nested == %w[Wrap Child Greets Inner Base Object])

# Refused: M reached through Child and through Base. CRuby keeps Base, M for Child; the static links do not.
shared = { 'Child' => 'Base', 'Base' => :none }
dup_owners = RbsSignatures.contract_owners('Child', shared, included_modules: { 'Child' => ['M'], 'Base' => ['M'] })
check('module reached through two include paths supplies no contract', dup_owners.empty?)
dup_world = { superclass_of: shared, included_modules: { 'Child' => ['M'], 'Base' => ['M'] }, prepended_modules: {}, unknown_mixins: Set.new,
              subclasses: closed }
dup_applied = applied(ir_methods: [['M', 'm'], ['Base', 'm']], returns: { ['M', 'm'] => Set[:Symbol], ['Base', 'm'] => Set[:Integer] },
                      owner: 'Use', arg_types: { '1' => Set[:Child] })
dup_fact, dup_refusal = result_fact(dup_world, dup_applied)
check('duplicate include refuses the call instead of returning M#m (Symbol)', dup_fact.nil? && dup_refusal[:cause] == 'call_receiver_unbounded:Child#m')
check('duplicate include yields no contract at all', !dup_fact&.declared?)

# Refused: a cycle through modules, and an unknown mixin, supply no contract.
cyclic = RbsSignatures.contract_owners('Child', hierarchy, included_modules: { 'Child' => ['A'], 'A' => ['A'] })
check('cyclic mixin chain supplies no contract', cyclic.empty?)
unknown = RbsSignatures.contract_owners('Child', hierarchy, included_modules: { 'Child' => ['A', 'B'] }, unknown_mixins: Set['B'])
check('unknown mixin in the chain supplies no contract', unknown.empty?)

# Accepted: the receiver is a declared Child, and the module's contract is its only candidate.
accepted_applied = applied(ir_methods: [['M', 'm']], returns: { ['M', 'm'] => Set[:Symbol] }, owner: 'Use', arg_types: { '1' => Set[:Child] })
accepted_fact, = result_fact(world, accepted_applied)
check('proven receiver resolves the module contract', accepted_fact&.classes == Set[:Symbol] && accepted_fact.declared?)
check('module call result records its call-result dependency',
      accepted_fact&.contracts&.include?('call-result:M#m') && accepted_fact.contracts.include?('argument:R1'))

# Refused (rule a): the receiver's class set is unknown, though m has one declared contract in the program. The
# resolver is consulted only for a receiver the compiler proves, so this stays unknown.
unknown_applied = applied(ir_methods: [['M', 'm']], returns: { ['M', 'm'] => Set[:Symbol] }, owner: 'Use')
unknown_fact, unknown_refusal = result_fact(world, unknown_applied)
check('unknown receiver is not assumed to be the single contract owner', unknown_fact.nil? && unknown_refusal[:cause].to_s.start_with?('unknown:'))

# Refused: a declared receiver with no closed-world bound may be an outside subclass, so its module contract is untyped.
open_world = world.merge(subclasses: nil)
open_fact, open_refusal = result_fact(open_world, accepted_applied)
check('declared receiver with no closed-world bound is untyped', open_fact.nil? && open_refusal[:cause] == 'call_receiver_unbounded:Child#m')

if $failures.empty?
  puts 'host mixin and receiver contract checks passed'
else
  puts "#{$failures.size} host mixin and receiver contract check(s) failed"
end

# Pipeline part: the real analysis (needs MRBC, as type_check_run_check does).
unless ENV['MRBC']
  puts 'SKIP mixin pipeline fixtures (set MRBC)'
  exit($failures.empty? ? 0 : 1)
end

require_relative '../../tools/bc2cpp/type_check_run'
root = File.expand_path('../..', __dir__)
Dir.mktmpdir('rbs-mixin-contracts') do |dir|
  source = File.join(dir, 'mruby-rpg2k/mrblib/fixture.rb')
  FileUtils.mkdir_p(File.dirname(source))
  File.write(source, <<~SOURCE)
    module MixinLookupM
      def m; $mv; end
    end
    class MixinLookupBase
      include MixinLookupM
      def m; $bv; end
    end
    class MixinLookupChild < MixinLookupBase
      include MixinLookupM
    end
    module MixinLookupGreets
      def greet; $gv; end
    end
    class MixinLookupSolo
      include MixinLookupGreets
    end
    class MixinLookupUse
      def go(child); child.m; end
      def go2(solo); solo.greet; end
    end
  SOURCE
  sig = File.join(dir, 'sig')
  Dir.mkdir(sig)
  File.write(File.join(sig, 'mixins.rbs'), <<~RBS)
    module MixinLookupM
      def m: () -> Symbol
    end
    class MixinLookupBase
      def m: () -> Integer
    end
    module MixinLookupGreets
      def greet: () -> Symbol
    end
    class MixinLookupUse
      def go: (MixinLookupChild child) -> untyped
      def go2: (MixinLookupSolo solo) -> untyped
    end
  RBS
  work = File.join(dir, 'work')
  Dir.mkdir(work)
  result = TypeCheckRun.run(root: root, mrbc: File.expand_path(ENV.fetch('MRBC')), workdir: work,
                            sources: [source], sig_dirs: [sig], display_root: dir, sends: false)
  rows = JSON.parse(File.read(result.facts_path))['ir_feedback']
  go = rows.find { |row| row['owner'] == 'MixinLookupUse' && row['method'] == 'go' && row['kind'] == 'return' }
  go2 = rows.find { |row| row['owner'] == 'MixinLookupUse' && row['method'] == 'go2' && row['kind'] == 'return' }
  check('pipeline: duplicate include is refused (go)', go && go['status'] == 'unknown' && go['reason'] == 'call_contract_missing:MixinLookupChild#m')
  check('pipeline: single include resolves the module contract (go2)',
        go2 && go2['status'] == 'declared' && go2['type'] == 'Symbol' && go2['contracts'].include?('call-result:MixinLookupGreets#greet'))
end

if $failures.empty?
  puts 'mixin and receiver contract checks passed'
  exit 0
end
warn "FAILED: #{$failures.join('; ')}"
exit 1

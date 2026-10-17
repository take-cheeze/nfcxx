#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_RETURN_GUARD (docs/adr/0455): a `%a{bc2cpp:hint}` return declaration is checked at run time by its
# compiled body and is then a fact. Host only (no mrbc, no build), on a CodeGen with hand-set state:
#
# 1. the wrapped body: a hinted `-> Integer` and `-> C` (and `C?`) check every value the method returns (the exit
#    wrapper and the Fiber hand-off), raise through bc2cpp_declared_return_violation, and keep no by-name fallback;
# 2. the fact: the hinted names enter declared_return_facts (callers trust them with no guard), RBS_CHECKED_PARAMS
#    takes a hinted `-> C` as a proof, and the closed-world preconditions still refuse (alias, core body);
# 3. the refusals: a hinted declaration on a native method, an undefined one or an unchecked kind is a TC1010 error;
#    a run that compiles the owner without the guard fails (guard_failures);
#
# Usage: ruby scripts/bc2cpp/declared_return_guard_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/codegen'
require_relative '../../tools/bc2cpp/codegen_send'
require_relative '../../tools/bc2cpp/codegen_declared_returns'
require_relative '../../tools/bc2cpp/codegen_block_returns'
require_relative '../../tools/bc2cpp/rbs_signatures'
require_relative '../../tools/bc2cpp/rbs_param_check'
require_relative '../../tools/bc2cpp/review_scope'

ROOT = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

Loc = RbsSignatures::Loc
entry = lambda do |owner, name, label, kind, cls, text, nilable: false|
  DeclaredReturns::Entry.new(owner: owner, name: name, label: label, kind: kind, cls: cls, nilable: nilable,
                             text: text, loc: Loc.new('sig/t.rbs', 3, 3), hint: true)
end
count_hint = entry.call('Foo', 'count', 'L1', :fixnum, 'Integer', 'Integer')
pick_hint = entry.call('Foo', 'pick', 'L2', :class, 'Bar', 'Bar')
find_hint = entry.call('Foo', 'find', 'L3', :class, 'Bar', 'Bar?', nilable: true)
list_hint = entry.call('Foo', 'list', 'L4', :array, 'Array', 'Array[Bar]')
hints = [count_hint, pick_hint, find_hint, list_hint]

# CodeGen's own methods over hand-set state (no constructor run).
class GuardHarness < CodeGen
  attr_accessor :installed, :aliased

  # CodeGen's class-level inputs, read through self.class.
  def self.declared_returns = CodeGen.declared_returns
  def self.declared_return_hint_refusals = CodeGen.declared_return_hint_refusals
  def self.declared_return_root = nil

  def initialize(defs, ireps)
    @ireps = ireps
    @registry = defs.group_by(&:name)
    @owner_of = defs.to_h { |d| [d.irep, d] }
    @foreign_method_names = Set.new
    @installed = Set.new
    @aliased = Set.new
  end

  def symbol_installed_names = @installed
  def numeric_aliased_names = @aliased
  def return_table_definitions(name) = @registry.fetch(name, [])
  def numeric_dynamically_named?(_name) = false
end

defs = %w[count pick find list].each_with_index.map do |name, i|
  MethodDef.new(name: name, owner: 'Foo', irep: "L#{i + 1}")
end
ireps = defs.to_h { |d| [d.irep, Irep.new(label: d.irep, instructions: [], reps: [])] }
CodeGen.declared_returns = hints
gen = GuardHarness.new(defs, ireps)

puts '-- the compiled body checks every return (host)'
body = lambda do |impl|
  "// Foo#m (compiled from irep L, 3 insns)\n" \
    "mrb_value #{impl}(mrb_state* M, mrb_value self, mrb_int n) {\n  mrb_value r1 = self;\n  if (n) return r1;\n" \
    "  return mrb_nil_value();\n}\n\n" \
    "static mrb_value Foo_m(mrb_state* M, mrb_value self) {\n" \
    "  if (mrb_unlikely(M->c != M->root_c)) return bc2cpp_core_interpreted(M, self, 4);\n" \
    "  mrb_int n;\n  mrb_get_args(M, \"i\", &n);\n  return #{impl}(M, self, n);\n}\n\n"
end
fixnum_code = gen.declared_return_guard_wrap('L1', body.call('Foo_count_impl'), 'Foo_count_impl')
check.call('the hinted -> Integer body is renamed and called by a checking Foo_count_impl',
           fixnum_code.include?('static inline mrb_value Foo_count_impl_unguarded(mrb_state* M, mrb_value self, mrb_int n) {') &&
             fixnum_code.include?("mrb_value Foo_count_impl(mrb_state* M, mrb_value self, mrb_int n) {\n" \
                                  '  mrb_value bc2cpp_declared_ret = Foo_count_impl_unguarded(M, self, n);'))
check.call('-> Integer is checked Fixnum-exact (mrb_fixnum_p), with the method and type named',
           fixnum_code.include?('if (mrb_unlikely(!(mrb_fixnum_p(bc2cpp_declared_ret)))) ' \
                                'bc2cpp_declared_return_violation(M, bc2cpp_declared_ret, "Foo#count", "Integer");'))
check.call('the Fiber hand-off to the interpreter is checked too (two guards, one marker each)',
           fixnum_code.scan('/* DECLARED_RETURN_GUARD Foo#count -> Integer */').size == 2 &&
             fixnum_code.include?('{ mrb_value bc2cpp_declared_ret = bc2cpp_core_interpreted(M, self, 4);') &&
             !fixnum_code.include?('return bc2cpp_core_interpreted('))
check.call('no by-name fallback in a guard', !fixnum_code.match?(/bc2cpp_send|mrb_funcall|bc2cpp_hint_violation\(/))
class_code = gen.declared_return_guard_wrap('L2', body.call('Foo_pick_impl'), 'Foo_pick_impl')
check.call('-> C is checked as exactly C (the class-equality test of the receiver guards)',
           class_code.match?(/if \(mrb_unlikely\(!\(mrb_obj_class\(M, bc2cpp_declared_ret\) == bc2cpp_owner_class_\d+\(M\)\)\)\) /) &&
             class_code.include?('"Foo#pick", "Bar")'))
nil_code = gen.declared_return_guard_wrap('L3', body.call('Foo_find_impl'), 'Foo_find_impl')
check.call('-> C? also takes nil', nil_code.include?('!(mrb_nil_p(bc2cpp_declared_ret) || mrb_obj_class(M, bc2cpp_declared_ret) == '))
list_code = gen.declared_return_guard_wrap('L4', body.call('Foo_list_impl'), 'Foo_list_impl')
check.call('-> Array[C] checks the Array (the element stays a guarded seed)',
           list_code.include?('!(mrb_array_p(bc2cpp_declared_ret))') && list_code.include?('"Array[Bar]"'))
check.call('a body with no runtime-checked declaration is unchanged',
           gen.declared_return_guard_wrap('L9', body.call('Foo_x_impl'), 'Foo_x_impl') == body.call('Foo_x_impl'))
check.call('an `#error` stub is left alone (guard_failures refuses it)',
           gen.declared_return_guard_wrap('L1', "#error x\n", 'Foo_count_impl') == "#error x\n")

puts '-- the declaration is a fact (host)'
check.call('a hinted -> Integer joins the Fixnum return facts', gen.declared_return_facts(:fixnum).include?('count'))
check.call('a hinted -> Array joins the Array return facts', gen.declared_return_facts(:array).include?('list'))
check.call('hinted -> C and -> C? join the class return facts',
           gen.declared_return_facts(:class) == { 'pick' => 'Bar', 'find' => 'Bar' })
gen.check_declared_returns
check.call('the listing says runtime-checked, fact',
           gen.declared_return_report.include?('  DECLARED_RET Foo#count -> Integer: runtime-checked (%a{bc2cpp:hint}), fact fixnum') &&
             gen.declared_return_diagnostics.empty?)
ctx = { registry: { 'pick' => [defs[1]], 'find' => [defs[2]] }, declared: hints.to_h { |e| [e.label, e] }, sig_of: {} }
check.call('RBS_CHECKED_PARAMS: a call to a hinted -> C proves C', RbsParamCheck.returns_why(ctx, 'pick', 'Bar', 0).nil?)
check.call('RBS_CHECKED_PARAMS: a hinted -> C? proves C or nil only',
           RbsParamCheck.returns_why(ctx, 'find', 'Bar', 0).is_a?(RbsParamCheck::Nilable))
aliased = GuardHarness.new(defs, ireps)
aliased.aliased << 'count'
check.call('an aliased hinted name is refused (error) and carries no fact',
           aliased.declared_return_refusal('count')&.first == 'error' && !aliased.declared_return_facts(:fixnum).include?('count'))
core_defs = defs.map { |d| d.name == 'count' ? d.dup.tap { |c| c.core = true } : d }
core = GuardHarness.new(core_defs, ireps)
check.call('a hinted core method is refused (error): it may run interpreted',
           core.declared_return_refusal('count')&.first == 'error')
poly_defs = defs + [MethodDef.new(name: 'count', owner: 'Baz', irep: 'L5')]
poly = GuardHarness.new(poly_defs, ireps.merge('L5' => Irep.new(label: 'L5', instructions: [], reps: [])))
check.call('a POLY name declared on one definition only adds no fact (every definition must carry the check)',
           poly.declared_return_refusal('count')&.first == 'info' && !poly.declared_return_facts(:fixnum).include?('count'))

puts '-- refusals (host)'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 't.rbs'), <<~RBS)
    class Foo
      %a{bc2cpp:hint}
      def native_size: () -> Integer
      %a{bc2cpp:hint}
      def nowhere: () -> Integer
      %a{bc2cpp:hint}
      def name_text: () -> String
      %a{bc2cpp:hint}
      def count: () -> Integer
    end
  RBS
  loaded = RbsSignatures.load([dir], display_root: dir)
  registry = { 'native_size' => [MethodDef.new(name: 'native_size', owner: 'Foo', irep: nil)],
               'name_text' => [MethodDef.new(name: 'name_text', owner: 'Foo', irep: 'N1')],
               'count' => [MethodDef.new(name: 'count', owner: 'Foo', irep: 'N2')] }
  rireps = { 'N1' => Irep.new(label: 'N1', instructions: [], reps: []),
             'N2' => Irep.new(label: 'N2', instructions: [], reps: []) }
  refusals = DeclaredReturns.hint_refusals(loaded, rireps, registry).to_h { |r| [r[:key], r[:why]] }
  check.call('a hinted declaration on a native method is refused',
             refusals['Foo#native_size']&.include?('a native or accessor method'))
  check.call('a hinted declaration on an undefined method is refused', refusals['Foo#nowhere']&.include?('defines no such'))
  check.call('a hinted declaration of an unchecked kind is refused', refusals['Foo#name_text']&.include?('no checked kind'))
  check.call('a hinted declaration on a compiled body is not refused (it is an entry)',
             !refusals.key?('Foo#count') && DeclaredReturns.from_signatures(loaded, rireps, registry).map(&:key) == ['Foo#count'])
  CodeGen.declared_return_hint_refusals = DeclaredReturns.hint_refusals(loaded, rireps, registry)
  gen2 = GuardHarness.new(defs, ireps)
  diags = gen2.check_declared_returns
  check.call('each refusal is a located TC1010 error',
             diags.count { |d| d[:severity] == 'error' && d[:code] == 'TC1010' && d[:file] == 't.rbs' } == 3)
  CodeGen.declared_return_hint_refusals = nil
end
guarded = { label: 'L1', owner: 'Foo', name: 'count', code: fixnum_code }
check.call('a run that compiles the guarded body passes', DeclaredReturns.guard_failures([count_hint], [guarded], nil, nil).empty?)
check.call('a run that compiles the owner but not the body fails',
           DeclaredReturns.guard_failures([count_hint], [], ['Foo'], nil).first&.include?('does not compile it'))
check.call('a body left interpreted (#error) fails',
           DeclaredReturns.guard_failures([count_hint], [guarded.merge(code: "#error x\n", unsupported: true)], nil, nil)
                          .first&.include?('interpreted and unchecked'))
check.call('a body compiled without its guard fails',
           DeclaredReturns.guard_failures([count_hint], [guarded.merge(code: body.call('Foo_count_impl'))], nil, nil)
                          .first&.include?('carries no guard'))
check.call('an owner another gem compiles is that run\'s to check',
           DeclaredReturns.guard_failures([count_hint], [], ['Other'], ['Foo']).empty?)
check.call('an owner no gem compiles fails',
           DeclaredReturns.guard_failures([count_hint], [], ['Other'], ['Else']).first&.include?('no compiled gem'))

if failures.empty?
  puts 'declared return guard check: ok'
else
  abort "declared return guard check: #{failures.size} failure(s)"
end

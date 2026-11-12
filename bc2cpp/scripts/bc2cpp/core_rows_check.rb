#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_ROWS (tools/bc2cpp/core_rows.rb): a core ROM entry the engine reaches only through proven-receiver calls is kept
# as a row (2 in the exclusion header) instead of a method-table entry.
#
#   - the generated-code scan: a by-name send, a presym or symbol reference passed to a by-name helper is a lookup;
#     a variable, constant, keyword, Symbol value or comparison, table entry or diagnostic is none, and neither is the
#     bare index an owner call or a native singleton call takes;
#   - the engine reading: a send's or Symbol literal's operand looks nothing up, any other operand does, and an
#     unresolved alias keeps every symbol; the dynamic and `super` names count;
#   - the outputs: the header defines a row to 2, the lists read without the key as empty, and the runtime helpers a
#     proven receiver calls through find rows (bc2cpp_find_proven).
#
# Usage: ruby scripts/bc2cpp/core_rows_check.rb

require_relative '../../tools/bc2cpp/world_root'
require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/core_rows'
require_relative '../../tools/bc2cpp/core_native_candidates'
require_relative '../../tools/bc2cpp/static_dispatch_lists'
require_relative '../../tools/bc2cpp/symbol_cache'

suite = FixtureCheck.new('core_rows_check')

gen = <<~CPP
  static const char* const bc2cpp_sym_names[9] = {
    "first",
    "@x",
    "Foo",
    "last",
    "join",
    "each",
    "pack",
    "sort",
    "zip",
  };
  mrb_value f(mrb_state* M, mrb_value self, mrb_value r1) {
    r1 = bc2cpp_owner_call(M, r1, 0, 2, BC2CPP_OWNERS("Array"), mrb_nil_value(), 0, self); /* CLOSED_WORLD owner-call: first */
    r1 = mrb_iv_get(M, self, bc2cpp_sym(M, 1));
    mrb_sym name = bc2cpp_sym(M, 2);
    mrb_value r0 = mrb_const_get(M, recv, name);
    r1 = mrb_symbol_value(bc2cpp_sym(M, 3));
    r1 = mrb_bool_value(mrb_symbol_p(r1) && mrb_symbol(r1) == MRB_SYM(sort));
    r1 = bc2cpp_send(M, r1, 4, 0);
    r1 = bc2cpp_funcall_argv(M, r1, bc2cpp_sym(M, 5), 0, nullptr);
    r1 = mrb_funcall_id(M, r1, MRB_SYM(zip), 0);
    r1 = bc2cpp_nomethod(M, r1, bc2cpp_sym(M, 6));
    r1 = bc2cpp_native_singleton(M, r1, 6, BC2CPP_NSC_SLOT, 0);
  }
CPP
found = CoreRows.generated_lookups(gen)
suite.check('a by-name send helper is a lookup', found.include?('join'))
suite.check('a symbol passed to a by-name call is a lookup', found.include?('each'))
suite.check('a presym passed to a by-name call is a lookup', found.include?('zip'))
suite.check('an owner call and a native singleton call look nothing up by name', !found.include?('first') && !found.include?('pack'))
suite.check('a Symbol value, a comparison, a variable and a constant are no lookup',
            (found & %w[last sort @x Foo]).empty?)
suite.check('the symbol table itself is no lookup', CoreRows.strip_sym_table(gen).count('"') == gen.count('"') - 18)

insn = Struct.new(:op, :sym, :alias_name) do
  def first_of(_kind) = alias_name && Struct.new(:value).new(alias_name)
end
program = Struct.new(:insns) do
  def each_source(&) = insns.each_with_index(&)
end
irep = Struct.new(:label, :syms, :insns)
ireps = {
  'a' => irep.new('a', %i[first each], [insn.new(:SEND, :first), insn.new(:LOADSYM, :each)]),
  'b' => irep.new('b', %i[undef_me], [insn.new(:UNDEF, :undef_me)])
}
BytecodeIR.singleton_class.send(:define_method, :for) { |i| program.new(i.insns) }
names = CoreRows.engine_names(ireps, [], Set['dyn'], Set['sup'])
suite.check('a send and a Symbol literal of the engine look nothing up', !names.include?('first') && !names.include?('each'))
suite.check('another operand of the engine is a lookup', names.include?('undef_me'))
suite.check('the dynamic and super names count', names.superset?(Set['dyn', 'sup']))
ireps['c'] = irep.new('c', %i[hidden], [insn.new(:ALIAS, :x, nil)])
suite.check('an unresolved alias keeps every symbol', CoreRows.engine_names(ireps, [], Set.new, Set.new).include?('hidden'))

entries = [{ mt_class: 'Array', kind: 'SYM', cname: 'first', name: 'first' },
           { mt_class: 'Array', kind: 'SYM', cname: 'pack', name: 'pack' }]
text = CoreNativeCandidates.header(['Array#pack'], entries, rows: ['Array#first'])
suite.check('the header defines a row to 2 and an excluded entry to 1',
            text.include?('MRB_MT_EXCLUDE_Array_SYM__first 2') && text.include?('MRB_MT_EXCLUDE_Array_SYM__pack 1'))
lists = StaticDispatchLists.parse(JSON.generate(StaticDispatchLists::REQUIRED_KEYS.to_h { |k| [k, []] }.merge('digest' => 'x')))
suite.check('lists without core_rows read it as empty', lists.core_rows.empty?)

owner_call = SymbolCache.const_get(:OWNER_CALL)
suite.check('an owner call finds rows', owner_call.include?('bc2cpp_find_proven(M, &c, mid)'))
suite.check('a native singleton call finds rows', SymbolCache.const_get(:NATIVE_SINGLETON).scan('bc2cpp_find_proven(M, &c, mid)').size == 2)

suite.finish!

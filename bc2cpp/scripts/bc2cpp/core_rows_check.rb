#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_ROWS (tools/bc2cpp/core_rows.rb): a core ROM entry the engine reaches only through proven-receiver calls is kept
# as a row (2 in the exclusion header) instead of a method-table entry.
#
#   - the generated-code scan: a by-name send, a presym or symbol reference passed to a by-name helper is a lookup;
#     a variable, constant, keyword, Symbol value or comparison, table entry or diagnostic is none, and neither is the
#     bare index an owner call or a native singleton call takes, nor ARRAY_FIXNUM_HASH's compared `hash`; the
#     literal scan reads no PROC_SPEC name;
#   - the engine reading: a send's or Symbol literal's operand looks nothing up, any other operand does, and an
#     unresolved alias keeps every symbol; the dynamic and `super` names count, and a name only a native under 3rd/
#     gives is none of the engine's (the core run reads that source itself); the closed build's engine bytecode sends
#     count only where a bytecode proc may run (ENGINE_ROWS_COMPILED);
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
require_relative '../../tools/bc2cpp/static_dispatch_registrations'
require 'fileutils'
require 'tmpdir'

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
hash_gen = <<~CPP
  static const char* const bc2cpp_sym_names[1] = {
    "hash",
  };
  { mrb_value h; if (bc2cpp_ary_fixnum_hash(M, self, bc2cpp_sym(M, 0), &h)) return h; }
CPP
suite.check("ARRAY_FIXNUM_HASH's `hash` (a recursion guard's compare) is no lookup",
            !CoreRows.generated_lookups(hash_gen).include?('hash'))
spec_gen = <<~'CPP'
  static const char* const bc2cpp_proc_spec_7_names[] = { "\x6b\x65\x79", "", nullptr };
  mrb_value v = mrb_funcall(M, x, "kept_literal", 0);
  mrb_value w = bc2cpp_pool_str(M, "\x6b\x65\x79\x32");
CPP
lits = StaticDispatchRegistrations.rows_generated_text(spec_gen).scan(StaticDispatchRegistrations::STRING_LITERAL)
                                  .map { |(s)| StaticDispatchRegistrations.unescape(s) }
suite.check("the rows run reads no PROC_SPEC name (a block's local), a code literal still (#{lits.join(', ')})",
            !lits.include?('key') && lits.include?('key2'))

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
suite.check('ENGINE_ROWS_COMPILED: in the VM-free closed build the engine bytecode sends give no row lookup',
            !CoreRows.bytecode_sends_count?(true, false))
suite.check('they still count in the open build, or when the generated code builds a bytecode proc',
            CoreRows.bytecode_sends_count?(false, false) && CoreRows.bytecode_sends_count?(true, true))

Dir.mktmpdir do |dir|
  core_c = File.join(dir, '3rd/mruby/src/x.c')
  engine_c = File.join(dir, 'src/y.c')
  [core_c, engine_c].each { |p| FileUtils.mkdir_p(File.dirname(p)) }
  File.write(core_c, 'mrb_funcall(M, v, "core_only", 0);')
  File.write(engine_c, 'mrb_funcall(M, v, "engine_named", 0);')
  sdr = StaticDispatchRegistrations
  files = sdr.singleton_class.instance_method(:outside_world_files)
  sdr.singleton_class.send(:define_method, :outside_world_files) { |*_a, **_k| [[], [core_c, engine_c]] }
  begin
    engine = Set.new
    all = sdr.outside_world_tokens(dir, engine_tokens: engine)
    suite.check('a native under 3rd/ names its tokens for the engine proof only',
                all.include?('core_only') && !engine.include?('core_only'))
    suite.check('a native outside 3rd/ is read by the rows run alone: its tokens reach the rows run, not the engine proof',
                all.include?('engine_named') && !engine.include?('engine_named'))
  ensure
    sdr.singleton_class.send(:define_method, :outside_world_files, files)
  end
end

# SUFFIX_EXACT_NAMES: a symbol of a reflective core file is the exact name looked up, a base of a setter or predicate
# only where core Ruby has a "=", "?" or "!" to build one with.
sdr = StaticDispatchRegistrations
stubbed = %i[outside_world_files closed_unlinked_dirs core_compiled_mrblib_srcs core_bytecode_tokens]
saved = stubbed.to_h { |name| [name, sdr.singleton_class.instance_method(name)] }
text_of = lambda do |literals|
  sdr.singleton_class.send(:define_method, :outside_world_files) { |*_a, **_k| [['/w/3rd/mruby/mrblib/refl.rb'], []] }
  sdr.singleton_class.send(:define_method, :closed_unlinked_dirs) { |*_a| [] }
  sdr.singleton_class.send(:define_method, :core_compiled_mrblib_srcs) { |*_a| [] }
  sdr.singleton_class.send(:define_method, :core_bytecode_tokens) do |_paths, _tokens, suffix_literals: nil, **_k|
    suffix_literals&.merge(literals)
    { '/w/3rd/mruby/mrblib/refl.rb' => Set['size', 'done?'] }
  end
  text = Set.new
  sdr.outside_world_tokens('/w', closed_only: true, core: { mrbc: 'mrbc', superclass_of: {} }, text: text)
  text
ensure
  saved.each { |name, method| sdr.singleton_class.send(:define_method, name, method) }
end
tokens = text_of.call([])
suite.check('a reflective core file with no suffix literal gives no text base', !tokens.include?('size') && !tokens.include?('done'))
tokens = text_of.call(['='])
suite.check('with a "=" in core Ruby its symbols and their stems are text bases', tokens.include?('size') && tokens.include?('done'))

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

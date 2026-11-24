#!/usr/bin/env ruby
# frozen_string_literal: true

# SETCONST emitter (tools/bc2cpp/codegen_insn.rb): the constant write of a class body becomes an mrb_const_set on the
# body's class, named by the cached owner class pointer. Only a class body holds a SETCONST (a def cannot write one), so
# the check compiles a class, finds its SETCONST, and emits it for that class as owner. CONST_DEF_ELIDE
# (tools/bc2cpp/const_def_elide.rb): a write nothing can observe by name is dropped, and each refusal keeps it.
# CONST_DEF_TABLE (tools/bc2cpp/const_def_table.rb): a run of Fixnum writes becomes one table. Needs MRBC; without it: SKIP.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/setconst_emit_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('setconst_emit_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Router
    LIMIT = 3
    def route(x)
      x + LIMIT
    end
  end
RUBY

suite.compile(SOURCE) do |ireps, _root|
  setconst = ireps.values.flat_map do |irep|
    BytecodeIR.for(irep).each_source.select { |insn, _| insn.op == :SETCONST }.map { |insn, idx| [irep, insn, idx] }
  end
  suite.check('the class body has one SETCONST (LIMIT)', setconst.size == 1 && setconst.first[1].const_name == 'LIMIT')

  irep, insn, idx = setconst.first
  gen = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  owner_def = Struct.new(:owner, :core).new('Router', false)
  code = gen.compile_insn(insn, irep, owner_def, idx)
  suite.check('SETCONST emits mrb_const_set on the cached owner class, named LIMIT',
              code.include?('mrb_const_set(M, mrb_obj_value(bc2cpp_owner_class_0(M)), mrb_intern_cstr(M, "LIMIT"), r') &&
              code.match?(/, r\d+\);/))
  suite.check('the owner class helper is named for Router', gen.send(:owner_class_fn_name, 'Router') == 'bc2cpp_owner_class_0')

  unknown = gen.compile_insn(insn, irep, Struct.new(:owner, :core).new(nil, false), idx)
  suite.check('without an owner the emitter refuses with #error', unknown.include?('#error SETCONST'))
end

# CONST_DEF_ELIDE: the analysis on a fixture world. `native` is [name, C text] of linked native sources.
elide = lambda do |source, vm_free: true, native: nil, &blk|
  saved = ENV['BC2CPP_VM_FREE']
  ENV['BC2CPP_VM_FREE'] = vm_free ? '1' : '0'
  suite.compile(source) do |ireps, root, dir|
    registry, superclass_of, _containers, included, prepended, unknown, = build_registry(ireps, root)
    paths = native ? [File.join(dir, native[0]).tap { |path| File.write(path, native[1]) }] : []
    world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: {}, walked: [], native_paths: paths,
                            ruby_paths: [])
    facts = BytecodeIR::ConstantFacts.analyze(ireps, sites: [], poisoned: Set.new, operators_safe: true)
    folded = facts.values.select { |name, _| facts.fixnum_names.include?(name) }
    result = ConstDefElide.analyze(ireps: ireps, folded: folded, facts: facts.groups,
                                   site_keys: LexicalConsts.analyze(ireps, static: true).site_keys, closed_world: world,
                                   linked_native: paths, spelled_native: paths,
                                   mixins: { superclass_of: superclass_of, included: included, prepended: prepended,
                                             unknown: unknown, modules: Set.new })
    blk.call(result, ireps)
  end
ensure
  ENV['BC2CPP_VM_FREE'] = saved
end

PLAIN = <<~'RUBY'
  class Router
    LIMIT = 3
    MODE = :fast
    UNREAD = nil
    def route(x) = x + LIMIT
    def mode = MODE
  end
RUBY

elide.call(PLAIN) do |result, ireps|
  suite.check('CONST_DEF_ELIDE: a folded Fixnum constant is elided', result.elide?('LIMIT'))
  suite.check('CONST_DEF_ELIDE: an immediate nothing reads is elided', result.elide?('UNREAD'))
  suite.check('CONST_DEF_ELIDE: a Symbol constant read by name is kept', !result.elide?('MODE') &&
              result.kept['MODE'] == 'read and not folded')
  irep, insn, idx = ireps.values.flat_map do |i|
    BytecodeIR.for(i).each_source.select { |s, _| s.op == :SETCONST && s.const_name == 'LIMIT' }.map { |s, x| [i, s, x] }
  end.first
  CodeGen.const_def_elide = result
  code = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
                .compile_insn(insn, irep, Struct.new(:owner, :core).new('Router', false), idx)
  CodeGen.const_def_elide = nil
  suite.check('CONST_DEF_ELIDE: the elided write emits no mrb_const_set', !code.include?('mrb_const_set') &&
              code.include?('CONST_DEF_ELIDE LIMIT'))
  aborted = begin
    ConstDefElide.assert_unnamed!(result, ['  if (bc2cpp_str_eq(r1, "LIMIT")) r1 = bc2cpp_const_scope_1(M, MRB_SYM(LIMIT));'], [])
    false
  rescue SystemExit
    true
  end
  suite.check('CONST_DEF_ELIDE: generated code that still names an elided constant aborts the run', aborted)
  suite.check('CONST_DEF_ELIDE: a String literal spelling the name is no lookup',
              ConstDefElide.assert_unnamed!(result, ['  r1 = bc2cpp_str_eq(r1, "LIMIT");'], ['"UNREAD_NOT"']).nil?)
end
elide.call(PLAIN, vm_free: false) do |result, _|
  suite.check('CONST_DEF_ELIDE: a world that can run bytecode elides nothing',
              result.names.empty? && result.refusal.to_s.include?('MRB_VM_FREE'))
end
elide.call(PLAIN + "p Router.const_get(:LIMIT)\n") do |result, _|
  suite.check('CONST_DEF_ELIDE: a const_get of a Symbol literal keeps that name only', !result.elide?('LIMIT') &&
              result.elide?('UNREAD'))
end
elide.call(PLAIN + "p Router.const_get(\"LIM\" + \"IT\")\n") do |result, _|
  suite.check('CONST_DEF_ELIDE: a const_get of a computed name elides nothing', result.names.empty? &&
              result.refusal.to_s.include?(':const_get'))
end
elide.call(PLAIN + "p Router.constants\n") do |result, _|
  suite.check('CONST_DEF_ELIDE: Module#constants anywhere elides nothing', result.names.empty?)
end
elide.call(PLAIN + "p defined?(Router::LIMIT)\n") do |result, _|
  suite.check('CONST_DEF_ELIDE: defined? reads the folded value, so the write is still elided', result.elide?('LIMIT'))
end
elide.call(PLAIN + "Router.freeze\n") do |result, _|
  suite.check('CONST_DEF_ELIDE: a class that can be frozen keeps its writes', !result.elide?('LIMIT') &&
              result.kept['LIMIT'].to_s.include?('frozen'))
end
elide.call(PLAIN, native: ['reader.c', "int f(mrb_state* M, mrb_value c) { return mrb_fixnum(mrb_const_get(M, c, mrb_intern_lit(M, \"LIMIT\"))); }\n"]) do |result, _|
  suite.check('CONST_DEF_ELIDE: a name native code spells is kept', result.kept['LIMIT'] == 'spelled by native code')
end
elide.call(PLAIN, native: ['reader.c', "mrb_value f(mrb_state* M, mrb_value c, mrb_sym s) { return mrb_const_get(M, c, s); }\n"]) do |result, _|
  suite.check('CONST_DEF_ELIDE: an unreviewed computed-name native read elides nothing', result.names.empty? &&
              result.refusal.to_s.start_with?('unreviewed native table read'))
end
elide.call(<<~'RUBY') do |result, _|
  class Router
    LIMIT = 3
    def route(x) = x + LIMIT
  end
  Router::LIMIT = 4
RUBY
  suite.check('CONST_DEF_ELIDE: a `Scope::NAME =` binding keeps the name', !result.elide?('LIMIT'))
end

table = ConstDefTable.rewrite(<<~CPP.gsub(/^/, '  '))
  r1 = mrb_fixnum_value(24);
  mrb_const_set(M, mrb_obj_value(bc2cpp_owner_class_3(M)), MRB_SYM(WIDTH), r1);
  r1 = mrb_fixnum_value(32);
  mrb_const_set(M, mrb_obj_value(bc2cpp_owner_class_3(M)), MRB_SYM(HEIGHT), r1);
  r1 = mrb_fixnum_value(7);
  mrb_const_set(M, mrb_obj_value(bc2cpp_owner_class_4(M)), MRB_SYM(OTHER), r1);
CPP
suite.check('CONST_DEF_TABLE: a run of writes to one owner becomes one table call in order',
            table.include?('rows[] = {{MRB_SYM(WIDTH), 24}, {MRB_SYM(HEIGHT), 32}}') &&
            table.include?('bc2cpp_const_rows(M, bc2cpp_owner_class_3(M), rows, 2); }') &&
            table.include?("  r1 = mrb_fixnum_value(32);\n") && table.include?('MRB_SYM(OTHER), r1);'))

suite.finish!

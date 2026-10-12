#!/usr/bin/env ruby
# encoding: UTF-8
# Check INTEGER_CONSTANT_VALUE_PROOF (IntegerConstants.analyze_values,
# tools/bc2cpp/bc2cpp.rb): a bare name that always binds a Fixnum
# (IntegerConstants.analyze) and always binds the SAME Fixnum can have its
# GETCONST/GETMCNST replaced with that literal value outright, skipping the
# runtime lookup entirely -- this is the actual RPG2k hot spot the proof
# exists for: `case cmd.code when Cmd::SHOW_MESSAGE` compiles to one GETMCNST
# per `when` arm, and Game::Interpreter::Cmd alone has ~130 members scanned in
# sequence on every command dispatch.
#
# Wrongly admitted, this silently substitutes the WRONG number for a real
# program's constant reference -- a much worse failure than falling back to
# the ordinary lookup, so every rejection case here matters as much as the
# admission cases.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SRC = <<~'RUBY'
  module Cmd
    SHOW_MESSAGE = 10110
    END_LOOP     = 12410
    OFFSET       = 20
    ARITHMETIC   = END_LOOP + OFFSET
    ARITHMETIC_CHAIN = ARITHMETIC - 10
    FIXNUM_EDGE  = 1073741823
    ARITHMETIC_OVERFLOW = FIXNUM_EDGE + 1
  end
  ALIASED = Cmd::SHOW_MESSAGE
  DISAGREEING = 1
  DISAGREEING = 2
  module Sub
    DISAGREEING = 3
  end
  NON_INTEGER = "x"
  CYCLE_A = CYCLE_B
  CYCLE_B = CYCLE_A

  class User
    def read_bare
      Cmd
      ALIASED
    end

    def read_scoped cmd
      cmd == Cmd::SHOW_MESSAGE
    end

    def read_disagreeing
      DISAGREEING
    end

    def read_cycle
      CYCLE_A
    end
  end
RUBY

Dir.mktmpdir do |dir|
  source = File.join(dir, 'intconst.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_intconst', dir)
  order = dfs_order(ireps, root_label)

  native = File.join(dir, 'native.cxx')
  File.write(native, 'void f(mrb_state* M) { mrb_define_class(M, "NativeDefined", M->object_class); }')
  clean_foreign = File.join(dir, 'clean.rb')
  File.write(clean_foreign, "class Foreign; end\n")

  admitted = IntegerConstants.analyze(ireps, [native], [clean_foreign])
  check.call('literal, aliased, and in-range arithmetic constants are proven Fixnum-kind',
             %w[SHOW_MESSAGE END_LOOP ALIASED ARITHMETIC ARITHMETIC_CHAIN].all? { |n| admitted.include?(n) })
  check.call('arithmetic beyond the cross-target Fixnum range is refused',
             !admitted.include?('ARITHMETIC_OVERFLOW'))

  values = IntegerConstants.analyze_values(ireps, admitted)
  check.call('a plain literal resolves to its own value', values['SHOW_MESSAGE'] == 10110)
  check.call('a second literal in the same module resolves independently', values['END_LOOP'] == 12410)
  check.call('an alias to an admitted literal resolves through it', values['ALIASED'] == 10110)
  check.call('ADD/SUBI constant expressions resolve through aliases',
             values['ARITHMETIC'] == 12430 && values['ARITHMETIC_CHAIN'] == 12420)
  check.call('an arithmetic result outside the cross-target Fixnum range is not inlined',
             !values.key?('ARITHMETIC_OVERFLOW'))
  check.call('two definitions disagreeing on the value resolve to nothing',
             !values.key?('DISAGREEING') && admitted.include?('DISAGREEING'))
  check.call('a name with no literal-rooted definition (pure alias cycle) resolves to nothing',
             !values.key?('CYCLE_A') && !values.key?('CYCLE_B'))
  check.call('a name not admitted by the kind proof is absent here too', !values.key?('NON_INTEGER'))
  check.call('an out-of-scope name never appears', values.empty? || !values.key?('NOPE'))

  # Emission through the real GETCONST/GETMCNST codegen.
  registry = build_registry(ireps, root_label)[0]
  emit = lambda do |method_name, op, name, table|
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    CodeGen.integer_constant_values = table
    md = registry.fetch(method_name).find { |m| m.owner == 'User' }
    irep = ireps.fetch(md.irep)
    idx = irep.instructions.index { |insn| insn.op == op && insn.args.include?(name) }
    raise "#{method_name}: no #{op} naming #{name} found" unless idx

    code = gen.compile_insn(irep.instructions[idx], irep, md, idx)
    CodeGen.integer_constant_values = nil
    code
  end

  bare = emit.call('read_bare', 'GETCONST', 'ALIASED', { 'ALIASED' => 10110 })
  check.call('a proven bare GETCONST inlines the literal with no lookup at all',
             bare.match?(/r\d+ = mrb_fixnum_value\(10110\);/) && !bare.include?('mrb_const_get') &&
               !bare.include?('bc2cpp_cconst_'))

  scoped = emit.call('read_scoped', 'GETMCNST', 'SHOW_MESSAGE', { 'SHOW_MESSAGE' => 10110 })
  check.call('a proven GETMCNST inlines the literal and skips the member lookup',
             scoped.match?(/r\d+ = mrb_fixnum_value\(10110\);/) && !scoped.include?('mrb_const_get'))

  plain_getconst = emit.call('read_bare', 'GETCONST', 'ALIASED', {})
  check.call('an unproven bare GETCONST keeps the ordinary lookup',
             !plain_getconst.include?('mrb_fixnum_value') &&
               (plain_getconst.include?('mrb_const_get') || plain_getconst.include?('bc2cpp_const_scope_')))

  plain_getmcnst = emit.call('read_scoped', 'GETMCNST', 'SHOW_MESSAGE', {})
  check.call('an unproven GETMCNST keeps the ordinary lookup',
             plain_getmcnst.include?('mrb_const_get(M, r') && !plain_getmcnst.include?('mrb_fixnum_value'))

  # A class/module-valued name must never collide with the integer-value path:
  # StableClassConstants only admits names with a CLASS/MODULE definition,
  # analyze_values only admits names with a SETCONST/SETMCNST literal
  # definition -- a name cannot have both without one of the two proofs
  # already refusing it (a CLASS statement poisons IntegerConstants outright).
  check.call('a class/module name is never also an admitted integer value',
             admitted.disjoint?(Set['Cmd', 'Sub', 'User']))
end

# 32-bit mrb_int safety: LOADI32 is the only LOADI* form wide enough to exceed
# the Fixnum range this whole toolchain (Wio/Emscripten/PSP's 32-bit mrb_int)
# requires; every other LOADI* form is already bounded to +-2^15.
in_range = IntegerConstants.loadi_value(Insn.synthetic('LOADI32', 'R1 1073741823'))
out_of_range = IntegerConstants.loadi_value(Insn.synthetic('LOADI32', 'R1 1073741824'))
check.call('a LOADI32 value at the Fixnum boundary is accepted', in_range == 1_073_741_823)
check.call('a LOADI32 value one past the Fixnum boundary is refused', out_of_range.nil?)

if failures.empty?
  puts 'bc2cpp integer constant inlining check: PASS'
else
  warn "bc2cpp integer constant inlining check: #{failures.size} failure(s)"
  exit 1
end

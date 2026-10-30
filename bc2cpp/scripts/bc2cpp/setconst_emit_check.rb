#!/usr/bin/env ruby
# frozen_string_literal: true

# SETCONST emitter (tools/bc2cpp/codegen_insn.rb): the constant write of a class body becomes an mrb_const_set on the
# body's class, named by the cached owner class pointer. Only a class body holds a SETCONST (a def cannot write one), so
# the check compiles a class, finds its SETCONST, and emits it for that class as owner. Needs MRBC; without it: SKIP.
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

suite.finish!

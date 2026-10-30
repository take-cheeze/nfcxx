#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_REGISTER (prototype): a kept method a class body defines (its TDEF) is compiled by the method compiler,
# and its registration call (the one emit_owner_registration_lines makes) names the compiled entry and aspec. Needs MRBC.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/class_body_method_register_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = File.expand_path('../..', __dir__)
suite = FixtureCheck.new('class_body_method_register_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Foo
    def add(a, b)
      a + b
    end
  end
RUBY

suite.compile(SOURCE) do |ireps, root|
  registry = build_registry(ireps, root)[0]
  body = ireps.values.find { |irep| BytecodeIR.class_bodies(irep, :CLASS, :MODULE, :SCLASS).empty? && BytecodeIR.for(irep).each_source.any? { |insn, _| insn.op == :TDEF } }
  tdef = BytecodeIR.for(body).each_source.find { |insn, _| insn.op == :TDEF }.first
  child = body.reps[tdef.def_child_index]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code, define = gen.class_body_method_registration('Foo', child)
  suite.check('a kept method compiles and gets a registration call', code && define&.match?(/mrb_define_method\(M, bc2cpp_owner_reg, .*, Foo_add, MRB_ARGS_REQ\(2\)\);/))
  # The method's C++ needs the gem's own prelude (fixnum helpers, owner class helpers) to compile, so it is checked
  # on the generated gem output (the integration step), not in this unit.
end

suite.finish!

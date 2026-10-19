#!/usr/bin/env ruby
# frozen_string_literal: true

# BytecodeIR.class_bodies and class_body_path (tools/bc2cpp/bytecode_ir_classes.rb) on host-compiled fixtures: which
# CLASS/MODULE opener owns the EXEC that follows it, and the qualified path its outer scope gives. An empty body emits
# no EXEC, so the opener before it must not pick up the next class's body. Needs MRBC (a host mrbc); without it the
# check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/class_bodies_check.rb

require_relative 'check_support'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir_classes'

suite = FixtureCheck.new('class_bodies_check')
suite.require_mrbc!
check = suite.method(:check)

def opener_index(irep, name)
  found = nil
  irep.each_with_op('CLASS', 'MODULE') { |insn, idx| found = idx if insn.sym == name }
  raise "no CLASS/MODULE opener named #{name}" unless found

  found
end

suite.compile(<<~SOURCE) do |ireps, root_label|
  class Timeout < StandardError; end
  class Real
    def hi; end
  end
  class Outer::Viaconst
    def v; end
  end
  module Outer
    class Inner; end
    module Deep
      class ::TopLevel
        def top; end
      end
    end
  end
SOURCE
  root = ireps.fetch(root_label)
  bodies = BytecodeIR.class_bodies(root, 'CLASS', 'MODULE')

  timeout = opener_index(root, 'Timeout')
  real = opener_index(root, 'Real')
  viaconst = opener_index(root, 'Viaconst')
  outer = opener_index(root, 'Outer')

  check.call('empty body has no body EXEC', !bodies.key?(timeout))
  check.call('empty body does not borrow the next class body', bodies[real] != bodies[timeout])
  check.call('class with a body maps to its child irep', root.reps.include?(bodies[real]) && bodies[real])
  check.call('path of a top-level class is its name', BytecodeIR.class_body_path(root, real, nil) == 'Real')
  check.call('path of a class with a constant outer is unresolved',
             BytecodeIR.class_body_path(root, viaconst, nil).nil? && bodies.key?(viaconst))

  outer_body = ireps.fetch(bodies.fetch(outer))
  inner = opener_index(outer_body, 'Inner')
  deep = opener_index(outer_body, 'Deep')
  inner_body = BytecodeIR.class_bodies(outer_body, 'CLASS', 'MODULE')
  check.call('nested empty class has no body EXEC', !inner_body.key?(inner))
  check.call('nested class is named through its lexical namespace',
             BytecodeIR.class_body_path(outer_body, inner, 'Outer') == 'Outer::Inner')

  deep_body = ireps.fetch(BytecodeIR.class_bodies(outer_body, 'CLASS', 'MODULE').fetch(deep))
  top = opener_index(deep_body, 'TopLevel')
  check.call('explicit top-level class ignores the lexical namespace',
             BytecodeIR.class_body_path(deep_body, top, 'Outer::Deep') == 'TopLevel')
end

suite.finish!

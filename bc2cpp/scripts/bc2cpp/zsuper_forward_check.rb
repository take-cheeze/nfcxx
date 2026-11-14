#!/usr/bin/env ruby
# frozen_string_literal: true

# zsuper_forward_plan (tools/bc2cpp/codegen_receiver_facts.rb): a zsuper in a method with keyword parameters and/or a block
# parameter forwards the caller's current keyword values and block to the superclass `_impl`, in the order codegen_method.rb
# declares them. A keyword set that differs between caller and target, or a block on only one side, is still refused and
# keeps its `#error`. The fixtures compile to C++ through CodeGen#compile_method (no full build). Needs MRBC; without it the
# check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/zsuper_forward_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('zsuper_forward_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Base
    def initialize(enum = nil, key_type: 1, &block)
      key_type
    end
  end

  class Sub < Base
    def initialize(enum = nil, key_type: Integer, &block)
      super
    end
  end

  class KwBase
    def initialize(enum = nil, key_type: 1)
      key_type
    end
  end

  class KwSub < KwBase
    def initialize(enum = nil, key_type: Integer)
      super
    end
  end

  class OtherBase
    def initialize(enum = nil, other: 1, &block)
      other
    end
  end

  class MismatchSub < OtherBase
    def initialize(enum = nil, key_type: 1, &block)
      super
    end
  end

  class BlockOnlyBase
    def initialize(enum = nil)
      enum
    end
  end

  class BlockOnlySub < BlockOnlyBase
    def initialize(enum = nil, &block)
      super
    end
  end
RUBY

# The generated C++ of <class>#initialize, from a fixture compiled once.
init_code = lambda do |owner|
  suite.compile(SOURCE) do |ireps, root|
    # build_registry's values in the order CodeGen.new takes them: the registry, the superclass map (zsuper needs it),
    # the container constants and, after the native name sources, the included and prepended modules.
    registry, superclass_of, container_constants, included, prepended = build_registry(ireps, root)
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, container_constants, {}, Set.new,
                      nil, nil, nil, included, prepended)
    method = registry.fetch('initialize').find { |d| d.owner == owner }
    gen.compile_method(method.irep).fetch(:code)
  end
end

sub = init_code.call('Sub')
kw_sub = init_code.call('KwSub')
mismatch = init_code.call('MismatchSub')
block_only = init_code.call('BlockOnlySub')

puts '== forwarding'
# Sub: enum (r1) is the forwarded positional; the block is r3 (after the keyword hash r2); Base's key_type is optional, so
# its given flag follows the value.
suite.check('keyword and block zsuper calls the superclass _impl with the block and the keyword value',
            sub.match?(/_impl\(M, self, r1, r3, 1, r\d+, 1\);/))
suite.check('the forwarded zsuper no longer leaves a SUPER #error for that site',
            !sub.include?('#error unhandled opcode SUPER'))
suite.check('keyword-only zsuper forwards the keyword value without a block',
            kw_sub.match?(/_impl\(M, self, r1, 1, r\d+, 1\);/))
suite.check('a block on only one side is not forwarded to the superclass _impl directly',
            !block_only.match?(/BlockOnlyBase_initialize_impl\(M, self/))
suite.check('that site keeps the by-name zsuper call, which passes the block at run time',
            block_only.include?('bc2cpp_super_call(M, self'))

puts '== refusals'
suite.check('a keyword set the superclass does not name stays refused',
            mismatch.include?('#error') && !mismatch.match?(/_impl\(M, self, r1, r3/))

suite.finish!

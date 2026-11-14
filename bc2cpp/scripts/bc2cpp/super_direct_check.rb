#!/usr/bin/env ruby
# frozen_string_literal: true

# SUPER_DIRECT: the evidence InitializerTables.super_direct reads. A `super` every copy of which calls its target's
# `_impl` carries a SUPER_DIRECT marker and its [content digest, index] key is proven; a `super` resolved at run time
# (a module's, which mixes into an unknown class) has no marker and its key is refused. A key any run refuses, or a
# run without exactly one evidence row, proves nothing. Generated end to end by bc2cpp.rb.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/super_direct_check.rb
require 'json'
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/initializer_tables'
require_relative '../../tools/bc2cpp/bc2cpp'
require 'set'

ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('super_direct_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  module Game
    class Base
      def step
        1
      end

      def scaled(x)
        x * 2
      end

      def mixed
        3
      end
    end

    module Mix
      def mixed
        super + 1
      end
    end

    class Mixed < Base
      include Mix
    end

    class Child < Base
      def step
        super + 10
      end

      def scaled(x)
        super(x) + 1
      end
    end
  end
RUBY

code, err = Dir.mktmpdir('super_direct') do |dir|
  Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Game::Base Game::Mix Game::Mixed Game::Child])
end
row = err.lines.grep(/^#{InitializerTables::PREFIX}/)
check.call('one evidence row', row.size == 1)
evidence = JSON.parse(row.first.delete_prefix(InitializerTables::PREFIX))
bodies = code.split(%r{^(?=// \w+(?:::\w+)*#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }

check.call('a bare super with a known target is marked direct', bodies.fetch('Game::Child#step').include?('// SUPER_DIRECT '))
check.call('super(x) with a known target is marked direct', bodies.fetch('Game::Child#scaled').include?('// SUPER_DIRECT '))
check.call("a module's super is not marked direct", !bodies.fetch('Game::Mix#mixed').include?('// SUPER_DIRECT '))
check.call('the two direct sites are proven', evidence.fetch('super_direct').size == 2)
check.call("the module's site is refused", evidence.fetch('super_refused').size == 1)

run = ->(proven, refused) { { err: "#{InitializerTables::PREFIX}#{JSON.generate(super_direct: proven, super_refused: refused)}\n" } }
check.call('a key one run proves and another refuses stays out',
           InitializerTables.super_direct([run.([['d1', 3]], []), run.([], [['d1', 3]])]).empty?)
check.call('a key proven in one run and absent from the other is proven',
           InitializerTables.super_direct([run.([['d1', 3]], []), run.([], [])]) == Set[['d1', 3]])
check.call('a run without an evidence row proves nothing',
           InitializerTables.super_direct([run.([['d1', 3]], []), { err: '' }]).empty?)

# ZSUPER_FORWARD (tools/bc2cpp/codegen_receiver_facts.rb, zsuper_forward_plan): a zsuper of a method with keyword parameters
# and/or a block parameter calls the superclass `_impl` with the caller's keyword values and block, in the order
# codegen_method.rb declares them. A block present on one side only, or a keyword set the superclass does not name, stays
# out of the direct call. Fixtures compile to C++ through CodeGen#compile_method (no full build).
ZSUPER_SOURCE = <<~'RUBY'
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

zsuper_init_code = lambda do |owner|
  suite.compile(ZSUPER_SOURCE) do |ireps, root|
    # build_registry's values in CodeGen.new's order: the registry, the superclass map (zsuper needs it), the container
    # constants and, after the native name sources, the included and prepended modules.
    registry, superclass_of, container_constants, included, prepended = build_registry(ireps, root)
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, container_constants, {}, Set.new,
                      nil, nil, nil, included, prepended)
    method = registry.fetch('initialize').find { |d| d.owner == owner }
    gen.compile_method(method.irep).fetch(:code)
  end
end

zsuper_sub = zsuper_init_code.call('Sub')
zsuper_kw_sub = zsuper_init_code.call('KwSub')
zsuper_mismatch = zsuper_init_code.call('MismatchSub')
zsuper_block_only = zsuper_init_code.call('BlockOnlySub')

# Sub: enum (r1) is the forwarded positional; the block is r3 (after the keyword hash r2); Base's key_type is optional, so
# its given flag follows the value.
check.call('zsuper with keyword and block calls the superclass _impl with the block and the keyword value',
           zsuper_sub.match?(/_impl\(M, self, r1, r3, 1, r\d+, 1\);/))
check.call('the forwarded zsuper leaves no SUPER #error for that site', !zsuper_sub.include?('#error unhandled opcode SUPER'))
check.call('keyword-only zsuper forwards the keyword value without a block',
           zsuper_kw_sub.match?(/_impl\(M, self, r1, 1, r\d+, 1\);/))
check.call('a block on only one side is not forwarded to the superclass _impl directly',
           !zsuper_block_only.match?(/BlockOnlyBase_initialize_impl\(M, self/))
check.call('that site keeps the by-name zsuper call, which passes the block at run time',
           zsuper_block_only.include?('bc2cpp_super_call(M, self'))
check.call('a keyword set the superclass does not name stays out of the direct call',
           !zsuper_mismatch.match?(/OtherBase_initialize_impl\(M, self, r1, r3/) && zsuper_mismatch.include?('#error'))

# ZSUPER_SINGLETON: a class method's zsuper (`def self.new ... super`, owner K.singleton) reaches the superclass's singleton.
# A program that calls `extend` may put a module first, so the forwarding is refused there.
SINGLETON_SOURCE = <<~'RUBY'
  class SBase
    def self.new(enum = nil, key_type: 1, &block)
      key_type
    end
  end

  class SSub < SBase
    def self.new(enum = nil, key_type: Integer, &block)
      super
    end
  end
RUBY

SINGLETON_EXTEND_SOURCE = <<~'RUBY'
  module Ext
    def new(enum = nil, key_type: 1, &block)
      super
    end
  end

  class SBase
    def self.new(enum = nil, key_type: 1, &block)
      key_type
    end
  end

  class SSub < SBase
    extend Ext

    def self.new(enum = nil, key_type: Integer, &block)
      super
    end
  end
RUBY

singleton_code = lambda do |source|
  suite.compile(source) do |ireps, root|
    registry, superclass_of, container_constants, included, prepended = build_registry(ireps, root)
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, container_constants, {}, Set.new,
                      nil, nil, nil, included, prepended)
    method = registry.fetch('new').find { |d| d.owner == 'SSub.singleton' }
    gen.compile_method(method.irep).fetch(:code)
  end
end

singleton_plain = singleton_code.call(SINGLETON_SOURCE)
singleton_extended = singleton_code.call(SINGLETON_EXTEND_SOURCE)
check.call('a class method zsuper with keyword and block forwards to the superclass singleton',
           singleton_plain.match?(/_impl\(M, self, r1, r3, 1, r\d+, 1\);/))
check.call('a program that calls extend keeps the class method zsuper out of the direct call',
           !singleton_extended.match?(/_impl\(M, self, r1, r3, 1, r\d+, 1\);/))

suite.finish!

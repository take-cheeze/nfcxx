#!/usr/bin/env ruby
# frozen_string_literal: true

# MRBLIB_STUBS (tools/bc2cpp/mrblib_stubs.rb): which compiled bodies a closed build's mrblib may ship empty, and the
# source rewrite that empties them.
#
#   stubbable (needs a host mrbc)
#     - a plain compiled def is stubbable, also when load-time core code calls it on self, dups or clones;
#     - a core body the generation's registry dropped (all_defs still holds it) is no load-time code;
#     - a body that runs while mrblib loads, a module_function or alias copy, a guarded entry and a key with two defs
#       are not;
#   rewrite
#     - the lexical owner follows module/class nesting, `::` paths, `def self.` and `class << self`;
#     - defs in blocks and in method bodies are left alone, and so is a key matched twice in one file;
#     - a body with rescue/ensure keeps its def line;
#     - the result compiles with mrbc, and a stubbed body raises ScriptError.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/mrblib_stubs_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ENV['BC2CPP_SIG_DIRS'] = ''
suite = FixtureCheck.new('mrblib_stubs_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  module Game
    class Plain
      def run
        1
      end

      def copy
        0
      end

      def self.boot
        2
      end
      boot

      def shared
        3
      end
      alias shared2 shared

      def guarded
        4
      end

      def twice
        5
      end

      def twice
        6
      end
    end

    module Util
      def helper
        7
      end
      module_function :helper
    end
  end

  class Hash
    def copy(other)
      run
      other.dup
    end

    def make(klass) = klass.new
  end
  {}.copy(1)
  [1].clone
RUBY

COMPILED = [
  { owner: 'Game::Plain', name: 'run' }, { owner: 'Game::Plain', name: 'copy' },
  { owner: 'Game::Plain.singleton', name: 'boot' },
  { owner: 'Game::Plain', name: 'shared' }, { owner: 'Game::Plain', name: 'guarded', guard: 0 },
  { owner: 'Game::Plain', name: 'twice' }, { owner: 'Game::Util', name: 'helper' }
].freeze

suite.compile(SOURCE) do |ireps, root|
  registry = build_registry(ireps, root)[0]
  stub = MrblibStubs.stubbable(COMPILED, ireps, registry)
  suite.check('a plain compiled def is stubbable, though load-time code copies core objects (also self in a core method)',
              stub.include?('Game::Plain#run') && stub.include?('Game::Plain#copy'))
  suite.check('a body that runs while mrblib loads is not', !stub.include?('Game::Plain.singleton#boot'))
  suite.check('an aliased body is not', !stub.include?('Game::Plain#shared'))
  suite.check('a module_function body is not', !stub.include?('Game::Util#helper'))
  suite.check('a guarded entry is not', !stub.include?('Game::Plain#guarded'))
  suite.check('a key with two defs is not', !stub.include?('Game::Plain#twice'))
  # The generation's registry no longer holds core defs it keeps interpreted: their bodies are still method bodies.
  filtered = registry.transform_values { |defs| defs.reject { |d| d.owner == 'Hash' } }
  suite.check('a core body the registry dropped runs only when called',
              MrblibStubs.stubbable(COMPILED, ireps, filtered, registry).include?('Game::Plain#copy'))
end

# A copy takes the symbol literals in its argument registers, not every symbol literal of the body: an attr_reader
# name or a def of another name in the same class body stays stubbable. A copy whose argument is not a literal keeps
# every symbol literal of the body (the conservative reading).
COPY_SOURCE = <<~'RUBY'
  class Pane
    def x
      1
    end

    attr_reader :y

    def a
      2
    end

    alias_method :b, :a
  end

  class Dynamic
    def x
      1
    end

    def a
      2
    end

    name = :b
    alias_method name, :a
  end
RUBY

COPY_COMPILED = [
  { owner: 'Pane', name: 'x' }, { owner: 'Pane', name: 'a' },
  { owner: 'Dynamic', name: 'x' }, { owner: 'Dynamic', name: 'a' }
].freeze

suite.compile(COPY_SOURCE) do |ireps, root|
  registry = build_registry(ireps, root)[0]
  stub = MrblibStubs.stubbable(COPY_COMPILED, ireps, registry)
  suite.check('a literal copy keeps only the copied def, not an unrelated symbol of the body',
              stub.include?('Pane#x') && !stub.include?('Pane#a'))
  suite.check('a copy whose argument is not a literal keeps every symbol literal of the body (a def named by one stays)',
              !stub.include?('Dynamic#a') && stub.include?('Dynamic#x'))
end

REWRITE = <<~'RUBY'
  module Game
    class Scene::Map
      def a(x, y = 1)
        x + y
      end

      def self.b = 2

      class << self
        def c
          3
        rescue StandardError
          4
        end
      end

      private def d
        5
      end

      if true
        def e; 6; end
      end

      [1].each do
        def f; 7; end
      end

      def g
        def h; 8; end
      end
    end
  end

  class ::Top
    def i; 9; end
    def j; 10; end
    def j; 11; end
  end
RUBY

keys = %w[Game::Scene::Map#a Game::Scene::Map.singleton#b Game::Scene::Map.singleton#c Game::Scene::Map#d
          Game::Scene::Map#e Game::Scene::Map#f Game::Scene::Map#h Top#i Top#j].to_set
out, stubbed = MrblibStubs.rewrite(REWRITE, keys)
suite.check('nesting, ::paths, def self. and class << self give the registry owner, under modifiers and conditionals',
            stubbed == %w[Game::Scene::Map#a Game::Scene::Map.singleton#b Game::Scene::Map.singleton#c
                          Game::Scene::Map#d Game::Scene::Map#e Top#i].to_set)
suite.check('defs in blocks and method bodies, and a key matched twice, keep their bodies',
            out.include?('def f; 7; end') && out.include?('def h; 8; end') && out.include?('def j; 10; end') &&
            out.include?('def j; 11; end'))
suite.check('a stubbed body keeps its parameters', out.include?("def a(x, y = 1)\n      raise ScriptError\n"))
suite.check('a body with rescue keeps its def line and loses the rescue',
            out.match?(/def c\n *raise ScriptError\n *end/) && !out.include?('rescue StandardError'))
suite.compile(out.force_encoding(Encoding::UTF_8)) do |ireps, _root|
  raises = ireps.values.count { |irep| irep.syms.map(&:to_s).include?('ScriptError') }
  suite.check('the rewrite compiles, one ScriptError raise per stubbed body', raises == stubbed.size)
end

suite.finish!

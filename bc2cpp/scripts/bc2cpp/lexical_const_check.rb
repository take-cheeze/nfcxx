#!/usr/bin/env ruby
# frozen_string_literal: true

# LEXICAL_CONST (ADR 0423): LexicalConsts.analyze names the definition each GETCONST / GETMCNST reads.
# Each fixture is compiled by the host mrbc and its reads are checked against the lexical rule: a
# bare name resolves to the first scope of its lexical chain that defines it, only when no other
# definition reachable from that scope (chain, ancestors, Object) could be read instead; anything
# else has no key. Needs MRBC (a host mrbc); without it the check prints SKIP and exits 0.

require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/lexical_consts'

mrbc = ENV['MRBC']
unless mrbc && File.executable?(mrbc)
  puts 'SKIP lexical_const_check: MRBC is not set to a host mrbc'
  exit 0
end

failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# [op, name, key] of every GETCONST/GETMCNST read, and [name, key] of every SETCONST site.
analyze = lambda do |source, static: true|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'fixture.rb')
    File.write(path, source)
    ireps, _root = compile_ireps([path], 'lexical_const', dir)
    info = LexicalConsts.analyze(ireps, static: static)
    reads = []
    sites = []
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        case insn.op
        when 'GETCONST', 'GETMCNST' then reads << [insn.op, insn.const_name, info.read_keys[insn]]
        when 'SETCONST' then sites << [insn.const_name, info.site_keys[insn]]
        end
      end
    end
    { reads: reads, sites: sites, read_keys: info.read_keys.size }
  end
end

# The reads of one constant name, so a fixture's own headers (a superclass, a module name) are not counted.
named = ->(result, name) { result[:reads].select { |_op, read_name, _key| read_name == name } }

puts '== resolution'
turn = analyze.call(<<~RUBY)
  module Game
    class Character
      TURN_LEFT = { 8 => 4 }.freeze
      def turn_left; TURN_LEFT[1]; end
    end
    class MoveRoute
      TURN_LEFT = 17
      def mr; TURN_LEFT; end
    end
    def self.outer; Character::TURN_LEFT; end
  end
  def top_read; Game::Character::TURN_LEFT; end
RUBY
check.call('TURN_LEFT read in Game::Character is Game::Character::TURN_LEFT',
           turn[:reads].include?(['GETCONST', 'TURN_LEFT', 'Game::Character::TURN_LEFT']))
check.call('TURN_LEFT read in Game::MoveRoute is Game::MoveRoute::TURN_LEFT',
           turn[:reads].include?(['GETCONST', 'TURN_LEFT', 'Game::MoveRoute::TURN_LEFT']))
check.call('Character::TURN_LEFT (GETMCNST from Game) is Game::Character::TURN_LEFT',
           turn[:reads].count(['GETMCNST', 'TURN_LEFT', 'Game::Character::TURN_LEFT']) == 2)
check.call('the definitions are keyed by their own scope', turn[:sites].sort == [['TURN_LEFT', 'Game::Character::TURN_LEFT'],
                                                                                 ['TURN_LEFT', 'Game::MoveRoute::TURN_LEFT']])

only_top = analyze.call("TURN_LEFT = 0\ndef top_read; TURN_LEFT; end\n")
check.call('a name defined only at the top level is read as that definition', only_top[:reads] == [['GETCONST', 'TURN_LEFT', 'TURN_LEFT']])

sibling = analyze.call("class Pre; Y = 0; end\nclass P2; Y = 1; def f; Y; end; end\n")
check.call('a sibling definition in another scope does not reach a read (P2::Y)',
           sibling[:reads] == [['GETCONST', 'Y', 'P2::Y']])

reopen = analyze.call("class A0; V = 1; end\nclass A0; def f; V; end; end\n")
check.call('a plain reopened class reads its own constant', reopen[:reads] == [['GETCONST', 'V', 'A0::V']])

block = analyze.call("class Blk; T = 1; def f; [1].each { |_| T }; end; end\n")
check.call('a block in a method keeps the lexical scope of its body', block[:reads] == [['GETCONST', 'T', 'Blk::T']])

puts '== refused'
shadow = analyze.call("module G; X = 1; class F; X = 2; def f; X; end; end; end\n")
check.call('an inner definition does not hide an outer one that is also reachable: refused',
           shadow[:reads] == [['GETCONST', 'X', nil]])

prefn = analyze.call("X = 0\nclass F; X = 1; def f; X; end; end\n")
check.call('Object::X can be read before F::X is assigned: refused', prefn[:reads] == [['GETCONST', 'X', nil]])

superclass = analyze.call("class B0; W = 1; end\nclass S0 < B0; W = 2; def f; W; end; end\n")
check.call('a name also defined by an explicit superclass: refused', named.call(superclass, 'W') == [['GETCONST', 'W', nil]])

unrelated = analyze.call("module Q; Z = 1; end\nclass S2; def f; Z; end; end\n")
check.call('a read outside the scope of the only definition: refused', unrelated[:reads] == [['GETCONST', 'Z', nil]])

mixin = analyze.call("module M0; U = 1; end\nclass C0; include M0; U = 2; def f; U; end; end\n")
check.call('a name also defined by an included module: refused', named.call(mixin, 'U') == [['GETCONST', 'U', nil]])

compact = analyze.call("module G; end\nclass G::Compact; def f; Q1; end; end\nQ1 = 1\n")
check.call('a read in a compact class body (scope not modelled): refused', named.call(compact, 'Q1') == [['GETCONST', 'Q1', nil]])

singleton = analyze.call("class << Object\n  Z9 = 1\nend\nclass Rd; def f; Z9; end; end\n")
check.call('a definition in a singleton body is unknown: its site and its reads are refused',
           singleton[:sites] == [['Z9', nil]] && named.call(singleton, 'Z9') == [['GETCONST', 'Z9', nil]])

private = analyze.call("class Pc; V = 1; private_constant :V; end\nclass Pq; def f; Pc::V; end; end\n")
check.call('a scoped read of a private constant is refused (it raises from outside its class)',
           named.call(private, 'V') == [['GETMCNST', 'V', nil]])

evaled = analyze.call("class K; def f; X; end; end\nK.class_eval('X = 1')\n")
check.call('a string class_eval makes the whole world unresolved', evaled[:read_keys].zero?)

unstatic = analyze.call("class A1; V = 1; def f; V; end; end\n", static: false)
check.call('non-static constants (const_set and friends) make the whole world unresolved', unstatic[:read_keys].zero?)

if failures.empty?
  puts "lexical_const_check: #{checks} checks passed"
else
  puts "lexical_const_check: #{failures.size} failure(s)"
  exit 1
end

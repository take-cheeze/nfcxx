#!/usr/bin/env ruby
# frozen_string_literal: true

# CALLEE_RETURN_FOLD (tools/bc2cpp/codegen_callee_return_fold.rb): with BC2CPP_RETURN_FOLD=1 a conditional jump on a call
# result is decided when every definition the call can reach returns a literal true, false or nil. The fixtures are:
#   - a complete program whose callees return only true, only false, or only nil: `if ok?`, `unless no?`, `v = ok?; if v`
#     and `no?.nil?` fold (gate on) and keep their tests (gate off);
#   - a callee returning true or a parameter-dependent value: the test is kept with the gate on;
#   - the same name redefined by define_method, reached by a computed-name send, aliased, or on an owner with
#     method_missing: the test is kept with the gate on;
#   - a callee whose return sits in a block, that has a rescue, or that is called with a block: the test is kept.
# The closed world is a ClosedWorld built from the fixture's own ireps and registry, with no outside sources. Needs MRBC;
# without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/callee_return_fold_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('callee_return_fold_check')
suite.require_mrbc!

# The fixtures are spelled out as strings: each variant differs from COMPLETE by one construct, and a substitution that
# silently misses would make the variant the base program.
HEAD = "class Router\n  def ok?\n    true\n  end\n\n  def no?\n    false\n  end\n\n"
ROUTE = <<~'RUBY'
  def route(x)
    r = 0
    r += 1 if ok?
    r += 2 unless no?
    v = ok?
    r += 4 if v
    r += 8 if no?.nil?
    r
  end
RUBY
RUN = "\n  def run\n    route(3)\n  end\nend\n"

COMPLETE = HEAD + ROUTE + RUN

# Substitutions into ROUTE: the guard raises if one misses, so a variant can never equal its base program by accident.
def replace_once(text, from, to)
  raise ArgumentError, "fixture text not found: #{from.inspect}" unless text.include?(from)

  text.sub(from, to)
end

MIXED = HEAD + "  def maybe(x)\n    x ? true : false\n  end\n\n" +
        replace_once(ROUTE, "  r\nend\n", "  r += 16 if maybe(x)\n  r\nend\n") + RUN

DEFINE_METHOD = COMPLETE + "\nclass Dm\n  define_method(:ok?) { false }\nend\n"

# The literal 'ok?' is a name the program spells, so DynamicNames reaches the method through the computed send.
COMPUTED_SEND = HEAD + ROUTE + "\n  def go(n)\n    send(n)\n  end\n\n" +
                "  def run\n    route(3) + go('ok?')\n  end\nend\n"

ALIASED = HEAD + ROUTE + "\n  alias_method :yes?, :ok?\n" + RUN

METHOD_MISSING = HEAD + ROUTE + "\n  def method_missing(*)\n    0\n  end\n" + RUN

BLOCK_RETURN = "class Router\n  def ok?\n    true\n  end\n\n  def no?\n    [1].each { return false }\n    true\n  end\n\n" +
               ROUTE + RUN

RESCUE = "class Router\n  def ok?\n    true\n  end\n\n  def no?\n    begin\n      false\n    rescue StandardError\n" \
         "      false\n    end\n  end\n\n" + ROUTE + RUN

# A block call is SENDB: its result is the value a `break` supplies, so it is never read.
BLOCK_CALL = HEAD + replace_once(ROUTE, "  r += 1 if ok?\n", "  r += 1 if ok? { 3 }\n") + RUN

# The generated C++ of Router#route with BC2CPP_RETURN_FOLD set to +gate+ ('1' or '0') for +source+.
route_code = lambda do |gate, source = COMPLETE|
  previous = ENV['BC2CPP_RETURN_FOLD']
  ENV['BC2CPP_RETURN_FOLD'] = gate
  suite.compile(source) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: {}, walked: [], native_paths: [], ruby_paths: [])
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                      Set.new, Set.new, nil, {}, {}, Set.new, closed_world: world)
    method = registry.fetch('route').find { |d| d.owner == 'Router' }
    gen.compile_method(method.irep).fetch(:code)
  end
ensure
  ENV['BC2CPP_RETURN_FOLD'] = previous
end

tests = ->(code) { code.scan(/mrb_test\(|mrb_nil_p\(/).size }
folded = ->(code) { code.scan(/DECIDED_BRANCH JMP(?:IF|NOT|NIL) R\d+: (?:taken|not taken)/).size }

on = route_code.call('1')
off = route_code.call('0')

puts '== callees returning a literal are folded'
suite.check('gate on: the four literal-return tests are decided', folded.call(on) == 4 && tests.call(on) == 0)
suite.check('gate on: the nil test on the false callee is decided not taken',
            on.scan(/DECIDED_BRANCH JMPNIL R\d+: not taken/).size == 1)
suite.check('gate off: the callee tests are kept', folded.call(off) == 0 && tests.call(off) == 4)

puts '== a callee with a parameter-dependent return is kept'
mixed = route_code.call('1', MIXED)
suite.check('the test on maybe(x) is kept and the literal ones are decided',
            tests.call(mixed) == 1 && folded.call(mixed) == 4)

puts '== a name the closed world does not fully see is kept'
# ok? is refused in each of these, so only the two folds on no? remain (`unless no?` and `no?.nil?`).
suite.check('define_method of the same name keeps the ok? tests',
            folded.call(route_code.call('1', DEFINE_METHOD)) == 2)
suite.check('a computed-name send that can reach ok? keeps the ok? tests',
            folded.call(route_code.call('1', COMPUTED_SEND)) == 2)
suite.check('an alias of ok? keeps the ok? tests', folded.call(route_code.call('1', ALIASED)) == 2)
suite.check('a method_missing on the owner keeps every test', folded.call(route_code.call('1', METHOD_MISSING)) == 0)

puts '== a body with a non-literal exit is kept'
suite.check('a return inside a block (RETURN_BLK) keeps the no? tests',
            folded.call(route_code.call('1', BLOCK_RETURN)) == 2)
suite.check('a rescue handler keeps the no? tests', folded.call(route_code.call('1', RESCUE)) == 2)

puts '== a block call is never read'
# `if ok? { 3 }` is SENDB and keeps its test; `v = ok?` is still a plain SEND and folds.
suite.check('ok? called with a block keeps its test', folded.call(route_code.call('1', BLOCK_CALL)) == 3)

puts '== gate'
suite.check('BC2CPP_RETURN_FOLD=0 emits no callee fold', folded.call(off) == 0)

suite.finish!
